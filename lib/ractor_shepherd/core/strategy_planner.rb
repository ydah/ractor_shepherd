# frozen_string_literal: true

module RactorShepherd
  module Core
    # Turns a restart strategy into the concrete list of children to stop and start.
    #
    # @api private
    module StrategyPlanner
      # The little that the planner needs to know about a child.
      ChildView = Data.define(:id, :restart, :alive)

      # `terminate` is in stop order (reverse of start order), `start` is in start order.
      Plan = Data.define(:terminate, :start, :remove)

      # @param children [Array<ChildView>] in start order
      # @param failed_id [Object] the id of the child that went down
      # @param strategy [Symbol] :one_for_one, :one_for_all or :rest_for_one
      # @return [Plan]
      def self.plan(children:, failed_id:, strategy:)
        index = children.index { |c| c.id == failed_id }
        raise ArgumentError, "unknown child: #{failed_id.inspect}" if index.nil?

        case strategy
        when :one_for_one then Plan.new(terminate: [], start: [failed_id], remove: [])
        when :one_for_all then for_group(children, children, failed_id)
        when :rest_for_one then for_group(children, children[index..], failed_id)
        else raise ArgumentError, "unknown strategy: #{strategy.inspect}"
        end
      end

      # @param scope [Array<ChildView>] the children the strategy reaches, in start order
      def self.for_group(_children, scope, failed_id)
        affected = scope.reject { |c| c.id == failed_id }
        terminate = affected.select(&:alive)
        Plan.new(
          terminate: terminate.map(&:id).reverse,
          start: scope.reject { |c| c.restart == :temporary }.map(&:id),
          remove: terminate.select { |c| c.restart == :temporary }.map(&:id)
        )
      end
      private_class_method :for_group
    end
  end
end
