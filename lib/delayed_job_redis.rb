require "redis"
require "delayed_job"
require "delayed/backend/redis_store"

module Delayed
  class Worker
    class << self
      attr_accessor :redis, :redis_prefix
    end
  end
end

Delayed::Worker.backend = :redis_store
Delayed::Worker.redis_prefix = "delayed_job"
