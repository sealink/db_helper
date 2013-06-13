require 'db_helper'
require 'rails'
module DbHelper
  class Railtie < Rails::Railtie
    railtie_name :db_helper

    rake_tasks do
      load "db_helper/tasks.rb"
    end
  end
end
