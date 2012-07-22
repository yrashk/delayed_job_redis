require 'uuidtools'
module Delayed
  module Backend
    module RedisStore
      class Job 
        include Delayed::Backend::Base
        attr_accessor :priority, :run_at, :queue, 
                      :failed_at, :locked_at, :locked_by

        attr_accessor :handler
        attr_writer :id

        attr_accessor :last_error, :attempts

        def self.all_keys
          Delayed::Worker.redis.keys "#{Delayed::Worker.redis_prefix}_*"
        end

        def self.count
          all_keys.length
        end

        def self.delete_all 
          all_keys.each{|k| Delayed::Worker.redis.del k }
        end

        def self.ready_to_run(worker_name, max_run_time)
          time_now = db_time_now
          keys = all_keys
          keys.select do |key|
            run_at, locked_at, locked_by, failed_at = Delayed::Worker.redis.hmget key, "run_at", "locked_at", "locked_by", "failed_at"
            run_at = Time.at run_at.to_i
            locked_at = Time.at locked_at.to_i
            failed_at = Time.at failed_at.to_i
            (run_at <= time_now and (locked_at.to_i == 0 or locked_at < time_now - max_run_time) or locked_by == worker_name) and failed_at.to_i == 0
          end
        end

        def self.before_fork
          Delayed::Worker.redis.client.disconnect
        end

        def self.after_fork
          Delayed::Worker.redis.client.connect
        end

        # When a worker is exiting, make sure we don't have any locked jobs.
        def self.clear_locks!(worker_name)
          keys = all_keys
          keys = 
          keys.select do |key|
            locked_by = Delayed::Worker.redis.hget key, "locked_by"
            locked_by == worker_name
          end
          keys.each do |k|
            Delayed::Worker.redis.hdel k, "locked_by" 
            Delayed::Worker.redis.hdel k, "locked_at" 
          end
        end

        # Find a few candidate jobs to run (in case some immediately get locked by others).
        def self.find_available(worker_name, limit = 5, max_run_time = Worker.max_run_time)
          keys = self.ready_to_run(worker_name, max_run_time)
          if Worker.min_priority
            keys = 
              keys.select do |key|
              priority = Delayed::Worker.redis.hget key, "priority"
              priority = priority.to_i
              priority >= Worker.min_priority
            end
          end
          
          if Worker.max_priority
            keys = 
              keys.select do |key|
              priority = Delayed::Worker.redis.hget key, "priority"
              priority = priority.to_i
              priority <= Worker.max_priority
            end
          end
          
          if Worker.queues.any?
            keys =
              keys.select do |key|
              queue = Delayed::Worker.redis.hget key, "queue"
              Worker.queues.include?(queue)
            end
          end
          
          keys =
            keys.sort_by do |key|
            priority, run_at = Delayed::Worker.redis.hmget key, "priority", "run_at"
            priority = priority.to_i
            run_at = run_at.to_i
            [priority, run_at]
          end

          keys[0..limit-1].map {|k| find(k) }
        end

        def save
          set_default_run_at
          keys = [:id, :priority, :run_at, :queue, :last_error,
                  :failed_at, :locked_at, :locked_by, :attempts].select  {|c| v = self.send(c); !v.nil? }
          args = keys.map do |k| 
            v = self.send(k)
            v = v.to_i if v.is_a?(Time)
            [k.to_s, v] 
          end.flatten
          args += ["payload_object", handler]
          Delayed::Worker.redis.hmset "#{Delayed::Worker.redis_prefix}_#{id}", *args
          self
        end

        def save! ; save ; end
          

        def destroy
          Delayed::Worker.redis.del "#{Delayed::Worker.redis_prefix}_#{id}"
        end

        def id
          @id ||= UUIDTools::UUID.random_create.to_s
        end

        def self.create(options)
          new(options).save
        end

        def self.create!(options)
          create(options)
        end

        def reload
          reset
          _priority, _run_at, _queue, _payload_object, _failed_at, _locked_at, _locked_by, _attempts, _last_error = 
            Delayed::Worker.redis.hmget "#{Delayed::Worker.redis_prefix}_#{id}", "priority", "run_at",
            "queue", "payload_object", "failed_at", "locked_at", "locked_by", "attempts", "last_error"
          self.priority = _priority.to_i
          self.run_at = _run_at.nil? ? nil : Time.at(_run_at.to_i)
          self.queue = _queue
          self.handler = _payload_object||YAML.dump(nil)
          self.failed_at = _failed_at.nil? ? nil : Time.at(_failed_at.to_i)
          self.locked_at = _locked_at.nil? ? nil : Time.at(_locked_at.to_i)
          self.locked_by = _locked_by
          self.attempts = _attempts.to_i
          self.last_error = _last_error
          self
        end

        def initialize(options)
          @id = nil
          @priority = 0
          @run_at = nil
          @queue = nil
          @failed_at = nil
          @locked_at = nil
          @attempts = 0
          options.each {|k,v| send("#{k}=", v) }
        end

        def update_attributes(options)
          options.each {|k,v| send("#{k}=", v) }
          save
        end
        
        def self.find(key)
          _, _id = key.split("#{Delayed::Worker.redis_prefix}_")
          _priority, _run_at, _queue, _payload_object, _failed_at, _locked_at, _locked_by, _attempts, _last_error = 
            Delayed::Worker.redis.hmget "#{Delayed::Worker.redis_prefix}_#{_id}", "priority", "run_at",
            "queue", "payload_object", "failed_at", "locked_at", "locked_by", "attempts", "last_error"
          new(:id => _id,
              :priority => _priority.to_i,
              :run_at => _run_at.nil? ? nil : Time.at(_run_at.to_i),
              :queue => _queue,
              :handler => _payload_object||YAML.dump(nil),
              :failed_at => _failed_at.nil? ? nil : Time.at(_failed_at.to_i),
              :locked_at => _locked_at.nil? ? nil : Time.at(_locked_at.to_i),
              :locked_by => _locked_by,
              :last_error => _last_error,
              :attempts => _attempts.to_i)
        end

        # Lock this job for this worker.
        # Returns true if we have the lock, false otherwise.
        def lock_exclusively!(max_run_time, worker)
          now = self.class.db_time_now
          affected_rows = 
            if locked_by != worker
              # We don't own this job so we will update the locked_by name and the locked_at
              keys = self.class.all_keys

              keys = keys.select do |key|
                _id, locked_at, run_at = Delayed::Worker.redis.hmget key, "id", "locked_at", "run_at"
                run_at = Time.at(run_at.to_i)
                locked_at = Time.at(locked_at.to_i)
                _id == id and (locked_at.to_i == 0 or locked_at < (now - max_run_time.to_i)) and (run_at <= now)
              end

              Delayed::Worker.redis.watch *keys
              Delayed::Worker.redis.multi

              keys.each {|key| Delayed::Worker.redis.hmset key, "locked_at", now, "locked_by", worker}

              Delayed::Worker.redis.exec
              
              keys.length
            else
              # We already own this job, this may happen if the job queue crashes.
              # Simply resume and update the locked_at

              keys = self.class.all_keys

              keys = keys.select do |key|
                _id, locked_by = Delayed::Worker.redis.hmget key, "id", "locked_by"
                _id == id and locked_by == worker
              end

              Delayed::Worker.redis.watch *keys
              Delayed::Worker.redis.multi
              
              keys.each {|key| Delayed::Worker.redis.hset key, "locked_at", now }
              
              Delayed::Worker.redis.exec
              
              keys.length
            end
          if affected_rows == 1
            self.locked_at = now
            self.locked_by = worker
            save
            return true
          else
            return false
          end
        end

        def self.db_time_now
          Time.now
        end

        def ==(x)
           self.id == x.id
        end

      end
    end
  end
end
