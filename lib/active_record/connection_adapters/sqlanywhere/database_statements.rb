module ActiveRecord
  module ConnectionAdapters
    module SqlAnywhere
      module DatabaseStatements
      
        def begin_db_transaction #:nodoc:
          @auto_commit = false;
        end

        def commit_db_transaction #:nodoc:
          SA.instance.api.sqlany_commit(@connection)
          @auto_commit = true;
        end
        
        # Executes the delete statement and returns the number of rows affected.
        def delete(arel, name = nil, binds = [])
          exec_delete(to_sql(arel), name, binds)
        end
        
        # Executes delete sql statement in the context of this connection using binds as the bind substitutes. name is the logged along with the executed sql statement.
        def exec_delete(sql, name, binds)
          exec_query(sql, name, binds)
        end
        
        # Executes insert sql statement in the context of this connection using binds as the bind substitutes. name is the logged along with the executed sql statement.
        def exec_insert(sql, name, binds)
          exec_query(sql, name, binds)
        end
        
        # Executes sql statement in the context of this connection using binds as the bind substitutes. name is the logged along with the executed sql statement.
        def exec_query(sql, name = 'SQL', binds = [])
          if name == :skip_logging
            #execute(sql, name)
            hash_query(sql, name, binds)
          else
            log(sql, name) do
              #execute(sql, name)
              hash_query(sql, name, binds)
            end
          end    
        end
        
        # Executes update sql statement in the context of this connection using binds as the bind substitutes. name is the logged along with the executed sql statement.
        def exec_update(sql, name, binds)
          exec_query(sql, name, binds)
        end
        
        # Executes the SQL statement in the context of this connection. Sets @affected_rows, @last_id for last inserted id
        def execute(sql, name = nil)
          do_execute(sql, name)
        end
        
        # Returns id_value or the last auto-generated ID from the affected table.
        def insert(arel, name = nil, pk = nil, id_value = nil, sequence_name = nil, binds = [])
          exec_insert(to_sql(arel), name, binds)
          retval = last_inserted_id(nil)
          retval = id_value if retval == 0
          return retval
        end
        
        # @@trancount contains the current nesting level of transaction
        def outside_transaction?()
          # trancount = SA.instance.api.sqlany_execute_direct(@connection, 'SELECT @@trancount')
          # raise ActiveRecord::StatementInvalid.new("#{SA.instance.api.sqlany_error(@connection)}:SELECT @@trancount") if trancount.nil?
          # SA.instance.api.sqlany_fetch_next(trancount)
          # count = SA.instance.api.sqlany_get_column(trancount, 0)[1]
          # SA.instance.api.sqlany_free_stmt(trancount)
          
          # count == 0
          nil
        end
        
        def rollback_db_transaction #:nodoc:
          SA.instance.api.sqlany_rollback(@connection)
          @auto_commit = true;
        end
        
        # Returns an array of record hashes with the column names as keys and column values as values.
        def select_all(arel, name = nil, binds = [])
          select(to_sql(arel), name, binds)
        end
        
        # Returns an array of arrays containing the field values. Order is the same as that returned by 'columns'.
        def select_rows(sql, name = nil)
          array_query(sql, name, [])
        end
        
        def update(arel, name = nil, binds = [])
          exec_update(to_sql(arel), name, binds)
          @affected_rows
        end
      
      protected       
        def last_inserted_id(result)
          identity = SA.instance.api.sqlany_execute_direct(@connection, 'SELECT @@identity')
          raise ActiveRecord::StatementInvalid.new("#{SA.instance.api.sqlany_error(@connection)}:#{sql}") if identity.nil?
          SA.instance.api.sqlany_fetch_next(identity)
          retval = SA.instance.api.sqlany_get_column(identity, 0)[1]
          SA.instance.api.sqlany_free_stmt(identity)

          return retval
        end
        
        # Returns an array of record hashes with the column names as keys and column values as values. 
        def select(sql, name = nil, binds = [])
          hash_query(sql, name, binds)
        end
        
        def sql_for_insert(sql, pk, id_value, sequence_name, binds)
          [sql, binds]
        end
        
        def update_sql(sql, name = nil)
          execute(sql, name)
        end
        
        # Returns affected rows, sets @last_id
        def do_execute(sql, name)
          rs = SA.instance.api.sqlany_execute_direct(@connection, sql)
          raise ActiveRecord::StatementInvalid.new("#{SA.instance.api.sqlany_error(@connection)}:#{sql}") if rs.nil?
          
          @affected_rows = SA.instance.api.sqlany_affected_rows(rs)
          SA.instance.api.sqlany_free_stmt(rs)
          
          identity = SA.instance.api.sqlany_execute_direct(@connection, 'SELECT @@identity')
          raise ActiveRecord::StatementInvalid.new("#{SA.instance.api.sqlany_error(@connection)}:#{sql}") if identity.nil?
          SA.instance.api.sqlany_fetch_next(identity)
          @last_id = SA.instance.api.sqlany_get_column(identity, 0)[1]
          SA.instance.api.sqlany_free_stmt(identity)
          
          @affected_rows
        end
        
        # Returns array of 2 of the resulting rows and columns
        def query(sql, name, binds)
        
          rs = SA.instance.api.sqlany_execute_direct(@connection, sql)
          raise ActiveRecord::StatementInvalid.new("#{SA.instance.api.sqlany_error(@connection)}:#{sql}") if rs.nil?
          
          max_cols = SA.instance.api.sqlany_num_cols(rs)
          fields = {}
          max_cols.times do |i|
            fields[i] = SA.instance.api.sqlany_get_column_info(rs, i)[2]
          end
          
          rows = []
          while SA.instance.api.sqlany_fetch_next(rs) == 1
            result = Array.new(max_cols)
            max_cols.times do |cols|
              result[cols] = SA.instance.api.sqlany_get_column(rs, cols)[1]
            end
            rows << result
          end
          @affected_rows = SA.instance.api.sqlany_affected_rows(rs)
          SA.instance.api.sqlany_free_stmt(rs)

          return rows, fields
        end
        
        # Returns array of hashes
        def hash_query(sql, name = nil, binds = [])
          
          return if sql.nil?
          #sql = modify_limit_offset(sql)

          # ActiveRecord allows a query to return TOP 0. SQL Anywhere requires that the TOP value is a positive integer.
          return Array.new() if sql =~ /TOP 0/i

          stmt = SA.instance.api.sqlany_prepare(@connection, sql)
          
          # sql may contain unbounded params
          
          i = 0
          binds.map do |col, val|
            result, param = SA.instance.api.sqlany_describe_bind_param(stmt, i)
            param.set_value(type_cast(val, col)) if result
            result = SA.instance.api.sqlany_bind_param(stmt, i, param) if param
            i = i + 1
          end
          
          # Executes the query, iterates through the results, and builds an array of hashes.
          # rs = SA.instance.api.sqlany_execute_direct(@connection, sql)
          return [] if stmt.nil?
          result = SA.instance.api.sqlany_execute(stmt)
          if result.nil?
            result, errstr = SA.instance.api.sqlany_error(@connection)
            raise SQLAnywhereException.new(errstr, result, sql)
          end
        
          record = []
          if( SA.instance.api.sqlany_num_cols(stmt) > 0 ) 
            while SA.instance.api.sqlany_fetch_next(stmt) == 1
              max_cols = SA.instance.api.sqlany_num_cols(stmt)
              result = Hash.new()
              max_cols.times do |cols|
                result[SA.instance.api.sqlany_get_column_info(stmt, cols)[2]] = SA.instance.api.sqlany_get_column(stmt, cols)[1]
              end
              record << result
            end
            @affected_rows = 0
          else
            @affected_rows = SA.instance.api.sqlany_affected_rows(stmt)
          end 
          SA.instance.api.sqlany_free_stmt(stmt)

          SA.instance.api.sqlany_commit(@connection)
 
          return record
        end
        
        # Returns array of arrays
        def array_query(sql, name, binds)
          query(sql, name, binds)[0]
        end
        
        # ActiveRecord uses the OFFSET/LIMIT keywords at the end of query to limit the number of items in the result set.
        # This syntax is NOT supported by SQL Anywhere. In previous versions of this adapter this adapter simply
        # overrode the add_limit_offset function and added the appropriate TOP/START AT keywords to the start of the query.
        # However, this will not work for cases where add_limit_offset is being used in a subquery since add_limit_offset
        # is called with the WHERE clause. 
        #
        # As a result, the following function must be called before every SELECT statement against the database. It
        # recursivly walks through all subqueries in the SQL statment and replaces the instances of OFFSET/LIMIT with the
        # corresponding TOP/START AT. It was my intent to do the entire thing using regular expressions, but it would seem
        # that it is not possible given that it must count levels of nested brackets.
        def modify_limit_offset(sql)
          modified_sql = ""
          subquery_sql = ""
          in_single_quote = false
          in_double_quote = false
          nesting_level = 0
          if sql =~ /(OFFSET|LIMIT)/xmi then
            if sql =~ /\(/ then
              sql.split(//).each_with_index do |x, i|
                case x[0]
                  when 40  # left brace - (
                    modified_sql << x if nesting_level == 0
                    subquery_sql << x if nesting_level > 0
                    nesting_level = nesting_level + 1 unless in_double_quote || in_single_quote
                  when 41  # right brace - )
                    nesting_level = nesting_level - 1 unless in_double_quote || in_single_quote
                    if nesting_level == 0 and !in_double_quote and !in_single_quote then
                      modified_sql << modify_limit_offset(subquery_sql)
                      subquery_sql = ""
                    end
                    modified_sql << x if nesting_level == 0
                    subquery_sql << x if nesting_level > 0                         
                  when 39  # single quote - '
                    in_single_quote = in_single_quote ^ true unless in_double_quote
                    modified_sql << x if nesting_level == 0
                    subquery_sql << x if nesting_level > 0    
                  when 34  # double quote - "
                    in_double_quote = in_double_quote ^ true unless in_single_quote
                    modified_sql << x if nesting_level == 0
                    subquery_sql << x if nesting_level > 0
                  else
                    modified_sql << x if nesting_level == 0
                    subquery_sql << x if nesting_level > 0
                end
                raise ActiveRecord::StatementInvalid.new("Braces do not match: #{sql}") if nesting_level < 0
              end
            else
              modified_sql = sql
            end
            raise ActiveRecord::StatementInvalid.new("Quotes do not match: #{sql}") if in_double_quote or in_single_quote
            return "" if modified_sql.nil?
            select_components = modified_sql.scan(/\ASELECT\s+(DISTINCT)?(.*?)(?:\s+LIMIT\s+(.*?))?(?:\s+OFFSET\s+(.*?))?\Z/xmi)
            return modified_sql if select_components[0].nil?
            final_sql = "SELECT #{select_components[0][0]} "
            final_sql << "TOP #{select_components[0][2].nil? ? 1000000 : select_components[0][2]} " 
            final_sql << "START AT #{(select_components[0][3].to_i + 1).to_s} " unless select_components[0][3].nil?
            final_sql << "#{select_components[0][1]}"
            return final_sql
          else
            return sql
          end
        end
        
        def distinct(columns, order_by) #:nodoc:
          return "DISTINCT #{columns}" if order_by.blank?

          # construct a valid DISTINCT clause, ie. one that includes the ORDER BY columns, using
          # FIRST_VALUE such that the inclusion of these columns doesn't invalidate the DISTINCT
          order_columns = if order_by.is_a?(String)
            order_by.split(',').map { |s| s.strip }.reject(&:blank?)
            else # in latest ActiveRecord versions order_by is already Array
              order_by
            end
          order_columns = order_columns.zip((0...order_columns.size).to_a).map do |c, i|
            # remove any ASC/DESC modifiers
            value = c =~ /^(.+)\s+(ASC|DESC)\s*$/i ? $1 : c
            "FIRST_VALUE(#{value}) OVER (PARTITION BY #{columns} ORDER BY #{c}) AS alias_#{i}__"
          end
          sql = "DISTINCT #{columns}, "
          sql << order_columns * ", "
        end  

        
      end
    end
  end
end 