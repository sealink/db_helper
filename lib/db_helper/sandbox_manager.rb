require 'sys/proctable'
require 'parseconfig'

include Sys

class SandboxManager
  def initialize(dir)
    @dir = dir
  end


  def self.default_sandbox_base_dir
    configuration = Rails.configuration.database_configuration[Rails.env]
    suffixes = Rails.configuration.database_configuration.keys
    current_db = configuration['database']

    while suffix = suffixes.pop
      current_db = current_db.gsub("_#{suffix}",'')
    end

    sandbox_proc = Sys::ProcTable.ps.find { |p| p.comm == 'mysqld' && p.cwd.to_s.include?(current_db) }

    if sandbox_proc
      sandbox_proc.cwd.gsub(File.join('', current_db, 'data'), '')
    else
      File.join('', 'db')
    end
  end


  def configurations
    Dir[File.join(@dir,'**','my.sandbox.cnf')].map.with_object({}) do |config_file, hash|
      config = ParseConfig.new(config_file)
      sandbox_name = Pathname.new(config_file).split.first.split.last.to_s
      hash[sandbox_name] = config
    end
  end


  def ports
    configurations.map.with_object({}) { |(sandbox, conf), hash| hash[sandbox] = conf['client']['port']}
  end
end
