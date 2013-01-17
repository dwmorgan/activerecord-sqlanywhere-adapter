module ActiveRecord
  module ConnectionAdapters
    module SqlAnywhere
      module SchemaStatements
      
      # Maps native ActiveRecord/Ruby types into SQLAnywhere types
      # TINYINTs are treated as the default boolean value
      # ActiveRecord allows NULLs in boolean columns, and the SQL Anywhere BIT type does not
      # As a result, TINYINT must be used. All TINYINT columns will be assumed to be boolean and
      # should not be used as single-byte integer columns. This restriction is similar to other ActiveRecord database drivers
      def native_database_types #:nodoc:
        {
          :primary_key => 'INTEGER PRIMARY KEY DEFAULT AUTOINCREMENT NOT NULL',
          :string      => { :name => "varchar", :limit => 255 },
          :text        => { :name => "long varchar" },
          :integer     => { :name => "integer" },
          :float       => { :name => "float" },
          :decimal     => { :name => "decimal" },
          :datetime    => { :name => "datetime" },
          :timestamp   => { :name => "datetime" },
          :time        => { :name => "time" },
          :date        => { :name => "date" },
          :binary      => { :name => "long binary" },
          :boolean     => { :name => "tinyint"}
        }
      end
      
      def table_structure(table_name)
          sql = <<-SQL
SELECT SYS.SYSCOLUMN.column_name AS name, 
  NULLIF(SYS.SYSCOLUMN."default", 'autoincrement') AS "default",
  IF SYS.SYSCOLUMN.domain_id IN (7,8,9,11,33,34,35,3,27) THEN
    IF SYS.SYSCOLUMN.domain_id IN (3,27) THEN
      SYS.SYSDOMAIN.domain_name || '(' || SYS.SYSCOLUMN.width || ',' || SYS.SYSCOLUMN.scale || ')'
    ELSE
      SYS.SYSDOMAIN.domain_name || '(' || SYS.SYSCOLUMN.width || ')'
    ENDIF
  ELSE
    SYS.SYSDOMAIN.domain_name 
  ENDIF AS domain, 
  IF SYS.SYSCOLUMN.nulls = 'Y' THEN 1 ELSE 0 ENDIF AS nulls
FROM 
  SYS.SYSCOLUMN 
  INNER JOIN SYS.SYSTABLE ON SYS.SYSCOLUMN.table_id = SYS.SYSTABLE.table_id 
  INNER JOIN SYS.SYSDOMAIN ON SYS.SYSCOLUMN.domain_id = SYS.SYSDOMAIN.domain_id
WHERE
  table_name = '#{table_name}'
SQL
          structure = hash_query(sql, :skip_logging)
          raise(ActiveRecord::StatementInvalid, "Could not find table '#{table_name}'") if structure == false
          structure
        end
        
        # Required to prevent DEFAULT NULL being added to primary keys
        def options_include_default?(options)
          options.include?(:default) && !(options[:null] == false && options[:default].nil?)
        end

        # Do not return SYS-owned or DBO-owned tables
        def tables(name = nil) #:nodoc:
            sql = "SELECT table_name FROM SYS.SYSTABLE WHERE creator NOT IN (0,3)"
            select(sql, name).map { |row| row["table_name"] }
        end

        def columns(table_name, name = nil) #:nodoc:
          table_structure(table_name).map do |field|
            field['default'] = field['default'][1..-2] if (!field['default'].nil? and field['default'][0].chr == "'")
            SQLAnywhereColumn.new(field['name'], field['default'], field['domain'], (field['nulls'] == 1))
          end
        end

        def indexes(table_name, name = nil) #:nodoc:
          sql = "SELECT DISTINCT index_name, \"unique\" FROM SYS.SYSTABLE INNER JOIN SYS.SYSIDXCOL ON SYS.SYSTABLE.table_id = SYS.SYSIDXCOL.table_id INNER JOIN SYS.SYSIDX ON SYS.SYSTABLE.table_id = SYS.SYSIDX.table_id AND SYS.SYSIDXCOL.index_id = SYS.SYSIDX.index_id WHERE table_name = '#{table_name}' AND index_category > 2"
          select(sql, name).map do |row|
            index = IndexDefinition.new(table_name, row['index_name'])
            index.unique = row['unique'] == 1
            sql = "SELECT column_name FROM SYS.SYSIDX INNER JOIN SYS.SYSIDXCOL ON SYS.SYSIDXCOL.table_id = SYS.SYSIDX.table_id AND SYS.SYSIDXCOL.index_id = SYS.SYSIDX.index_id INNER JOIN SYS.SYSCOLUMN ON SYS.SYSCOLUMN.table_id = SYS.SYSIDXCOL.table_id AND SYS.SYSCOLUMN.column_id = SYS.SYSIDXCOL.column_id WHERE index_name = '#{row['index_name']}'"	
            index.columns = select(sql).map { |col| col['column_name'] }
            index
          end
        end

        def primary_key(table_name) #:nodoc:
          sql = "SELECT SYS.SYSTABCOL.column_name FROM (SYS.SYSTABLE JOIN SYS.SYSTABCOL) LEFT OUTER JOIN (SYS.SYSIDXCOL JOIN SYS.SYSIDX) WHERE table_name = '#{table_name}' AND SYS.SYSIDXCOL.sequence = 0"
          rs = select(sql)
          if !rs.nil? and !rs[0].nil?
            rs[0]['column_name']
          else
            nil
          end
        end

        def remove_index(table_name, options={}) #:nodoc:
          execute "DROP INDEX #{quote_table_name(table_name)}.#{quote_column_name(index_name(table_name, options))}"
        end

        def rename_table(name, new_name)
          execute "ALTER TABLE #{quote_table_name(name)} RENAME #{quote_table_name(new_name)}"
        end

        def change_column_default(table_name, column_name, default) #:nodoc:
          execute "ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} DEFAULT #{quote(default)}"
        end

        def change_column_null(table_name, column_name, null, default = nil)
          unless null || default.nil?
            execute("UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(column_name)}=#{quote(default)} WHERE #{quote_column_name(column_name)} IS NULL")
          end
          execute("ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} #{null ? '' : 'NOT'} NULL")
        end             

        def change_column(table_name, column_name, type, options = {}) #:nodoc:         
          add_column_sql = "ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
          add_column_options!(add_column_sql, options)
          add_column_sql << ' NULL' if options[:null]
          execute(add_column_sql)
        end
         
        def rename_column(table_name, column_name, new_column_name) #:nodoc:
          execute "ALTER TABLE #{quote_table_name(table_name)} RENAME #{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}"
        end

        def remove_column(table_name, column_name)
          sql = "SELECT \"index_name\" FROM SYS.SYSTAB join SYS.SYSTABCOL join SYS.SYSIDXCOL join SYS.SYSIDX WHERE \"column_name\" = '#{column_name}' AND \"table_name\" = '#{table_name}'"
          select(sql, nil).map do |row|
            execute "DROP INDEX \"#{table_name}\".\"#{row['index_name']}\""      
          end
          execute "ALTER TABLE #{quote_table_name(table_name)} DROP #{quote_column_name(column_name)}"
        end
      end
    end
  end
end