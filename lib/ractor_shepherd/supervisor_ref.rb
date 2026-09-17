# frozen_string_literal: true

module RactorShepherd
  # What `which_children` reports about one child.
  ChildInfo = Data.define(:id, :type, :status, :ref, :restart_count)

  # Maps an error name reported by a supervisor back to its class.
  REMOTE_ERRORS = Ractor.make_shareable(
    [ChildNotFound, ChildUnavailable, InvalidOperation, InvalidSpec,
     MaxChildrenReached, ProtocolError, StartError].to_h { |klass| [klass.name, klass] }
  )

  # A handle on a supervisor.
  #
  # It is shareable, so it can be handed to children or sent to other Ractors.
  # Every query is a synchronous call over the control port, with a default
  # timeout of five seconds.
  SupervisorRef = Data.define(:name, :path, :ractor, :control_port) do
    # @return [Array<ChildInfo>]
    def which_children(timeout: 5) = request([:which_children], timeout)

    # @return [Hash] { specs:, active:, workers:, supervisors: }
    def count_children(timeout: 5) = request([:count_children], timeout)

    # @return [Ractor, SupervisorRef, nil] nil while the child is being restarted
    def whereis(id, timeout: 5) = request([:whereis, id], timeout)

    # Build a lazily resolved address.
    #
    #   sup.lookup(:jobs, :poller).cast([:refresh])
    #
    # @return [Address]
    def lookup(*path, retries: 3, resolve_timeout: 1.0)
      Address.new(self, path, retries: retries, resolve_timeout: resolve_timeout)
    end

    # @return [Object] the id of the child that was added
    def start_child(child_spec, timeout: 5) = request([:start_child, child_spec], timeout)

    def terminate_child(id, timeout: 5) = request([:terminate_child, id], timeout)
    def restart_child(id, timeout: 5) = request([:restart_child, id], timeout)
    def delete_child(id, timeout: 5) = request([:delete_child, id], timeout)

    # Stop every child in reverse order, then the supervisor, and wait for it to finish.
    #
    # Returns true right away if it had already stopped.
    def stop(reason = :normal, timeout: :infinity)
      port = Ractor::Port.new
      timer = nil
      return true unless ractor.monitor(port) # already finished

      timer = Runtime::Timer.for_current_ractor.after(timeout, port, Runtime::Protocol.timeout(0)) unless
        timeout == :infinity
      return true unless send_shutdown(reason) # it finished just before we asked

      case port.receive
      in [Runtime::Protocol::TIMEOUT, _] then raise CallTimeout, "#{path} did not stop within #{timeout}s"
      else true # a monitor notification: it stopped
      end
    ensure
      timer&.cancel
      # unmonitor is unusable (see Runtime::Call). Just close the port.
      port&.close
    end

    # Leaves one monitor registration behind when the supervisor is alive,
    # because unmonitor is unusable (see Runtime::Call).
    def alive?
      port = Ractor::Port.new
      ractor.monitor(port)
    ensure
      port&.close
    end

    # Wait for the supervisor to finish.
    #
    # Call this only from the Ractor that started it: once another Ractor has
    # taken a Ractor's value, nobody else can.
    #
    # @raise [SupervisorCrashed] if it escalated instead of stopping
    def join
      ractor.value
      self
    rescue Ractor::RemoteError => e
      raise SupervisorCrashed, "#{path} crashed: #{e.cause.class}: #{e.cause.message}", cause: e.cause
    end

    private

    def send_shutdown(reason)
      control_port << Runtime::Protocol.shutdown(reason)
      true
    rescue Ractor::ClosedError
      false
    end

    def request(body, timeout)
      case Runtime::Call.perform(ractor, control_port, body, timeout: timeout, down_error: SupervisorDown)
      in [:ok, value] then value
      in [:error, error_class, message] then raise(REMOTE_ERRORS.fetch(error_class, Error), message)
      end
    end
  end
end
