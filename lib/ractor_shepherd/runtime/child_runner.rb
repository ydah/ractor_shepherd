# frozen_string_literal: true

module RactorShepherd
  module Runtime
    # What runs inside a child Ractor.
    #
    # A `Ractor.new` block cannot see outer locals or self, so the block that
    # starts a child is a single call to this method with everything passed as
    # arguments.
    #
    # @api private
    module ChildRunner
      module_function

      # @param spec [ChildSpec]
      # @param start_port [Ractor::Port] handshake port, created by the supervisor
      # @param parent_ref [SupervisorRef, nil]
      # @param event_port [Ractor::Port, nil]
      # @param path [String] e.g. "root/jobs/poller"
      def run(spec, start_port, parent_ref, event_port, path)
        # Report crashes through events instead of dumping a backtrace on stderr.
        Thread.current.report_on_exception = false
        return SupervisorServer.run_as_child(spec, start_port, parent_ref, event_port, path) if
          spec.type == :supervisor

        run_worker(spec, start_port, parent_ref, event_port, path)
      end

      def run_worker(spec, start_port, parent_ref, event_port, path)
        system_port = Ractor::Port.new
        ctx = Context.new(id: spec.id, path: path, supervisor: parent_ref, event_port: event_port)
        worker = spec.start.new(*spec.args, **spec.kwargs)

        start_port << Protocol.child_ready(spec.id, system_port, Ractor.current)
        ctx.start_watcher(system_port)

        reason = :normal
        begin
          worker.run(ctx)
          # Returning after a shutdown request still counts as a shutdown.
          reason = :shutdown if ctx.shutdown_requested?
        rescue ShutdownSignal
          reason = :shutdown
        rescue Exception => e # rubocop:disable Lint/RescueException
          reason = e
          raise
        ensure
          call_terminate(worker, reason, ctx)
        end
      end

      # An exception from `terminate` turns a clean exit into a crash. When the
      # worker was already crashing, it is swallowed and recorded as an event so
      # that the original cause survives.
      def call_terminate(worker, reason, ctx)
        worker.terminate(reason)
      rescue Exception => e # rubocop:disable Lint/RescueException
        raise unless reason.is_a?(Exception)

        ctx.emit(:terminate_failed, **Core::Event.error_info(e))
      end
    end
  end
end
