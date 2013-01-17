#====================================================
#
#    Copyright 2008-2010 iAnywhere Solutions, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#                                                                               
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#
# See the License for the specific language governing permissions and
# limitations under the License.
#
# While not a requirement of the license, if you do modify this file, we
# would appreciate hearing about it.   Please email sqlany_interfaces@sybase.com
#
#
#====================================================

require 'arel/visitors/sqlanywhere.rb'
require 'active_record'
require 'active_record/base'
require 'active_record/connection_adapters/abstract_adapter'
require 'active_record/connection_adapters/sqlanywhere/database_limits'
require 'active_record/connection_adapters/sqlanywhere/database_statements'
require 'active_record/connection_adapters/sqlanywhere/quoting'
require 'active_record/connection_adapters/sqlanywhere/schema_statements'

# Singleton class to hold a valid instance of the SQLAnywhereInterface across all connections
class SA
  include Singleton
  attr_accessor :api

  def initialize
    require 'sqlanywhere' unless defined? SQLAnywhere
    @api = SQLAnywhere::SQLAnywhereInterface.new()
    raise LoadError, "Could not load SQLAnywhere DBCAPI library" if SQLAnywhere::API.sqlany_initialize_interface(@api) == 0 
    raise LoadError, "Could not initialize SQLAnywhere DBCAPI library" if @api.sqlany_init() == 0 
  end
end

module ActiveRecord
  class Base
    DEFAULT_CONFIG = { :username => 'dba', :password => 'sql' }
    # Main connection function to SQL Anywhere
    # Connection Adapter takes four parameters:
    # * :database (required, no default). Corresponds to "DatabaseName=" in connection string
    # * :server (optional, defaults to :databse). Corresponds to "ServerName=" in connection string 
    # * :username (optional, default to 'dba')
    # * :password (optional, deafult to 'sql')
    # * :encoding (optional, defaults to charset of OS)
    # * :commlinks (optional). Corresponds to "CommLinks=" in connection string
    # * :connection_name (optional). Corresponds to "ConnectionName=" in connection string
    
    def self.sqlanywhere_connection(config)

      config = DEFAULT_CONFIG.merge(config)

      raise ArgumentError, "No database name was given. Please add a :database option." unless config.has_key?(:database)

      connection_string = "ServerName=#{(config[:server] || config[:database])};DatabaseName=#{config[:database]};UserID=#{config[:username]};Password=#{config[:password]};"
      connection_string += "CommLinks=#{config[:commlinks]};" unless config[:commlinks].nil?
      connection_string += "ConnectionName=#{config[:connection_name]};" unless config[:connection_name].nil?
      connection_string += "CharSet=#{config[:encoding]};" unless config[:encoding].nil?      
      connection_string += "Idle=0" # Prevent the server from disconnecting us if we're idle for >240mins (by default)

      db = SA.instance.api.sqlany_new_connection()
      
      ConnectionAdapters::SQLAnywhereAdapter.new(db, logger, connection_string)
    end
  end

  module ConnectionAdapters
    class SQLAnywhereException < StandardError
      attr_reader :errno
      attr_reader :sql

      def initialize(message, errno, sql)
        super(message)
        @errno = errno
        @sql = sql
      end
    end
  
    class SQLAnywhereColumn < Column
      private
        # Overridden to handle SQL Anywhere integer, varchar, binary, and timestamp types
        def simplified_type(field_type)
          return :boolean if field_type =~ /tinyint/i
          return :string if field_type =~ /varchar/i
          return :binary if field_type =~ /long binary/i
          return :datetime if field_type =~ /timestamp/i
          return :integer if field_type =~ /smallint|bigint/i
          super
        end

        def extract_limit(sql_type)
          case sql_type
            when /^tinyint/i
              1
            when /^smallint/i 
              2
            when /^integer/i  
              4            
            when /^bigint/i   
              8  
            else super
          end
        end

      protected
        # Handles the encoding of a binary object into SQL Anywhere
        # SQL Anywhere requires that binary values be encoded as \xHH, where HH is a hexadecimal number
        # This function encodes the binary string in this format
        def self.string_to_binary(value)
          "\\x" + value.unpack("H*")[0].scan(/../).join("\\x")
        end
        
        def self.binary_to_string(value)
          value.gsub(/\\x[0-9]{2}/) { |byte| byte[2..3].hex }
        end
    end

    class SQLAnywhereAdapter < AbstractAdapter
    
      include SqlAnywhere::DatabaseLimits
      include SqlAnywhere::DatabaseStatements
      include SqlAnywhere::Quoting
      include SqlAnywhere::SchemaStatements
      
      def initialize( connection, logger, connection_string = "") #:nodoc:
        super(connection, logger)
        @auto_commit = true
        @affected_rows = 0
        @last_id = 0
        @connection_string = connection_string
        connect!
      end
      
      def translate_exception(exception, message)
      
        if exception.kind_of? SQLAnywhereException
          case exception.errno
            when -143
              if exception.sql !~ /^SELECT/i then
          raise ActiveRecord::ActiveRecordError.new(message)
              else
                super
              end
            when -194
              raise InvalidForeignKey.new(message, exception)
            when -196
              raise RecordNotUnique.new(message, exception)
            when -183
              raise ArgumentError, message
            else
              super
          end
        else
          ActiveRecord::StatementInvalid.new(message)
        end
      end
    
      # ==== Abstract Adapter

      def adapter_name #:nodoc:
        'SQLAnywhere'
      end

      def supports_migrations? #:nodoc:
        true
      end

      def requires_reloading?
        true
      end
   
      def active?
        # The liveness variable is used a low-cost "no-op" to test liveness
        SA.instance.api.sqlany_execute_immediate(@connection, "SET liveness = 1") == 1
      rescue
        false
      end
      
      def set_connection_options
        SA.instance.api.sqlany_execute_immediate(@connection, "SET TEMPORARY OPTION non_keywords = 'LOGIN'") rescue nil
        SA.instance.api.sqlany_execute_immediate(@connection, "SET TEMPORARY OPTION timestamp_format = 'YYYY-MM-DD HH:NN:SS'") rescue nil
        #SA.instance.api.sqlany_execute_immediate(@connection, "SET OPTION reserved_keywords = 'LIMIT'") rescue nil
        # The liveness variable is used a low-cost "no-op" to test liveness
        SA.instance.api.sqlany_execute_immediate(@connection, "CREATE VARIABLE liveness INT") rescue nil
      end
      
      def connect!
        result = SA.instance.api.sqlany_connect(@connection, @connection_string)
        if result == 1 then
          set_connection_options
        else
          error = SA.instance.api.sqlany_error(@connection)
          raise ActiveRecord::ActiveRecordError.new("#{error}: Cannot Establish Connection")
        end
      end
      
      def disconnect!
        result = SA.instance.api.sqlany_disconnect( @connection )
        SA.instance.api.sqlany_free_connection(@connection)
        super
      end

      def reconnect!
        disconnect!
        connect!
      end

      def supports_count_distinct? #:nodoc:
        true
      end

      def supports_autoincrement? #:nodoc:
        true
      end
    end
  end
end

