require 'db_helper'

if defined?(Rails) && defined?(Rails::Railtie)
  module DbHelper
    class Railtie < Rails::Railtie
      railtie_name :db_helper

      rake_tasks do
        load "db_helper/tasks.rb"
      end
    end
  end
end
