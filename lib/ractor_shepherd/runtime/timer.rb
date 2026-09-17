# frozen_string_literal: true

module RactorShepherd
  module Runtime
    # Sends a message to a port after a delay.
    #
    # Ruby 4.0 has no `Ractor::Port#receive(timeout:)`, so every timed wait in
    # this gem is built from a Timer plus `Ractor.select`.
    #
    # ponytail: one thread per timer. If timers ever run into the thousands,
    # swap the implementation for a single thread with a time ordered queue;
    # the interface is already shaped for that.
    #
    # @api private
    class Timer
      RACTOR_KEY = :"ractor_shepherd.timer"

      # A handle on one pending message.
      class Handle
        def initialize(thread)
          @thread = thread
        end

        # Cancel before it fires. Calling this afterwards is harmless.
        def cancel
          @thread.kill
          nil
        end

        def pending? = @thread.alive?
      end

      # One timer per Ractor, kept in Ractor local storage.
      def self.for_current_ractor
        Ractor[RACTOR_KEY] ||= new
      end

      # @param seconds [Numeric] the delay
      # @param port [Ractor::Port, Ractor] anything that answers `<<`
      # @param message [Object] what to send; must be shareable
      # @return [Handle]
      def after(seconds, port, message)
        Handle.new(Thread.new(seconds, port, message) do |sec, pt, msg|
          Kernel.sleep(sec)
          pt << msg
        rescue Ractor::ClosedError
          # Whoever was waiting has already gone. Nothing left to do.
          nil
        end)
      end
    end
  end
end
