# frozen_string_literal: true

module RactorShepherd
  # The Ractor shell: everything that touches Ractors, ports, threads and the clock.
  module Runtime
    # Smooths over the Ractor API differences between Ruby 4.0 and 4.1.
    #
    # Decisions are made from the shape of a message rather than from
    # RUBY_VERSION, so development builds such as 4.1.0dev work too.
    #
    # @api private
    module Compat
      # @raise [UnsupportedRuby] when Ractor::Port is missing
      def self.check!
        return if defined?(::Ractor::Port)

        raise UnsupportedRuby,
              "ractor_shepherd requires Ruby >= 4.0 with Ractor::Port (running #{RUBY_VERSION})"
      end

      # Normalise a Ractor#monitor notification to :exited or :aborted.
      #
      # Ruby 4.0 sends a bare Symbol, Ruby 4.1 sends [ractor, status].
      def self.monitor_status(msg)
        case msg
        in :exited | :aborted then msg
        in [::Ractor, (:exited | :aborted) => status] then status
        else raise ProtocolError, "unexpected monitor message: #{msg.inspect}"
        end
      end

      # Does Ractor::Port#receive take a timeout: keyword?
      #
      # Ruby 4.0 has no such keyword, so every timed wait goes through
      # Runtime::Timer and Ractor.select. Kept for a future optimisation.
      def self.native_receive_timeout?
        ::Ractor::Port.instance_method(:receive).parameters.any? { |kind, name| kind == :key && name == :timeout }
      end
    end
  end
end
