require 'db_helper/command'

class Sandbox
  def initialize(dir)
    @dir = dir
  end

  def import(file)
    if file.ends_with?('tar.gz')
      import_innobackup(file)
    elsif file.ends_with?('sql.gz')
      import_sql(file)
    else
      raise "Unrecognised file format for #{file}."
    end
  end

  def import_sql(file)
    command "gunzip #{File.join(@dir, file)}"
    command File.join(@dir, 'start')
    db_name = file.gsub(/_[0-9]{4}.*/, '')
    command "#{File.join(@dir, 'use')} #{db_name} < #{File.join(@dir, file.sub('.gz',''))}"
    command "rm #{File.join(@dir, file.sub('.gz',''))}"
  end

  def import_innobackup(file)
    if File.exist?(data_new = File.join(@dir, 'data.new'))
      command "rm -rf #{data_new}"
    end
    command File.join(@dir,'start')
    command "mkdir #{data_new}"
    command "mv #{File.join(@dir, file)} #{File.join(data_new, file)}"
    command "cd #{data_new} && tar -ixzf #{file}"
    command "rm #{File.join(data_new, file)}"
    command "innobackupex --defaults-file=#{File.join(@dir,'my.sandbox.cnf')} --apply-log #{data_new}"
    command File.join(@dir,'stop')
    command "rm -rf #{File.join(@dir,'data')}"
    command "mv #{data_new} #{File.join(@dir,'data')}"
    command File.join(@dir,'start')
  end
end
