require 'spec_helper'
require 'delayed/backend/redis_store'

describe Delayed::Backend::RedisStore::Job do
  it_should_behave_like 'a delayed_job backend'
end
