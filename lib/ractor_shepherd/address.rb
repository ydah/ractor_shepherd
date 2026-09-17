# frozen_string_literal: true

module RactorShepherd
  # A destination identified by name, returned by `sup.lookup(:jobs, :poller)`.
  #
  # It caches what it resolved, so it is **not shareable**: build one per Ractor
  # that uses it.
  #
  # Delivery is at-most-once. A message that arrived just before the child died
  # is lost.
  class Address
    RETRY_INITIAL_DELAY = 0.01
    RETRY_MAX_DELAY = 0.2
    RESOLVE_POLL_INTERVAL = 0.01

    attr_reader :path

    def initialize(supervisor, path, retries: 3, resolve_timeout: 1.0)
      raise InvalidSpec, "lookup needs at least one id" if path.empty?

      @supervisor = supervisor
      @path = path.freeze
      @retries = retries
      @resolve_timeout = resolve_timeout
      @ractor = nil
    end

    # The currently cached destination, which may be stale.
    def ractor
      @ractor ||= resolve
    end

    # Throw the cache away and resolve again.
    def resolve!
      @ractor = nil
      ractor
    end

    # Send without waiting. If the destination has been replaced, resolve again and retry.
    def cast(message)
      delay = RETRY_INITIAL_DELAY
      attempts = 0
      while true # `loop do` is forbidden here: Ractor::ClosedError < StopIteration
        begin
          return send_to(ractor, message)
        rescue Ractor::ClosedError
          raise ChildUnavailable, "#{label} is gone" if attempts >= @retries

          attempts += 1
          Kernel.sleep(delay)
          delay = [delay * 2, RETRY_MAX_DELAY].min
          @ractor = nil
        end
      end
    end

    # A synchronous call, for Server children. It never retries on its own,
    # because the request may not be idempotent.
    def call(message, timeout: 5)
      target = ractor
      raise InvalidOperation, "#{label} is a supervisor; call its SupervisorRef instead" unless target.is_a?(Ractor)

      Runtime::Call.perform(target, target, message, timeout: timeout, down_error: WorkerDown)
    end

    private

    def label = "#{@supervisor.path}/#{@path.join("/")}"

    def send_to(target, message)
      raise InvalidOperation, "#{label} is a supervisor; send to its SupervisorRef" unless target.is_a?(Ractor)

      target << message
      :ok
    end

    # While the child is being restarted there is nothing to resolve to, so keep
    # trying until resolve_timeout runs out.
    def resolve
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @resolve_timeout
      while true # `loop do` is forbidden here: Ractor::ClosedError < StopIteration
        found = walk
        return found if found
        raise ChildUnavailable, "#{label} is not running" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        Kernel.sleep(RESOLVE_POLL_INTERVAL)
      end
    end

    def walk
      current = @supervisor
      @path[0..-2].each do |segment|
        current = current.whereis(segment)
        return nil unless current.is_a?(SupervisorRef)
      end
      current.whereis(@path.last)
    end
  end
end
