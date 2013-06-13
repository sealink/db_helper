module Command
  def command(command_text)
    puts "#{command_text}"
    res = `#{command_text}`
    raise "Command Failed: #{command_text}" unless $?.success?
    res
  end
end
