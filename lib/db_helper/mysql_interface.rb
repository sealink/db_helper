require 'active_support/core_ext/hash'
require 'db_helper/command'
include DbHelper::Command

module DbHelper
  class MysqlInterface
    attr_accessor :options, :config
    def initialize(config)
      @config = config.symbolize_keys
      @config[:username] ||= 'root'
      @options = "--user=#{@config[:username]}"
      [:password,:host,:port,:socket].each do |opt|
        @options += " --#{opt}=#{@config[opt]}" unless @config[opt].blank?
      end
    end

    def database
      @config[:database]
    end

    def drop_and_create
      puts "0. Dropping and creating database"
      begin
        command "mysqladmin #{@options} drop --force #{database}"
      rescue
        puts "database doesn't exist. Skipping drop"
      end
      command "mysqladmin #{@options} create #{database}"
    end

    def import(file)
      command "mysql #{@options} #{database} < #{file.gsub('.gz', '')}"
    end

    def csv_import(csv_file_full_path, columns, csv_options = {})
      csv_options['fields-terminated-by'] ||= "','"
      csv_options['fields-enclosed-by'] ||= "'\"'"
      csv_options['lines-terminated-by'] ||= "'\n'"
      csv_options['ignore-lines'] = '1' # Ignore first line so it can be used to show columns
      `mysqlimport #{@options} #{database} \
        #{csv_options.map{|k,v| "--#{k}=#{v}"}.join(' ')} \
       --columns='#{columns.join(',')}' \
       --local \
       #{csv_file_full_path}`
    end

    def admin
    end
  end
end
