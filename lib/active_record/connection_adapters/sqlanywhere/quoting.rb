module ActiveRecord
  module ConnectionAdapters
    module SqlAnywhere
      module Quoting
        # Applies quotations around column names in generated queries
        def quote_column_name(name) #:nodoc:
          %Q("#{name}")
        end
        
        def type_cast(value, column)
          return super unless value == true || value == false

          value ? 1 : 0
        end

        # Handles special quoting of binary columns. Binary columns will be treated as strings inside of ActiveRecord.
        # ActiveRecord requires that any strings it inserts into databases must escape the backslash (\).
        # Since in the binary case, the (\x) is significant to SQL Anywhere, it cannot be escaped.
        def quote(value, column = nil)
          case value
            when String, ActiveSupport::Multibyte::Chars
              value_S = value.to_s
              if column && column.type == :binary && column.class.respond_to?(:string_to_binary)
                "'#{column.class.string_to_binary(value_S)}'"
              else
                 super(value, column)
              end
            else
              super(value, column)
          end
        end

        def quoted_true
          '1'
        end

        def quoted_false
          '0'
        end
        
      end
    end
  end
end