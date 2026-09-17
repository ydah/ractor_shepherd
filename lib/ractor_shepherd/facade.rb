# frozen_string_literal: true

# The public entry points.
module RactorShepherd
  class << self
    # Start a root supervisor.
    #
    # Starting is synchronous: this returns once every child's `initialize` has
    # finished. If one of them fails, the children that already started are
    # stopped in reverse order and {StartError} is raised.
    #
    # @return [SupervisorRef]
    def start(name:, strategy: :one_for_one, children: [], max_restarts: 3, max_seconds: 5.0,
              on_unresponsive: :escalate, event_port: nil, boot_timeout: 30)
      spec = Validator.root_spec(kind: :static, strategy: strategy, children: children,
                                 max_restarts: max_restarts, max_seconds: max_seconds,
                                 on_unresponsive: on_unresponsive)
      Runtime::SupervisorServer.boot(spec, name: name, event_port: event_port, boot_timeout: boot_timeout)
    end

    # Start a root dynamic supervisor, which begins with no children.
    #
    # @return [SupervisorRef]
    def start_dynamic(name:, max_children: nil, max_restarts: 3, max_seconds: 5.0,
                      on_unresponsive: :escalate, event_port: nil, boot_timeout: 30)
      spec = Validator.root_spec(kind: :dynamic, strategy: :one_for_one, children: [],
                                 max_restarts: max_restarts, max_seconds: max_seconds,
                                 max_children: max_children, on_unresponsive: on_unresponsive)
      Runtime::SupervisorServer.boot(spec, name: name, event_port: event_port, boot_timeout: boot_timeout)
    end

    # Start a supervisor, yield it, and stop it on the way out.
    def run(**)
      supervisor = start(**)
      begin
        yield supervisor
      ensure
        supervisor.stop
      end
    end

    # Describe a worker child.
    #
    # @param id [Symbol, Integer, String] unique within its supervisor
    # @param klass [Class] a class that includes RactorShepherd::Worker
    def worker(id, klass, args: [], kwargs: {}, restart: :permanent,
               shutdown_timeout: 5.0, start_timeout: 5.0, restart_delay: nil)
      Validator.worker_spec(id, klass, args: args, kwargs: kwargs, restart: restart,
                                       shutdown_timeout: shutdown_timeout, start_timeout: start_timeout,
                                       restart_delay: restart_delay, allow_nil_id: id.nil?)
    end

    # Describe a supervisor child.
    def supervisor(id, strategy: :one_for_one, children: [], max_restarts: 3, max_seconds: 5.0,
                   on_unresponsive: :escalate, restart: :permanent,
                   shutdown_timeout: :infinity, start_timeout: :infinity, restart_delay: nil)
      Validator.supervisor_spec(id, kind: :static, strategy: strategy, children: children,
                                    max_restarts: max_restarts, max_seconds: max_seconds,
                                    on_unresponsive: on_unresponsive, restart: restart,
                                    shutdown_timeout: shutdown_timeout, start_timeout: start_timeout,
                                    restart_delay: restart_delay)
    end

    # Describe a dynamic supervisor child.
    def dynamic_supervisor(id, max_children: nil, max_restarts: 3, max_seconds: 5.0,
                           on_unresponsive: :escalate, restart: :permanent,
                           shutdown_timeout: :infinity, start_timeout: :infinity, restart_delay: nil)
      Validator.supervisor_spec(id, kind: :dynamic, strategy: :one_for_one, children: [],
                                    max_restarts: max_restarts, max_seconds: max_seconds,
                                    max_children: max_children, on_unresponsive: on_unresponsive,
                                    restart: restart, shutdown_timeout: shutdown_timeout,
                                    start_timeout: start_timeout, restart_delay: restart_delay)
    end
  end
end
