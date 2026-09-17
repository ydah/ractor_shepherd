# frozen_string_literal: true

module RactorShepherd
  module Runtime
    # Builds and recognises the messages this gem sends.
    #
    # Reserved names start with `:"$"`. No message symbol is spelled out
    # anywhere else in the codebase.
    #
    # @api private
    module Protocol
      RESERVED_PREFIX = "$"

      CHILD_READY = :"$child_ready"
      SHUTDOWN = :"$shutdown"
      CALL = :"$call"
      REPLY = :"$reply"
      TIMEOUT = :"$timeout"
      RESTART_DUE = :"$restart_due"
      SHUTDOWN_SENTINEL = :"$shutdown_sentinel"

      module_function

      # Child to start port: the child has finished starting.
      #
      # @param ref [Ractor, SupervisorRef] the child's own Ractor, or its SupervisorRef
      # @param stop_port [Ractor::Port] a worker's system port, or a supervisor's control port
      def child_ready(id, stop_port, ref) = [CHILD_READY, id, stop_port, ref].freeze

      # Parent or API to a child's stop port: please shut down.
      def shutdown(reason) = [SHUTDOWN, reason].freeze

      # Caller to a control port or a worker's default port.
      def call(reply_port, request) = [CALL, reply_port, request].freeze

      # Responder to a reply port.
      def reply(result) = [REPLY, result].freeze

      # Timer to whatever port is being waited on. `seq` tells stale notifications apart.
      def timeout(seq) = [TIMEOUT, seq].freeze

      # Timer to a supervisor's timer port: a delayed restart is due.
      def restart_due(generation, ids) = [RESTART_DUE, generation, ids].freeze

      # Is this one of the messages this gem reserves?
      def reserved?(message)
        case message
        when Symbol then message.start_with?(RESERVED_PREFIX)
        when Array then message[0].is_a?(Symbol) && message[0].start_with?(RESERVED_PREFIX)
        else false
        end
      end
    end
  end
end
