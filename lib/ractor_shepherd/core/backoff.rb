# frozen_string_literal: true

module RactorShepherd
  module Core
    # Works out how long to wait before restarting a child.
    #
    # The consecutive failure count resets to 1 when the child had been up for
    # at least `reset_after` seconds before dying.
    #
    # @api private
    class Backoff
      attr_reader :attempt

      # @param spec [nil, Numeric, BackoffSpec]
      # @param reset_after [Numeric] seconds of uptime after which failures stop counting as consecutive
      def initialize(spec, reset_after:)
        @spec = spec
        @reset_after = reset_after
        @attempt = 0
        @started_at = nil
      end

      # The child came up.
      def record_start(now)
        @started_at = now
      end

      # The child went down, or failed to start.
      #
      # @return [Integer] the consecutive failure count
      def record_failure(now)
        @attempt = if @started_at && (now - @started_at) >= @reset_after
                     1
                   else
                     @attempt + 1
                   end
        @started_at = nil
        @attempt
      end

      # @return [Numeric] seconds to wait before the next start; 0 means right away
      def delay
        return 0 if attempt.zero?

        case @spec
        when nil then 0
        when Numeric then @spec
        when BackoffSpec then [@spec.max, @spec.initial * (@spec.factor**(attempt - 1))].min
        else raise ArgumentError, "unknown restart_delay: #{@spec.inspect}"
        end
      end

      def reset
        @attempt = 0
        @started_at = nil
      end
    end
  end
end
