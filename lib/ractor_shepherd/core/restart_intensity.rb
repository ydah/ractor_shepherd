# frozen_string_literal: true

module RactorShepherd
  # Pure logic: no Ractors, no threads, no clock reads. The caller passes the time in.
  module Core
    # Give up once there have been more than `max_restarts` restarts within `max_seconds`.
    #
    # @api private
    class RestartIntensity
      attr_reader :max_restarts, :max_seconds

      def initialize(max_restarts:, max_seconds:)
        @max_restarts = max_restarts
        @max_seconds = max_seconds
        @times = []
      end

      # Call this once per failure, even when the strategy restarts several children.
      #
      # @param now [Float] CLOCK_MONOTONIC
      # @return [Symbol] :ok or :exceeded
      def record(now)
        @times.reject! { |t| now - t > max_seconds }
        @times << now
        @times.size > max_restarts ? :exceeded : :ok
      end

      # @return [Integer] restarts still inside the window
      def count = @times.size
    end
  end
end
