# frozen_string_literal: true

module RactorShepherd
  module Runtime
    # A child's mutable state, which lives only inside the supervisor's Ractor.
    #
    # @api private
    class ChildState
      STATUSES = %i[starting running stopping exited terminated restart_scheduled
                    start_failed unresponsive removed].freeze

      attr_reader :spec, :backoff
      attr_accessor :status, :ractor, :stop_port, :ref, :monitor_port, :restart_count

      def initialize(spec, reset_after:)
        @spec = spec
        @status = :starting
        @ractor = nil
        @stop_port = nil
        @ref = nil
        @monitor_port = nil
        @restart_count = 0
        @backoff = Core::Backoff.new(spec.restart_delay, reset_after: reset_after)
      end

      def id = spec.id
      def type = spec.type
      def running? = status == :running

      # Let go of the Ractor and its ports once the child has exited.
      def detach
        @ractor = nil
        @stop_port = nil
        @ref = nil
        @monitor_port = nil
      end

      # What the outside world sees.
      def to_info
        ChildInfo.new(id: id, type: type, status: status,
                      ref: running? ? ref : nil, restart_count: restart_count)
      end

      # What the strategy planner needs.
      def to_view
        Core::StrategyPlanner::ChildView.new(id: id, restart: spec.restart, alive: running?)
      end
    end
  end
end
