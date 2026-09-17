# frozen_string_literal: true

module RactorShepherd
  # Base class for every error this gem raises.
  #
  # Exceptions are copied across Ractor boundaries, so keep their instance
  # variables to simple values: symbols, numbers, frozen strings.
  class Error < StandardError; end

  # A ChildSpec or SupervisorSpec is invalid.
  class InvalidSpec < Error; end

  # Loaded on a Ruby that does not meet the requirements.
  class UnsupportedRuby < Error; end

  # The initial boot failed. The child's exception is the cause.
  class StartError < Error; end

  # Raised by #join when the supervisor had escalated instead of stopping.
  class SupervisorCrashed < Error; end

  # Restart intensity exceeded. Raised inside a supervisor and propagated to its parent.
  class MaxRestartsExceeded < Error; end

  # A child did not acknowledge a shutdown request, or did not finish starting, in time.
  class ChildUnresponsive < Error; end

  # A synchronous call timed out.
  class CallTimeout < Error; end

  # The supervisor being called is not running.
  class SupervisorDown < Error; end

  # The worker being called is not running.
  class WorkerDown < Error; end

  # No child with that id.
  class ChildNotFound < Error; end

  # The child exists but has no running Ractor right now (it is being restarted).
  class ChildUnavailable < Error; end

  # The operation does not apply in the current state.
  class InvalidOperation < Error; end

  # A dynamic supervisor is already at max_children.
  class MaxChildrenReached < Error; end

  # An unexpected message shape arrived. Signals a bug.
  class ProtocolError < Error; end

  # Signals that a shutdown was requested.
  #
  # It inherits Exception rather than StandardError so that a plain
  # `rescue => e` in user code cannot swallow it.
  class ShutdownSignal < Exception; end # rubocop:disable Lint/InheritException
end
