$:.unshift(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'bundler/setup'
require 'active_record'
require 'rspec'
require 'logger'

require 'delayed_job_redis'
require 'delayed/backend/shared_spec'

Delayed::Worker.logger = Logger.new('/tmp/dj.log')
Delayed::Worker.redis = Redis.new

ENV['RAILS_ENV'] = 'test'

ActiveRecord::Base.establish_connection :adapter => 'sqlite3', :database => ':memory:'
ActiveRecord::Base.logger = Delayed::Worker.logger
ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define do

  create_table :stories, :primary_key => :story_id, :force => true do |table|
    table.string :text
    table.boolean :scoped, :default => true
  end
end

# Purely useful for test cases...
class Story < ActiveRecord::Base
  self.primary_key = :story_id
  def tell; text; end
  def whatever(n, _); tell*n; end
  default_scope where(:scoped => true)

  handle_asynchronously :whatever
end

# Add this directory so the ActiveSupport autoloading works
ActiveSupport::Dependencies.autoload_paths << File.dirname(__FILE__)
