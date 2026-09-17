# frozen_string_literal: true

module RactorShepherd
  module Runtime
    # Everything that runs inside a supervisor's Ractor.
    #
    # Whether to restart, and which children to stop, is decided in Core.
    # This class only carries out the resulting plan.
    #
    # @api private
    class SupervisorServer
      # Called from the caller's Ractor: creates the supervisor Ractor and waits for it to boot.
      #
      # @return [SupervisorRef]
      def self.boot(spec, name:, event_port: nil, boot_timeout: 30)
        path = name.to_s.freeze
        boot_port = Ractor::Port.new
        timer = nil
        ractor = Ractor.new(spec, boot_port, event_port, path, name: "shepherd:#{path}") do |sp, bp, ep, pa|
          RactorShepherd::Runtime::SupervisorServer.run_root(sp, bp, ep, pa)
        end
        # monitor before reading, so a crash during boot is never missed;
        # a Ractor that has already finished notifies immediately.
        ractor.monitor(boot_port)
        timer = Timer.for_current_ractor.after(boot_timeout, boot_port, Protocol.timeout(0)) unless
          boot_timeout == :infinity

        case boot_port.receive
        in [Protocol::CHILD_READY, _id, _control_port, ref] then ref
        in [Protocol::TIMEOUT, _] then raise StartError, "#{path} did not finish booting within #{boot_timeout}s"
        else raise_boot_error(ractor, path)
        end
      ensure
        timer&.cancel
        # unmonitor is unusable (see Runtime::Call). Notifications to a closed port are dropped.
        boot_port.close
      end

      # The supervisor Ractor aborted. Surface the exception it raised.
      def self.raise_boot_error(ractor, path)
        ractor.value
        raise StartError, "#{path} exited during boot"
      rescue Ractor::RemoteError => e
        inner = e.cause
        # Without an explicit cause:, Ruby would set the RemoteError as the cause
        # and the chain would loop back on itself.
        raise inner, cause: inner.cause if inner.is_a?(StartError)

        raise StartError, "#{path} failed to boot: #{inner.class}: #{inner.message}", cause: inner
      end
      private_class_method :raise_boot_error

      # Entry point for a root supervisor's Ractor.
      def self.run_root(spec, boot_port, event_port, path)
        # Report crashes through events instead of dumping a backtrace on stderr.
        Thread.current.report_on_exception = false
        new(spec, name: path, path: path, event_port: event_port).run(boot_port)
      end

      # Entry point when this supervisor is itself somebody's child.
      def self.run_as_child(child_spec, start_port, _parent_ref, event_port, path)
        Thread.current.report_on_exception = false
        new(child_spec.start, name: child_spec.id, path: path, event_port: event_port).run(start_port)
      end

      def initialize(spec, name:, path:, event_port:)
        @spec = spec
        @name = name
        @path = path
        @event_port = event_port
        @children = {}
        @monitor_index = {}.compare_by_identity # Ractor.select returns the very port we passed in
        @state = :booting
        @generation = 0
        @next_auto_id = 0
        @intensity = Core::RestartIntensity.new(max_restarts: spec.max_restarts, max_seconds: spec.max_seconds)
        @timer = Timer.for_current_ractor
      end

      attr_reader :path

      # Boot, then run the watch loop. Returns once the supervisor has stopped.
      def run(ready_port)
        @control_port = Ractor::Port.new
        @timer_port = Ractor::Port.new
        @self_ref = Ractor.make_shareable(
          SupervisorRef.new(name: @name, path: @path, ractor: Ractor.current, control_port: @control_port)
        )

        boot_children
        @state = :running
        emit(:supervisor_started, children: @children.keys)
        ready_port << Protocol.child_ready(@name, @control_port, @self_ref)

        main_loop
        @state
      end

      # --- starting ---------------------------------------------------------

      def boot_children
        @spec.children.each do |child_spec|
          child = add_child(child_spec)
          result = start_child_sync(child)
          next if result == :ok

          rollback_boot!(child, result)
        end
      end

      # The initial boot failed: stop whatever already started, in reverse order, then raise.
      def rollback_boot!(child, result)
        running_children.reverse_each do |other|
          terminate_child_sync(other, :shutdown, requested_by: :shutdown, on_unresponsive: :abandon)
        end
        reason = result.is_a?(Array) ? result[1] : nil
        message = "#{@path}: child #{child.id.inspect} failed to start"
        raise StartError, message, cause: (reason if reason.is_a?(Exception))
      end

      # Start a child Ractor and wait synchronously for its child_ready.
      #
      # @return [Symbol, Array] :ok | [:failed, reason] | [:unresponsive]
      def start_child_sync(child)
        spec = child.spec
        start_port = Ractor::Port.new
        timer = nil
        child.status = :starting
        child_path = "#{@path}/#{spec.id}".freeze
        ractor = Ractor.new(spec, start_port, @self_ref, @event_port, child_path,
                            name: "shepherd:#{child_path}") do |sp, stp, pr, ep, pa|
          RactorShepherd::Runtime::ChildRunner.run(sp, stp, pr, ep, pa)
        end
        ractor.monitor(start_port)
        timer = @timer.after(spec.start_timeout, start_port, Protocol.timeout(0)) unless
          spec.start_timeout == :infinity

        await_start(child, ractor, start_port)
      ensure
        timer&.cancel
        # unmonitor is unusable (see Runtime::Call). Notifications to a closed port are dropped.
        start_port.close
      end

      def await_start(child, ractor, start_port)
        case start_port.receive
        in [Protocol::CHILD_READY, _id, stop_port, ref]
          activate(child, ractor, stop_port, ref)
          :ok
        in [Protocol::TIMEOUT, _]
          child.status = :unresponsive
          emit(:child_unresponsive, child: child.id, phase: :start,
                                    timeout: child.spec.start_timeout, action: @spec.on_unresponsive)
          [:unresponsive]
        else
          child.status = :start_failed
          reason = exit_reason(ractor)
          emit(:child_start_failed, child: child.id, **Core::Event.error_info(reason))
          [:failed, reason]
        end
      end

      def activate(child, ractor, stop_port, ref)
        child.ractor = ractor
        child.stop_port = stop_port
        child.ref = ref
        child.status = :running
        child.monitor_port = Ractor::Port.new
        # Even if it has already finished, the notification arrives at once, so ignore the result.
        ractor.monitor(child.monitor_port)
        @monitor_index[child.monitor_port] = child
        child.backoff.record_start(now)
        emit(:child_started, child: child.id, ractor_name: ractor.name, attempt: child.backoff.attempt)
      end

      # --- watch loop -------------------------------------------------------

      def main_loop
        while @state == :running # `loop do` is forbidden here: Ractor::ClosedError < StopIteration
          port, message = Ractor.select(@control_port, @timer_port, *@monitor_index.keys)
          if port.equal?(@control_port)
            handle_control(message)
          elsif port.equal?(@timer_port)
            handle_timer(message)
          else
            child = @monitor_index.delete(port)
            port.close
            handle_exit(child, Compat.monitor_status(message)) if child
          end
        end
      end

      def handle_control(message)
        case message
        in [Protocol::CALL, reply_port, request] then reply(reply_port, request)
        in [Protocol::SHUTDOWN, reason] then shutdown(reason)
        else raise ProtocolError, "unexpected control message: #{message.inspect}"
        end
      end

      def handle_timer(message)
        case message
        in [Protocol::RESTART_DUE, generation, ids]
          # Ignore a booking made before the last shutdown or escalation.
          start_children(ids) if generation == @generation
        else raise ProtocolError, "unexpected timer message: #{message.inspect}"
        end
      end

      # Answer user input errors and carry on. Anything else takes the supervisor down (let it crash).
      def reply(reply_port, request)
        result = begin
          [:ok, handle_request(request)]
        rescue Error => e
          [:error, e.class.name, e.message]
        end
        reply_port << Protocol.reply(result)
      rescue Ractor::ClosedError
        # The caller timed out and went away. Drop the answer.
        nil
      end

      def handle_request(request)
        case request
        in [:which_children] then @children.values.map(&:to_info)
        in [:count_children] then count_children
        in [:whereis, id] then find_child(id).then { |c| c.running? ? c.ref : nil }
        in [:start_child, spec] then add_and_start(spec)
        in [:terminate_child, id] then api_terminate_child(id)
        in [:restart_child, id] then api_restart_child(id)
        in [:delete_child, id] then api_delete_child(id)
        else raise ProtocolError, "unexpected request: #{request.inspect}"
        end
      end

      def count_children
        values = @children.values
        { specs: values.size,
          active: values.count(&:running?),
          workers: values.count { |c| c.type == :worker },
          supervisors: values.count { |c| c.type == :supervisor } }
      end

      # --- noticing an exit -------------------------------------------------

      def handle_exit(child, status)
        reason = status == :aborted ? exit_reason(child.ractor) : :normal
        emit(:child_exited, child: child.id, status: status,
                            reason: Core::Event.reason_kind(reason), **Core::Event.error_info(reason))
        child.detach
        child.status = :exited

        case Core::RestartPolicy.decide(restart: child.spec.restart, status: status, dynamic: dynamic?)
        when :keep_terminated then child.status = :terminated
        when :remove then remove_child(child)
        when :restart then restart_after_failure(child)
        end
      end

      # Dig the reason out of a Ractor that aborted.
      def exit_reason(ractor)
        ractor.value
        :unknown
      rescue Ractor::RemoteError => e
        e.cause
      rescue Ractor::Error
        # Another Ractor took the value first, so the reason is lost. Restart anyway.
        :unknown
      end

      # --- restarting -------------------------------------------------------

      def restart_after_failure(child)
        return escalate!(MaxRestartsExceeded.new(intensity_message)) if @intensity.record(now) == :exceeded

        child.restart_count += 1
        child.backoff.record_failure(now)
        plan = Core::StrategyPlanner.plan(children: views, failed_id: child.id, strategy: @spec.strategy)
        apply_plan(plan, delay: child.backoff.delay)
      end

      def apply_plan(plan, delay: 0)
        plan.terminate.each do |id|
          terminate_child_sync(@children.fetch(id), :shutdown, requested_by: :strategy)
        end
        plan.remove.each { |id| remove_child(@children.fetch(id)) }
        schedule_or_start(plan.start, delay)
      end

      def schedule_or_start(ids, delay)
        ids = ids.select { |id| @children.key?(id) }
        return if ids.empty?
        return start_children(ids) if delay.nil? || delay <= 0

        ids.each do |id|
          child = @children.fetch(id)
          child.status = :restart_scheduled
          emit(:child_restart_scheduled, child: id, delay: delay, attempt: child.backoff.attempt)
        end
        @timer.after(delay, @timer_port, Protocol.restart_due(@generation, ids.freeze))
      end

      # Start in order. A failure costs one restart from the budget, and the rest are retried in order.
      def start_children(ids)
        ids.each_with_index do |id, index|
          child = @children[id]
          next unless child
          next if start_child_sync(child) == :ok

          return escalate!(MaxRestartsExceeded.new(intensity_message)) if @intensity.record(now) == :exceeded

          child.backoff.record_failure(now)
          return schedule_or_start(ids[index..], child.backoff.delay)
        end
      end

      # --- stopping ---------------------------------------------------------

      def shutdown(reason)
        @state = :stopping
        @generation += 1
        emit(:supervisor_stopping, reason: reason)
        running_or_scheduled.reverse_each { |child| terminate_child_sync(child, reason, requested_by: :shutdown) }
        emit(:supervisor_stopped, reason: reason)
        @state = :stopped
      end

      # Cooperative shutdown, one child at a time, in reverse start order.
      def terminate_child_sync(child, reason, requested_by:, on_unresponsive: @spec.on_unresponsive)
        if child.status == :restart_scheduled
          child.status = :terminated
          emit(:child_terminated, child: child.id, requested_by: requested_by)
          return
        end
        return unless child.running?

        child.status = :stopping
        request_stop(child, reason)
        await_stop(child, requested_by, on_unresponsive)
      end

      def request_stop(child, reason)
        child.stop_port << Protocol.shutdown(reason)
      rescue Ractor::ClosedError
        # It has already finished; its monitor port is holding the notification, so just wait for it.
        nil
      end

      def await_stop(child, requested_by, on_unresponsive)
        op_port = Ractor::Port.new
        timer = nil
        timer = @timer.after(child.spec.shutdown_timeout, op_port, Protocol.timeout(0)) unless
          child.spec.shutdown_timeout == :infinity

        port, = Ractor.select(child.monitor_port, op_port)
        if port.equal?(op_port)
          handle_unresponsive(child, on_unresponsive)
        else
          forget_monitor(child)
          child.status = :terminated
          child.detach
          emit(:child_terminated, child: child.id, requested_by: requested_by)
        end
      ensure
        timer&.cancel
        op_port.close
      end

      def handle_unresponsive(child, on_unresponsive)
        emit(:child_unresponsive, child: child.id, phase: :stop,
                                  timeout: child.spec.shutdown_timeout, action: on_unresponsive)
        forget_monitor(child)
        child.status = :unresponsive
        return remove_child(child) if on_unresponsive == :abandon

        escalate!(ChildUnresponsive.new("#{@path}/#{child.id} did not stop within " \
                                        "#{child.spec.shutdown_timeout}s"))
      end

      # Give up: crash this supervisor so that its parent decides what happens next.
      def escalate!(error)
        @state = :crashed
        @generation += 1
        if error.is_a?(MaxRestartsExceeded)
          emit(:max_restarts_exceeded, restarts: @intensity.count, max_restarts: @spec.max_restarts,
                                       max_seconds: @spec.max_seconds)
        end
        running_children.reverse_each do |child|
          # Always abandon here, so that escalation cannot escalate again.
          terminate_child_sync(child, :shutdown, requested_by: :shutdown, on_unresponsive: :abandon)
        end
        emit(:supervisor_stopped, reason: error.class.name)
        raise error
      end

      # --- adding and removing children -------------------------------------

      def add_child(spec)
        @children[spec.id] = ChildState.new(spec, reset_after: @spec.max_seconds)
      end

      def remove_child(child)
        child.status = :removed
        @children.delete(child.id)
      end

      def forget_monitor(child)
        return unless child.monitor_port

        @monitor_index.delete(child.monitor_port)
        child.monitor_port.close
      end

      def find_child(id)
        @children[id] or raise ChildNotFound, "#{@path} has no child #{id.inspect}"
      end

      # Add a spec and start it. Dynamic supervisors can number children themselves.
      def add_and_start(spec)
        raise InvalidSpec, "start_child expects a ChildSpec (got #{spec.class})" unless spec.is_a?(ChildSpec)

        spec = assign_id(spec)
        raise InvalidSpec, "duplicated child id: #{spec.id.inspect}" if @children.key?(spec.id) # E13
        if dynamic? && @spec.max_children && @children.size >= @spec.max_children
          raise MaxChildrenReached, "#{@path} already has #{@children.size} children"
        end

        child = add_child(spec)
        result = start_child_sync(child)
        if result != :ok
          remove_child(child)
          raise StartError, "#{@path}: child #{spec.id.inspect} failed to start#{failure_detail(result)}"
        end
        spec.id
      end

      def assign_id(spec)
        return spec unless spec.id.nil?
        raise InvalidSpec, "only dynamic supervisors accept a nil id" unless dynamic?

        @next_auto_id += 1
        Ractor.make_shareable(spec.with(id: @next_auto_id))
      end

      # Cooperative stop. A static supervisor keeps the spec; a dynamic one drops it.
      def api_terminate_child(id)
        child = find_child(id)
        terminate_child_sync(child, :shutdown, requested_by: :api)
        child.status = :terminated
        remove_child(child) if dynamic?
        :ok
      end

      def api_restart_child(id)
        raise InvalidOperation, "dynamic supervisors do not support restart_child" if dynamic?

        child = find_child(id)
        raise InvalidOperation, "#{id.inspect} is #{child.status}, not terminated" unless child.status == :terminated

        result = start_child_sync(child)
        raise StartError, "#{@path}: child #{id.inspect} failed to restart#{failure_detail(result)}" if result != :ok

        :ok
      end

      def api_delete_child(id)
        raise InvalidOperation, "dynamic supervisors do not support delete_child" if dynamic?

        child = find_child(id)
        if child.running? || child.status == :restart_scheduled
          raise InvalidOperation, "#{id.inspect} is #{child.status}; terminate it first"
        end

        remove_child(child)
        :ok
      end

      def failure_detail(result)
        reason = result.is_a?(Array) ? result[1] : nil
        reason.is_a?(Exception) ? " (#{reason.class}: #{reason.message})" : ""
      end

      # --- odds and ends ----------------------------------------------------

      def dynamic? = @spec.kind == :dynamic
      def views = @children.values.map(&:to_view)
      def running_children = @children.values.select(&:running?)
      def running_or_scheduled = @children.values.select { |c| c.running? || c.status == :restart_scheduled }
      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def intensity_message
        "#{@path} exceeded #{@spec.max_restarts} restarts in #{@spec.max_seconds}s"
      end

      def emit(type, **data)
        return unless @event_port

        @event_port << Core::Event.build(type, supervisor: @path, at: Process.clock_gettime(Process::CLOCK_REALTIME),
                                               **data)
      rescue Ractor::ClosedError
        # Only the subscriber is gone. Losing observability must not take the supervisor down.
        nil
      end
    end
  end
end
