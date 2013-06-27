require 'input_reader'
require 'sys/proctable'
require 'db_helper/command'
require 'db_helper/sandbox'
require 'db_helper/sql_importer'
require 'db_helper/sandbox_manager'

include Command
include Sys

namespace :db do
  desc "Copy and import a remote database to a local database"
  task :import_from_remote do
    begin
      sources = YAML::load(File.open(File.join(ENV['RAILS_ROOT'] || '.', File.join('config','database_import.yml'))))
      default = sources.delete('default') || {:db => {}}

      puts "Select database?"

      sources.values.each.with_index do |source,i|
        puts "#{i + 1}. #{source['name']}"
      end

      num_selected = InputReader.get_int(prompt: 'Enter Choice: ', valid_values: (1..sources.count).to_a)
      selected = sources.values[num_selected - 1]

      importer = SqlImporter.new(selected, default)
      importer.backup

      post_execution_commands = Array.wrap(selected.has_key?('post_execution_commands')  ? selected['post_execution_commands'] : default['post_execution_commands'])

      if !post_execution_commands.empty?
        puts "Post execution commands"
        post_execution_commands.each.with_index { |c,i| puts "#{i + 1}. #{c}" }
        if InputReader.get_boolean(:prompt => "Run post execution commands (careful what you do, the command strings will be evaluated and executed!) (y/n)?")
          puts "Running post execution commands"
          post_execution_commands.each do |c|
            eval c
          end
        end
      end
    

      puts "Done"
    #rescue Exception => e
    #  puts "Error: #{e.message}"
    end
  end
  
  desc "Import remote database from hot backup into sandbox"
  task :update_sandbox do
    configuration = Rails.configuration.database_configuration[Rails.env]
    suffixes = Rails.configuration.database_configuration.keys
    default_db = configuration['database']

    while suffix = suffixes.pop
      default_db = default_db.gsub("_#{suffix}",'')
    end

    backup_db = default_db.gsub('_','-')

    db = InputReader.get_string(prompt: "Database (#{backup_db}):", default_value: backup_db)

    default_backup_dir = 'latest'
    backup_dir = InputReader.get_string(prompt: "Backup directory (#{default_backup_dir}):", default_value: default_backup_dir)
    default_hot_backup_dir = File.join('','media','backup','mysql',"#{db}","#{backup_dir}")
    hot_backup_dir = InputReader.get_string(prompt: "Backup path (#{default_hot_backup_dir}):", default_value: default_hot_backup_dir)
    raise "#{hot_backup_dir} is not a valid path" unless File.directory?(hot_backup_dir)

    sandbox_proc = Sys::ProcTable.ps.find { |p| p.comm == 'mysqld' && 
      ( p.respond_to?(:cwd) ? p.cwd.to_s.include?(default_db) : p.cmdline.include?(default_db)
      ) }

    default_sandbox_dir = if sandbox_proc
                            sandbox_proc.cwd.gsub(File.join('','data'),'')
                          else
                            File.join('','db',db)
                          end

    sandbox_dir = InputReader.get_string(prompt: "Sandbox path (#{default_sandbox_dir}):", default_value: default_sandbox_dir)
    raise "#{sandbox_dir} is not a valid path" unless File.directory?(sandbox_dir)

    backup_files = Dir[File.join(hot_backup_dir,'*.gz')]
    raise "No backup files found" if backup_files.empty?
    backup_file_path = InputReader.select_item(backup_files, prompt: "Select backup file:")

    command "cp #{File.join(backup_file_path)} #{sandbox_dir}"

    backup_file = File.basename(backup_file_path)

    sandbox = Sandbox.new(sandbox_dir)
    sandbox.import(backup_file)
  end


  # Given a set of database yml files in the config directory named following the pattern
  # database.#{database_name}.yml (e.g.: database.sealink.yml), it will allow swapping the
  # current database configuration with one of the specific database configurations
  # and start the related sandbox server
  desc "Swap database config files"
  task :swap_config do
    databases = []
    config_dir = Dir.new(File.join(Rails.root,'config'))
    config_dir.each do |f|
      match = f.scan(/database\.(.*)\.yml/).presence
      databases << match.flatten.first if match
    end
    database = InputReader.select_item(databases, :prompt => "Select database:")
    selected_database_config_file = File.join(config_dir,"database.#{database}.yml")
    database_config_file = File.join(config_dir,"database.yml")
    command "cp #{selected_database_config_file} #{database_config_file}"
    puts "Swapped database config file"
    
    if InputReader.get_boolean(:prompt => "Start #{database} sandbox server? (Y/N):")
      default_sandbox_base_dir = File.join('','home','projects','db')
      sandbox_base_dir = InputReader.get_string(:prompt => "Sandbox base directory (#{default_sandbox_base_dir}):", :default_value => default_sandbox_base_dir)
      default_sandbox_dir = File.join("#{sandbox_base_dir}","#{database}")
      sandbox_dir = InputReader.get_string(:prompt => "Full sandbox directory (#{default_sandbox_dir}):", :default_value => default_sandbox_dir)
      command "#{sandbox_dir}/start"
      puts "Started sandbox server"
    end
  end


  desc 'Create sandbox'
  task :create_sandbox do
    default_sandboxes_base_dir = SandboxManager.default_sandboxes_base_dir
    sandboxes_dir = InputReader.get_string(prompt: "Sandboxes path (#{default_sandboxes_base_dir}):", default_value: default_sandboxes_base_dir)
    sm = SandboxManager.new(sandboxes_dir)
    ports = sm.ports
    sandboxes = ports.keys.sort_by { |sandbox| ports[sandbox] }

    puts "Existing sandboxes:"
    sandboxes.each.with_index do |sandbox, i|
      puts "#{i + 1}. #{sandbox.foreground(:cyan)}: #{ports[sandbox].foreground(:green)}"
    end

    sandbox_name = InputReader.get_string(prompt: 'Sandbox name:')

    used_ports = ports.values.map(&:to_i)
    sandbox_port = nil
    while sandbox_port.nil? do
      suggested_ports = (used_ports.min..used_ports.max).to_a - used_ports
      puts "Suggested free ports: #{suggested_ports.join(', ')}"
      chosen_port = InputReader.get_int(prompt: 'Sandbox port:')
      if used_ports.include?(chosen_port)
        puts "Port #{chosen_port} is already taken!"
      else
        sandbox_port = chosen_port
      end
    end

    command "cd #{sandboxes_dir} && ./install_sandbox #{sandbox_name} #{sandbox_port}"
  end


  desc 'Change sandbox port'
  task :change_sandbox_port do
    default_sandboxes_base_dir = SandboxManager.default_sandboxes_base_dir
    sandboxes_dir = InputReader.get_string(prompt: "Sandboxes path (#{default_sandboxes_base_dir}):", default_value: default_sandboxes_base_dir)
    sm = SandboxManager.new(sandboxes_dir)

    change_port = true
    while change_port do
      ports = sm.ports

      selection_proc = ->(sandbox) { "#{sandbox.foreground(:cyan)}: #{ports[sandbox].foreground(:green)}" }
      sandboxes = ports.keys.sort_by { |sandbox| ports[sandbox] }
      selected_sandbox = InputReader.select_item(sandboxes,
                                                 selection_attribute: selection_proc,
                                                 prompt: 'Which sandbox port would you like to change?')
      path_to_sandbox = File.join(sandboxes_dir, selected_sandbox)

      used_ports = ports.values.map(&:to_i)
      new_port = nil
      while new_port.nil? do
        suggested_ports = (used_ports.min..used_ports.max).to_a - used_ports
        puts "Suggested free ports: #{suggested_ports.join(', ')}"
        chosen_port = InputReader.get_int(prompt: 'Enter new port:')
        if used_ports.include?(chosen_port)
          puts "Port #{chosen_port} is already taken!"
        else
          new_port = chosen_port
        end
      end

      puts "Changing port for #{selected_sandbox} from #{ports[selected_sandbox]} to #{new_port}:"
      command "cd #{sandboxes_dir} && sbtool -o port -s #{path_to_sandbox} --new_port=#{new_port}"

      if InputReader.get_boolean(prompt: "Start #{selected_sandbox} sandbox? (y/n):")
        command File.join(path_to_sandbox, 'start')
      end

      change_port = InputReader.get_boolean(prompt: 'Change another port (y/n)?')
    end
  end


  desc 'Remove sandbox'
  task :remove_sandbox do
    default_sandboxes_base_dir = SandboxManager.default_sandboxes_base_dir
    sandboxes_dir = InputReader.get_string(prompt: "Sandboxes path (#{default_sandboxes_base_dir}):", default_value: default_sandboxes_base_dir)
    sm = SandboxManager.new(sandboxes_dir)
    ports = sm.ports
    selection_proc = ->(sandbox) { "#{sandbox.foreground(:cyan)}: #{ports[sandbox].foreground(:green)}" }
    sandboxes = ports.keys.sort_by { |sandbox| ports[sandbox] }
    selected_sandbox = InputReader.select_item(sandboxes,
                                               selection_attribute: selection_proc,
                                               prompt: 'Which sandbox would you like to delete?')
    path_to_sandbox = File.join(sandboxes_dir, selected_sandbox)

    if InputReader.get_boolean(prompt: "Are you sure you want do delete #{selected_sandbox} sandbox? (y/n):".foreground(:red))
      puts "Deleting sandbox #{selected_sandbox}:"
      command "cd #{sandboxes_dir} && sbtool -o delete -s #{path_to_sandbox}"
    end
  end


end

