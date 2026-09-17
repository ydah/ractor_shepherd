# frozen_string_literal: true

module RactorShepherd
  module Runtime
    # A synchronous request/response over a one-shot reply port.
    #
    # Ruby 4.0's `Ractor#unmonitor` looks registrations up by port id alone and
    # ignores which Ractor created the port. Since port ids are a per Ractor
    # sequence, unmonitoring can silently drop *another* Ractor's monitor of the
    # same target, which would leave a supervisor blind to its own child dying.
    # So this gem never calls `unmonitor`. See DESIGN.md F24 and the reproduction
    # in spike/unmonitor_id_collision.rb.
    #
    # Registrations we cannot remove would pile up if every call added one, so a
    # call with a finite timeout does not monitor at all: a dead target is found
    # out either when the send raises ClosedError, or after the timeout by
    # checking whether the target is still alive.
    #
    # ponytail: one port and one timer thread per call. Hot paths should use
    # `cast` or their own port instead; the README says so.
    #
    # @api private
    module Call
      module_function

      # @param target_ractor [Ractor] the Ractor being called
      # @param target_port [Ractor::Port, Ractor] where the request goes
      # @param timeout [Numeric, :infinity]
      # @param down_error [Class] raised when the target is not running
      # @return [Object] the reply payload
      def perform(target_ractor, target_port, request, timeout: 5, down_error: SupervisorDown)
        reply = Ractor::Port.new
        timer = nil
        if timeout == :infinity
          # Only an unbounded call needs a monitor, so that it cannot wait forever.
          # monitor returns false when the target has already finished.
          raise down_error, down_message(target_ractor, "is not running") unless target_ractor.monitor(reply)
        else
          timer = Timer.for_current_ractor.after(timeout, reply, Protocol.timeout(0))
        end

        begin
          target_port << Protocol.call(reply, request)
        rescue Ractor::ClosedError
          # Sending to something that has already finished raises ClosedError.
          raise down_error, down_message(target_ractor, "is not running")
        end

        await(reply, target_ractor, down_error)
      ensure
        timer&.cancel
        reply&.close
      end

      def await(reply, target_ractor, down_error)
        case (msg = reply.receive)
        in [Protocol::REPLY, result] then result
        in [Protocol::TIMEOUT, _]
          raise down_error, down_message(target_ractor, "terminated while handling the call") if
            terminated?(target_ractor)

          raise CallTimeout, down_message(target_ractor, "did not reply within the timeout")
        else
          # A monitor notification; Compat validates its shape. The target went down.
          Compat.monitor_status(msg)
          raise down_error, down_message(target_ractor, "terminated while handling the call")
        end
      end

      # Has the target finished?
      #
      # When it is still alive this leaves one monitor registration behind,
      # because unmonitor is unusable. Timeouts are an exceptional path, so
      # these do not accumulate.
      def terminated?(ractor)
        probe = Ractor::Port.new
        !ractor.monitor(probe)
      ensure
        probe.close
      end

      def down_message(ractor, suffix)
        "#{ractor.name || ractor.inspect} #{suffix}"
      end

      private_class_method :await, :terminated?, :down_message
    end
  end
end
