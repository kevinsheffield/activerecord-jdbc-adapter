ArJdbc.load_java_part :MSSQL

require 'strscan'
require 'arjdbc/mssql/utils'
require 'arjdbc/mssql/tsql_methods'
require 'arjdbc/mssql/limit_helpers'
require 'arjdbc/mssql/lock_helpers'
require 'arjdbc/mssql/explain_support'

module ArJdbc
  module MSSQL
    include Utils
    include TSqlMethods
    
    include ExplainSupport
    
    def self.extended(adapter) # :nodoc:
      initialize!
      
      if ( version = adapter.sqlserver_version ) == '2000'
        extend LimitHelpers::SqlServer2000AddLimitOffset
      else
        extend LimitHelpers::SqlServerAddLimitOffset
      end
      adapter.config[:sqlserver_version] ||= version
    end

    @@_initialized = nil
    
    def self.initialize!
      return if @@_initialized; @@_initialized = true
      
      require 'arjdbc/jdbc/serialized_attributes_helper'
      ActiveRecord::Base.class_eval do
        def after_save_with_mssql_lob
          self.class.columns.select { |c| c.sql_type =~ /image/i }.each do |column|
            value = ::ArJdbc::SerializedAttributesHelper.dump_column_value(self, column)
            next if value.nil? || (value == '')

            self.class.connection.write_large_object(
              column.type == :binary, column.name, 
              self.class.table_name, self.class.primary_key, 
              self.class.connection.quote(id), value
            )
          end
        end
      end
      ActiveRecord::Base.after_save :after_save_with_mssql_lob
    end
    
    def configure_connection
      use_database # config[:database]
    end
    
    def self.column_selector
      [ /sqlserver|tds|Microsoft SQL/i, lambda { |cfg, column| column.extend(::ArJdbc::MSSQL::Column) } ]
    end

    def self.jdbc_connection_class
      ::ActiveRecord::ConnectionAdapters::MSSQLJdbcConnection
    end

    def jdbc_column_class
      ::ActiveRecord::ConnectionAdapters::MSSQLColumn
    end
    
    def self.arel2_visitors(config)
      require 'arel/visitors/sql_server'
      visitors = config[:sqlserver_version] == '2000' ? 
        ::Arel::Visitors::SQLServer2000 : ::Arel::Visitors::SQLServer
      { 'mssql' => visitors, 'jdbcmssql' => visitors, 'sqlserver' => visitors }
    end

    def sqlserver_version
      @sqlserver_version ||= begin
        config_version = config[:sqlserver_version]
        config_version ? config_version.to_s :
          select_value("SELECT @@version")[/(Microsoft SQL Server\s+|Microsoft SQL Azure.+\n.+)(\d{4})/, 2]
      end
    end

    def modify_types(types) #:nodoc:
      super(types)
      types[:string] = { :name => "NVARCHAR", :limit => 255 }
      if sqlserver_2000?
        types[:text] = { :name => "NTEXT" }
      else
        types[:text] = { :name => "NVARCHAR(MAX)" }
      end
      types[:primary_key] = "int NOT NULL IDENTITY(1, 1) PRIMARY KEY"
      types[:integer][:limit] = nil
      types[:boolean] = { :name => "bit" }
      types[:binary] = { :name => "image" }
      types
    end

    def type_to_sql(type, limit = nil, precision = nil, scale = nil) #:nodoc:
      # MSSQL's NVARCHAR(n | max) column supports either a number between 1 and
      # 4000, or the word "MAX", which corresponds to 2**30-1 UCS-2 characters.
      #
      # It does not accept NVARCHAR(1073741823) here, so we have to change it
      # to NVARCHAR(MAX), even though they are logically equivalent.
      #
      # MSSQL Server 2000 is skipped here because I don't know how it will behave.
      #
      # See: http://msdn.microsoft.com/en-us/library/ms186939.aspx
      if type.to_s == 'string' && limit == 1073741823 && ! sqlserver_2000?
        'NVARCHAR(MAX)'
      elsif %w( boolean date datetime ).include?(type.to_s)
        super(type) # cannot specify limit/precision/scale with these types
      else
        super # TSqlMethods#type_to_sql
      end
    end

    module Column
      include LockHelpers::SqlServerAddLock

      attr_accessor :identity, :special
      alias_method :is_special, :special # #deprecated

      def simplified_type(field_type)
        case field_type
        when /int|bigint|smallint|tinyint/i           then :integer
        when /numeric/i                               then (@scale.nil? || @scale == 0) ? :integer : :decimal
        when /float|double|money|real|smallmoney/i    then :decimal
        when /datetime|smalldatetime/i                then :datetime
        when /timestamp/i                             then :timestamp
        when /time/i                                  then :time
        when /date/i                                  then :date
        when /text|ntext|xml/i                        then :text
        when /binary|image|varbinary/i                then :binary
        when /char|nchar|nvarchar|string|varchar/i    then (@limit == 1073741823 ? (@limit = nil; :text) : :string)
        when /bit/i                                   then :boolean
        when /uniqueidentifier/i                      then :string
        else
          super
        end
      end

      def default_value(value)
        return $1 if value =~ /^\(N?'(.*)'\)$/
        value
      end

      def type_cast(value)
        return nil if value.nil?
        case type
        when :integer then value.delete('()').to_i rescue unquote(value).to_i rescue value ? 1 : 0
        when :primary_key then value == true || value == false ? value == true ? 1 : 0 : value.to_i
        when :decimal   then self.class.value_to_decimal(unquote(value))
        when :datetime  then cast_to_datetime(value)
        when :timestamp then cast_to_time(value)
        when :time      then cast_to_time(value)
        when :date      then cast_to_date(value)
        when :boolean   then value == true or (value =~ /^t(rue)?$/i) == 0 or unquote(value)=="1"
        when :binary    then unquote value
        else value
        end
      end

      def extract_limit(sql_type)
        case sql_type
        when /^smallint/i
          2
        when /^int/i
          4
        when /^bigint/i
          8
        when /\(max\)/, /decimal/, /numeric/
          nil
        when /text|ntext|xml|binary|image|varbinary|bit/
          nil
        else
          super
        end
      end

      def is_utf8?
        !!( sql_type =~ /nvarchar|ntext|nchar/i )
      end

      def unquote(value)
        value.to_s.sub(/\A\([\(\']?/, "").sub(/[\'\)]?\)\Z/, "")
      end

      def cast_to_time(value)
        return value if value.is_a?(Time)
        DateTime.parse(value).to_time rescue nil
      end

      def cast_to_date(value)
        return value if value.is_a?(Date)
        return Date.parse(value) rescue nil
      end

      def cast_to_datetime(value)
        if value.is_a?(Time)
          if value.year != 0 and value.month != 0 and value.day != 0
            return value
          else
            return Time.mktime(2000, 1, 1, value.hour, value.min, value.sec) rescue nil
          end
        end
        if value.is_a?(DateTime)
          begin
            # Attempt to convert back to a Time, but it could fail for dates significantly in the past/future.
            return Time.mktime(value.year, value.mon, value.day, value.hour, value.min, value.sec)
          rescue ArgumentError
            return value
          end
        end

        return cast_to_time(value) if value.is_a?(Date) or value.is_a?(String) rescue nil

        return value.is_a?(Date) ? value : nil
      end

      # These methods will only allow the adapter to insert binary data with a length of 7K or less
      # because of a SQL Server statement length policy.
      def self.string_to_binary(value)
        ''
      end

    end

    def quote(value, column = nil)
      return value.quoted_id if value.respond_to?(:quoted_id)

      case value
      # SQL Server 2000 doesn't let you insert an integer into a NVARCHAR
      # column, so we include Integer here.
      when String, ActiveSupport::Multibyte::Chars, Integer
        value = value.to_s
        column_type = column && column.type
        if column_type == :binary
          "'#{quote_string(ArJdbc::MSSQL::Column.string_to_binary(value))}'" # ' (for ruby-mode)
        elsif column_type == :integer
          value.to_i.to_s
        elsif column_type == :float
          value.to_f.to_s
        elsif ! column.respond_to?(:is_utf8?) || column.is_utf8?
          "N'#{quote_string(value)}'" # ' (for ruby-mode)
        else
          super
        end
      when Date, Time
        if column && column.type == :time
          "'#{quoted_time(value)}'"
        elsif column && column.sql_type.index('datetimeoffset')
          "'#{quoted_full_iso8601(value)}'"
        elsif column && column.sql_type.index('datetime')
          "'#{quoted_datetime(value)}'"
        else
          super
        end
      when TrueClass  then '1'
      when FalseClass then '0'
      else super
      end
    end
    
    def quoted_date(value)
      if value.respond_to?(:usec)
        "#{super}.#{sprintf("%03d", value.usec / 1000)}"
      else
        super
      end
    end

    def quoted_datetime(value)
      if value.acts_like?(:time)
        time_zone_qualified_value = quoted_value_acts_like_time_filter(value)
        if value.is_a?(Date)
          time_zone_qualified_value.to_time.xmlschema.to(18)
        else
          if value.is_a?(ActiveSupport::TimeWithZone) && RUBY_VERSION < '1.9'
            time_zone_qualified_value = time_zone_qualified_value.to_time
          end
          time_zone_qualified_value.iso8601(3).to(22)
        end
      else
        quoted_date(value)
      end
    end
    
    def quoted_time(value)
      if value.acts_like?(:time)
        tz_value = quoted_value_acts_like_time_filter(value)
        sprintf("%02d:%02d:%02d.%03d", tz_value.hour, tz_value.min, tz_value.sec, value.usec / 1000)
      else
        quoted_date(value)
      end
    end
    
    def quoted_full_iso8601(value)
      if value.acts_like?(:time)
        value.is_a?(Date) ? 
          quoted_value_acts_like_time_filter(value).to_time.xmlschema.to(18) : 
            quoted_value_acts_like_time_filter(value).iso8601(7).to(22)
      else
        quoted_date(value)
      end
    end
        
    def quoted_value_acts_like_time_filter(value)
      method = ActiveRecord::Base.default_timezone == :utc ? :getutc : :getlocal
      value.respond_to?(method) ? value.send(method) : value
    end
    protected :quoted_value_acts_like_time_filter
    
    def quote_table_name(name)
      quote_column_name(name)
    end
    
#    def quote_table_name_for_assignment(table, attr)
#      quote_column_name(attr)
#    end if ::ActiveRecord::VERSION::MAJOR > 3
    
    def quote_column_name(name)
      name.to_s.split('.').map do |n| # "[#{name}]"
        n =~ /^\[.*\]$/ ? n : "[#{n.gsub(']', ']]')}]"
      end.join('.')
    end

    ADAPTER_NAME = 'MSSQL'.freeze
    
    def adapter_name # :nodoc:
      ADAPTER_NAME
    end

    def change_order_direction(order)
      asc, desc = /\bASC\b/i, /\bDESC\b/i
      order.split(",").collect do |fragment|
        case fragment
        when desc  then fragment.gsub(desc, "ASC")
        when asc   then fragment.gsub(asc, "DESC")
        else "#{fragment.split(',').join(' DESC,')} DESC"
        end
      end.join(",")
    end

    def supports_ddl_transactions?
      true
    end

    # NOTE: Dynamic Name Resolution - SQL Server 2000 vs. 2005
    # 
    # A query such as "select * from table1" in SQL Server 2000 goes through 
    # a set of steps to resolve and validate the object references before 
    # execution. 
    # The search first looks at the identity of the connection executing 
    # the query.
    # 
    # However SQL Server 2005 provides a mechanism to allow finer control over
    # name resolution to the administrators. By manipulating the value of the 
    # default_schema_name columns in the sys.database_principals.
    # 
    # http://blogs.msdn.com/b/mssqlisv/archive/2007/03/23/upgrading-to-sql-server-2005-and-default-schema-setting.aspx
    
    # Returns the default schema (to be used for table resolution) used for the {#current_user}.
    def default_schema
      return current_user if sqlserver_2000?
      @default_schema ||= 
        @connection.execute_query_raw(
          "SELECT default_schema_name FROM sys.database_principals WHERE name = CURRENT_USER"
        ).first['default_schema_name']
    end
    alias_method :current_schema, :default_schema

    # Allows for changing of the default schema (to be used during unqualified
    # table name resolution).
    # @note This is not supported on SQL Server 2000 !
    def default_schema=(default_schema) # :nodoc:
      raise "changing DEFAULT_SCHEMA only supported on SQLServer 2005+" if sqlserver_2000?
      execute("ALTER #{current_user} WITH DEFAULT_SCHEMA=#{default_schema}")
      @default_schema = nil if defined?(@default_schema)
    end
    alias_method :current_schema=, :default_schema=
    
    # `SELECT CURRENT_USER`
    def current_user
      @current_user ||= @connection.execute_query_raw("SELECT CURRENT_USER").first['']
    end
    
    def charset
      select_value "SELECT SERVERPROPERTY('SqlCharSetName')"
    end

    def collation
      select_value "SELECT SERVERPROPERTY('Collation')"
    end
    
    def current_database
      select_value 'SELECT DB_NAME()'
    end
    
    def use_database(database = nil)
      database ||= config[:database]
      execute "USE #{quote_table_name(database)}" unless database.blank?
    end
    
    def recreate_database(name, options = {})
      drop_database(name)
      create_database(name, options)
    end

    def recreate_database!(database = nil)
      current_db = current_database
      database ||= current_db
      use_database('master') if this_db = ( database.to_s == current_db )
      drop_database(database)
      create_database(database)
    ensure
      use_database(current_db) if this_db
    end
    
    def drop_database(name)
      execute "DROP DATABASE #{quote_table_name(name)}"
    end

    def create_database(name, options = {})
      execute "CREATE DATABASE #{quote_table_name(name)}"
    end

    def database_exists?(name)
      select_value "SELECT name FROM sys.databases WHERE name = '#{name}'"
    end
    
    def rename_table(table_name, new_table_name)
      clear_cached_table(table_name)
      execute "EXEC sp_rename '#{table_name}', '#{new_table_name}'"
    end

    # Adds a new column to the named table.
    # See TableDefinition#column for details of the options you can use.
    def add_column(table_name, column_name, type, options = {})
      clear_cached_table(table_name)
      add_column_sql = "ALTER TABLE #{quote_table_name(table_name)} ADD #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
      add_column_options!(add_column_sql, options)
      # TODO: Add support to mimic date columns, using constraints to mark them as such in the database
      # add_column_sql << " CONSTRAINT ck__#{table_name}__#{column_name}__date_only CHECK ( CONVERT(CHAR(12), #{quote_column_name(column_name)}, 14)='00:00:00:000' )" if type == :date
      execute(add_column_sql)
    end

    def rename_column(table_name, column_name, new_column_name)
      clear_cached_table(table_name)
      execute "EXEC sp_rename '#{table_name}.#{column_name}', '#{new_column_name}', 'COLUMN'"
    end

    def change_column(table_name, column_name, type, options = {}) #:nodoc:
      clear_cached_table(table_name)
      change_column_type(table_name, column_name, type, options)
      change_column_default(table_name, column_name, options[:default]) if options_include_default?(options)
    end

    def change_column_type(table_name, column_name, type, options = {}) #:nodoc:
      clear_cached_table(table_name)
      sql = "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
      sql += (options[:null] ? " NULL" : " NOT NULL") if options.has_key?(:null)
      execute(sql)
    end

    def change_column_default(table_name, column_name, default) #:nodoc:
      clear_cached_table(table_name)
      remove_default_constraint(table_name, column_name)
      unless default.nil?
        execute "ALTER TABLE #{quote_table_name(table_name)} ADD CONSTRAINT DF_#{table_name}_#{column_name} DEFAULT #{quote(default)} FOR #{quote_column_name(column_name)}"
      end
    end
    
    def remove_column(table_name, *column_names)
      raise ArgumentError.new("You must specify at least one column name. Example: remove_column(:people, :first_name)") if column_names.empty?
      # remove_columns(:posts, :foo, :bar) old syntax : remove_columns(:posts, [:foo, :bar])
      clear_cached_table(table_name)
      column_names.flatten.each do |column_name|
        remove_check_constraints(table_name, column_name)
        remove_default_constraint(table_name, column_name)
        remove_indexes(table_name, column_name) unless sqlserver_2000?
        execute "ALTER TABLE #{quote_table_name(table_name)} DROP COLUMN #{quote_column_name(column_name)}"
      end
    end

    def remove_default_constraint(table_name, column_name)
      clear_cached_table(table_name)
      if sqlserver_2000?
        # NOTE: since SQLServer 2005 these are provided as sys.sysobjects etc.
        # but only due backwards-compatibility views and should be avoided ...
        defaults = select_values "SELECT d.name" <<
          " FROM sysobjects d, syscolumns c, sysobjects t" <<
          " WHERE c.cdefault = d.id AND c.name = '#{column_name}'" <<
          " AND t.name = '#{table_name}' AND c.id = t.id"
      else
        defaults = select_values "SELECT d.name FROM sys.tables t" <<
          " JOIN sys.default_constraints d ON d.parent_object_id = t.object_id" <<
          " JOIN sys.columns c ON c.object_id = t.object_id AND c.column_id = d.parent_column_id" <<
          " WHERE t.name = '#{table_name}' AND c.name = '#{column_name}'"
      end
      defaults.each do |def_name|
        execute "ALTER TABLE #{table_name} DROP CONSTRAINT #{def_name}"
      end
    end

    def remove_check_constraints(table_name, column_name)
      clear_cached_table(table_name)
      constraints = select_values "SELECT constraint_name" <<
        " FROM information_schema.constraint_column_usage" <<
        " WHERE table_name = '#{table_name}' AND column_name = '#{column_name}'"
      constraints.each do |constraint_name|
        execute "ALTER TABLE #{table_name} DROP CONSTRAINT #{constraint_name}"
      end
    end

    def remove_indexes(table_name, column_name)
      indexes = self.indexes(table_name)
      indexes.select{ |index| index.columns.include?(column_name.to_s) }.each do |index|
        remove_index(table_name, { :name => index.name })
      end
    end
    
    def remove_index(table_name, options = {})
      execute "DROP INDEX #{quote_table_name(table_name)}.#{index_name(table_name, options)}"
    end
    
    SKIP_COLUMNS_TABLE_NAMES_RE = /^information_schema\./i # :nodoc:
    IDENTITY_COLUMN_TYPE_RE = /identity/i # :nodoc:
    # NOTE: these do not handle = equality as expected {#repair_special_columns}
    # (TEXT, NTEXT, and IMAGE data types are deprecated)
    SPECIAL_COLUMN_TYPE_RE = /text|ntext|image|xml/i # :nodoc:
    
    EMPTY_ARRAY = [].freeze # :nodoc:
    
    def columns(table_name, name = nil, default = EMPTY_ARRAY)
      # It's possible for table_name to be an empty string, or nil, if something 
      # attempts to issue SQL which doesn't involve a table. 
      # IE. "SELECT 1" or "SELECT * FROM someFunction()".
      return default if table_name.blank?
      
      table_name = unquote_table_name(table_name)

      return default if table_name =~ SKIP_COLUMNS_TABLE_NAMES_RE
      
      unless columns = ( @table_columns ||= {} )[table_name]
        columns = super(table_name, name)
        for column in columns
          column.identity = true if column.sql_type =~ IDENTITY_COLUMN_TYPE_RE
          column.special = true if column.sql_type =~ SPECIAL_COLUMN_TYPE_RE
        end
        @table_columns[table_name] = columns
      end
      columns
    end

    def clear_cached_table(table_name)
      ( @table_columns ||= {} ).delete(table_name.to_s)
    end

    def reset_column_information
      @table_columns = nil if defined? @table_columns
    end
    
    # Turns IDENTITY_INSERT ON for table during execution of the block
    # N.B. This sets the state of IDENTITY_INSERT to OFF after the
    # block has been executed without regard to its previous state
    def with_identity_insert_enabled(table_name)
      set_identity_insert(table_name, true)
      yield
    ensure
      set_identity_insert(table_name, false)
    end

    def set_identity_insert(table_name, enable = true)
      execute "SET IDENTITY_INSERT #{table_name} #{enable ? 'ON' : 'OFF'}"
    rescue Exception => e
      raise ActiveRecord::ActiveRecordError, "IDENTITY_INSERT could not be turned" + 
            " #{enable ? 'ON' : 'OFF'} for table #{table_name} due : #{e.inspect}"
    end
    
    # @see ArJdbc::MSSQL::LimitHelpers
    def determine_order_clause(sql)
      return $1 if sql =~ /ORDER BY (.*)$/i
      table_name = get_table_name(sql)
      # determine primary key for table :
      columns = self.columns(table_name)
      primary_column = columns.find { |column| column.primary || column.identity }
      unless primary_column # look for an id column and return it,
        # without changing case, to cover DBs with a case-sensitive collation :
        primary_column = columns.find { |column| column.name =~ /^id$/i }
        raise "no columns for table: #{table_name}" if columns.empty?
      end
      # NOTE: if still no PK column simply get something for ORDER BY ...
      "#{table_name}.#{(primary_column || columns.first).name}"
    end
    
    def exec_proc(proc_name, *variables)
      vars = 
        if variables.any? && variables.first.is_a?(Hash)
          variables.first.map { |k, v| "@#{k} = #{quote(v)}" }
        else
          variables.map { |v| quote(v) }
        end.join(', ')
      sql = "EXEC #{proc_name} #{vars}".strip
      log(sql, 'Execute Procedure') do
        result = @connection.execute_query_raw(sql)
        result.map! do |row| 
          row = row.is_a?(Hash) ? row.with_indifferent_access : row
          yield(row) if block_given?
          row
        end
        result
      end
    end
    alias_method :execute_procedure, :exec_proc # AR-SQLServer-Adapter naming
    
    # @override
    def exec_query(sql, name = 'SQL', binds = []) # :nodoc:
      # NOTE: we allow to execute SQL as requested returning a results.
      # e.g. this allows to use SQLServer's EXEC with a result set ...
      sql = repair_special_columns to_sql(sql, binds)
      if prepared_statements?
        log(sql, name, binds) { @connection.execute_query(sql, binds) }
      else
        sql = suble_binds(sql, binds)
        log(sql, name) { @connection.execute_query(sql) }
      end
    end
    
    # @override
    def exec_query_raw(sql, name = 'SQL', binds = [], &block) # :nodoc:
      sql = repair_special_columns to_sql(sql, binds)
      if prepared_statements?
        log(sql, name, binds) { @connection.execute_query_raw(sql, binds, &block) }
      else
        sql = suble_binds(sql, binds)
        log(sql, name) { @connection.execute_query_raw(sql, &block) }
      end
    end
    
    private
    
    def _execute(sql, name = nil)
      # Match the start of the SQL to determine appropriate behavior.
      # Be aware of multi-line SQL which might begin with 'create stored_proc' 
      # and contain 'insert into ...' lines.
      # NOTE: ignoring comment blocks prior to the first statement ?!
      if self.class.insert?(sql)
        if id_insert_table_name = identity_insert_table_name(sql)
          with_identity_insert_enabled(id_insert_table_name) do
            @connection.execute_insert(sql)
          end
        else
          @connection.execute_insert(sql)
        end
      elsif self.class.select?(sql)
        @connection.execute_query_raw repair_special_columns(sql)
      else # create | exec
        @connection.execute_update(sql)
      end
    end
    
    def identity_insert_table_name(sql)
      table_name = get_table_name(sql)
      id_column = identity_column_name(table_name)
      if id_column && sql.strip =~ /INSERT INTO [^ ]+ ?\((.+?)\)/i
        insert_columns = $1.split(/, */).map(&method(:unquote_column_name))
        return table_name if insert_columns.include?(id_column)
      end
    end
    
    def identity_column_name(table_name)
      for column in columns(table_name)
        return column.name if column.identity
      end
      nil
    end
    
    def repair_special_columns(sql)
      qualified_table_name = get_table_name(sql, true)
      if special_columns = special_column_names(qualified_table_name)
        return sql if special_columns.empty?
        special_columns = special_columns.sort { |n1, n2| n2.size <=> n1.size }
        for column in special_columns
          sql.gsub!(/\s?\[?#{column}\]?\s?=\s?/, " [#{column}] LIKE ")
          sql.gsub!(/ORDER BY \[?#{column}\]?/i, '') # NOTE: a bit stupid
        end
      end
      sql
    end

    def special_column_names(qualified_table_name)
      columns = self.columns(qualified_table_name, nil, nil)
      return columns if ! columns || columns.empty?
      special = []
      columns.each { |column| special << column.name if column.special }
      special
    end
    
    def sqlserver_2000?
      sqlserver_version <= '2000'
    end
    
  end
end

module ActiveRecord::ConnectionAdapters
  
  class MSSQLAdapter < JdbcAdapter
    include ::ArJdbc::MSSQL
    
    def initialize(*args)
      ::ArJdbc::MSSQL.initialize!
      
      super # configure_connection happens in super
      
      if ( version = self.sqlserver_version ) == '2000'
        extend LimitHelpers::SqlServer2000AddLimitOffset
      else
        extend LimitHelpers::SqlServerAddLimitOffset
      end
      config[:sqlserver_version] ||= version
    end
    
    # some QUOTING caching :

    @@quoted_table_names = {}

    def quote_table_name(name)
      unless quoted = @@quoted_table_names[name]
        quoted = super
        @@quoted_table_names[name] = quoted.freeze
      end
      quoted
    end

    @@quoted_column_names = {}

    def quote_column_name(name)
      unless quoted = @@quoted_column_names[name]
        quoted = super
        @@quoted_column_names[name] = quoted.freeze
      end
      quoted
    end
    
  end
  
  class MSSQLColumn < JdbcColumn
    include ArJdbc::MSSQL::Column
  end
  
end
