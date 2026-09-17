# frozen_string_literal: true

module RactorShepherd
  module Core
    # Decides whether a child should be restarted, from its restart kind and how it exited.
    #
    # Exits the supervisor asked for do not go through this table; the shutdown
    # path handles those.
    #
    # @api private
    module RestartPolicy
      # | restart \ status | :exited          | :aborted |
      # |------------------|------------------|----------|
      # | :permanent       | :restart         | :restart |
      # | :transient       | :keep_terminated | :restart |
      # | :temporary       | :remove          | :remove  |
      TABLE = Ractor.make_shareable({
                                      permanent: { exited: :restart, aborted: :restart },
                                      transient: { exited: :keep_terminated, aborted: :restart },
                                      temporary: { exited: :remove, aborted: :remove }
                                    })

      # @return [Symbol] :restart, :keep_terminated or :remove
      def self.decide(restart:, status:, dynamic: false)
        by_status = TABLE[restart] or raise ArgumentError, "unknown restart: #{restart.inspect}"
        decision = by_status[status] or raise ArgumentError, "unknown status: #{status.inspect}"
        # A dynamic supervisor keeps no spec around, so "stay terminated" becomes "forget it".
        return :remove if dynamic && decision == :keep_terminated

        decision
      end
    end
  end
end
