require 'input_reader'
require 'db_helper/command'
require 'db_helper/mysql_interface'

module DbHelper
  class SqlImporter
    attr_accessor :selected, :default

    def initialize(selected, default)
      @selected = selected
      @default = default
    end


    def backup
      if selected['hot_backup_dir']
        hot_backup(selected, default)
      else
        cold_backup(selected, default)
      end
    end


    def hot_backup
      sandbox_dir = selected['sandbox_dir']
      #command "mkdir #{sandbox_dir}/data.new && cd #{sandbox_dir}/data.new"
      #command "cp #{selected['hot_backup_dir']}/*.tar.gz #{sandbox_dir}/data.new/remote-hot-backup.tar.gz"
      #command "cd #{sandbox_dir}/data.new && tar -xzf remote-hot-backup.tar.gz"
      command "#{sandbox_dir}/stop"
      command "rm -rf #{sandbox_dir}/data"
      command "mv #{sandbox_dir}/data.new #{sandbox_dir}/data"
      command "#{sandbox_dir}/start"
    end

    def cold_backup(selected, default)
      src_db_config = default['db'].merge(selected['db'] || {})

      selected['ssh'] ||= {}
      ssh_host          = selected['ssh']['host'] || selected['host'] || default['host']
      ssh_port          = selected['ssh']['port'] || default['ssh']['port']
      ssh_user          = selected['ssh']['user'] || default['ssh']['user']
      app_root          = selected['app_root']    || default['app_root']

      app_db_config     = selected['app_db_config'] || default['app_db_config']

      excluded_tables   = Array.wrap(selected.has_key?('excluded_tables')  ? selected['excluded_tables'] : default['excluded_tables'])
      included_tables   = Array.wrap(selected.has_key?('included_tables')  ? selected['included_tables'] : default['included_tables'])

      app_root ||= "/home/#{ssh_user}/#{src_db_config['database'].to_s.gsub('_production', '')}/current"

      db_config = selected
      if app_db_config
        yaml = command("ssh -p #{ssh_port} #{ssh_user}@#{ssh_host} \"cat #{app_root}/config/database.yml\"")
        db_config = YAML::load(yaml)
        app_db_config_hash = db_config[app_db_config]

        if app_db_config_hash
          src_db_config.merge!(app_db_config_hash)
        end
      end

      table_choices = []
      table_choices << {:option => :all,      :message => "All tables"}
      table_choices << {:option => :exclude,  :message => "All except #{excluded_tables.to_sentence}"} unless excluded_tables.empty?
      table_choices << {:option => :include,  :message => "Only #{included_tables.to_sentence}"} unless included_tables.empty?
      table_choices << {:option => :custom,   :message => "Custom select tables"}

      table_choices.each.with_index do |tc,i|
        puts "#{i + 1}. #{tc[:message]}"
      end

      table_choice = table_choices[get_int(:valid_values => (1..table_choices.count).to_a) - 1][:option]
      case table_choice
      when :all
        included_tables, excluded_tables = [[],[]]
      when :exclude
        included_tables = []
      when :include
        excluded_tables = []
      when :custom
        included_tables, excluded_tables = [get_input(:prompt => "Which tables to select (comma separated)").split(',').map(&:strip), []]
      end

      time_string = DateTime.current.strftime('%Y%m%d-%H%M')
      file_prefix = "#{src_db_config['database']}_#{time_string}"
      data_file_name = "#{file_prefix}_data.sql"
      structure_file_name = "#{file_prefix}_structure_for_empty_tables.sql" if included_tables.empty? && !excluded_tables.empty?

      db_config = YAML::load(File.open(File.join(ENV['RAILS_ROOT'] || '.', File.join('config','database.yml'))))
      db_config.delete_if { |config,db| db['database'].blank? }

      puts "Destination database?"
      db_config.each.with_index do |source_db,i|
        puts "#{i + 1}. #{source_db.first} - (#{source_db.last['database']})"
      end
      puts "#{db_config.size + 1}. Original (#{src_db_config['database']})"
      puts "#{db_config.size + 2}. Custom select database"
      choice = get_int(:valid_values => (1..db_config.size + 2).to_a) - 1
      destination_db_config = if choice < db_config.size
        db_config.to_a[choice] && db_config.to_a[choice].last
      else
        puts "Database options:"
        {
          :database => choice == db_config.size ? src_db_config['database'] : get_input(:prompt => "Database: ", :allow_blank => false),
          :username => get_input(:prompt => "Username: ", :allow_blank => true),
          :password => get_input(:prompt => "Password: ", :allow_blank => true),
          :port     => get_input(:prompt => "Port: ",     :allow_blank => true),
          :host     => get_input(:prompt => "Host: ",     :allow_blank => true),
          :socket   => get_input(:prompt => "Socket: ",   :allow_blank => true)
        }
      end

      src_sql = MysqlInterface.new(src_db_config)
      dst_sql = MysqlInterface.new(destination_db_config)
      dst_sql.drop_and_create if included_tables.empty?

      puts "1. Backing up database"

      mysql_cmd = "mysqldump #{src_sql.options} #{src_sql.database}"

      dump_data_cmd = "#{mysql_cmd} %s %s > %s" % [
        included_tables.map{|t| " #{t}"}.join,
        excluded_tables.map{|t| " --ignore-table=#{src_sql.database}.#{t}"}.join,
        "/tmp/#{data_file_name}"
      ]

      compress_data_cmd = "gzip '/tmp/#{data_file_name}'"

      dump_structure_cmd = "#{mysql_cmd} --no-data --tables #{excluded_tables.join(" ")} > /tmp/#{structure_file_name}" if included_tables.empty? && !excluded_tables.empty?

      [dump_data_cmd, dump_structure_cmd, compress_data_cmd].compact.each do |dump_cmd|
        command "ssh -p #{ssh_port} #{ssh_user}@#{ssh_host} \"#{dump_cmd}\""
      end


      puts "2. Coping & Decompressing SQL Files..."
      [data_file_name + ".gz", structure_file_name].compact.each_with_index do |f, index|
        command "scp -P #{ssh_port} #{ssh_user}@#{ssh_host}:/tmp/#{f} #{f}"
        command("ssh -p #{ssh_port} #{ssh_user}@#{ssh_host} \"rm /tmp/#{f}\"")
        command "gunzip #{f}" if f.end_with?('.gz')
      end

      puts "3. Importing SQL files..."
      [data_file_name + ".gz", structure_file_name].compact.each_with_index do |f, index|
        dst_sql.import(f.gsub('.gz', ''))
      end
    end


    def get_input(options = {})
      options[:prompt] ||= "Enter Choice: "
      InputReader.get_input(options)
    end


    def get_int(options = {})
      options[:prompt] ||= "Enter Choice: "
      InputReader.get_int(options)
    end
  end
end
