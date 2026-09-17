# frozen_string_literal: true

module RactorShepherd
  module Runtime
    # The handle a worker gets inside its own Ractor.
    #
    # It is not shareable. Do not hand it to another Ractor.
    #
    # @api private
    class Context
      attr_reader :id, :path, :supervisor, :shutdown_reason

      def initialize(id:, path:, supervisor:, event_port:)
        @id = id
        @path = path
        @supervisor = supervisor
        @event_port = event_port
        @shutdown = false
        @shutdown_reason = nil
        @wake = Thread::Queue.new
        @seq = 0
      end

      # Receive one application message.
      #
      # @param timeout [Numeric, nil] seconds; nil waits forever
      # @return [Object, nil] nil on timeout
      # @raise [ShutdownSignal] once a shutdown has been requested
      def receive(timeout: nil)
        raise ShutdownSignal if shutdown_requested?

        timer = nil
        if timeout
          @seq += 1
          timer = Timer.for_current_ractor.after(timeout, Ractor.current, Protocol.timeout(@seq))
        end

        while true # `loop do` is forbidden here: Ractor::ClosedError < StopIteration
          message = Ractor.receive
          raise ShutdownSignal if message == Protocol::SHUTDOWN_SENTINEL

          case message
          in [Protocol::TIMEOUT, seq]
            return nil if seq == @seq
            # A leftover notification from an earlier receive. Drop it and read again.
          else
            return message
          end
        end
      ensure
        timer&.cancel
      end

      # Has a shutdown been requested?
      def shutdown_requested? = @shutdown

      # Sleep, but wake immediately if a shutdown arrives.
      #
      # @return [Boolean] true if it slept the whole time, false if a shutdown cut it short
      def sleep(seconds) # rubocop:disable Naming/PredicateMethod
        return false if shutdown_requested?

        @wake.pop(timeout: seconds).nil?
      end

      # Publish an application event (as type: :worker_event).
      def emit(name, **data)
        emit_system(:worker_event, name: name, data: data)
      end

      # Publish one of the event types this gem defines.
      #
      # @api private
      def emit_system(type, **data)
        publish(Core::Event.build(type, supervisor: supervisor_path, at: now, child: id, **data))
      end

      # Start the thread that waits for a shutdown request.
      #
      # A Ractor ends as soon as its main block returns, even with threads still
      # asleep, so there is nothing to clean up here.
      def start_watcher(system_port)
        me = Ractor.current
        Thread.new(system_port, me) do |port, ractor|
          _tag, reason = port.receive
          request_shutdown(reason)
          ractor.send(Protocol::SHUTDOWN_SENTINEL)
        rescue Ractor::ClosedError
          # This Ractor is already on its way out; there is nobody left to wake.
          nil
        end
      end

      # Called from the watcher thread.
      def request_shutdown(reason)
        @shutdown_reason = reason
        @shutdown = true
        @wake.push(true)
      end

      # @api private
      def publish(event)
        return unless @event_port

        @event_port << event
      rescue Ractor::ClosedError
        # The subscriber is gone. Losing observability must not take the child down.
        nil
      end

      private

      def supervisor_path = @supervisor&.path || @path

      def now = Process.clock_gettime(Process::CLOCK_REALTIME)
    end
  end
end
