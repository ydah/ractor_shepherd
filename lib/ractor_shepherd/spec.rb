# frozen_string_literal: true

module RactorShepherd
  # What a child is. Immutable and shareable.
  #
  # - `type`: `:worker` or `:supervisor`
  # - `start`: a Class for a worker, a {SupervisorSpec} for a supervisor
  ChildSpec = Data.define(:id, :type, :start, :args, :kwargs, :restart,
                          :shutdown_timeout, :start_timeout, :restart_delay)

  # What a supervisor is. `kind` is `:static` or `:dynamic`.
  SupervisorSpec = Data.define(:kind, :strategy, :children, :max_restarts,
                               :max_seconds, :max_children, :on_unresponsive)

  # Exponential backoff settings.
  BackoffSpec = Data.define(:initial, :max, :factor)

  # Validates and builds specs. Every violation is listed in a single {InvalidSpec}.
  #
  # This is part of the functional core: no Ractors and no clock reads.
  # (`Ractor.make_shareable` is used here purely as a conversion.)
  module Validator
    RESTARTS = %i[permanent transient temporary].freeze
    STRATEGIES = %i[one_for_one one_for_all rest_for_one].freeze
    ON_UNRESPONSIVE = %i[escalate abandon].freeze

    SHAREABLE_HINT = "Procs, Threads and Mutexes cannot cross Ractors. " \
                     "Pass plain values and hand the behaviour over as a class."

    module_function

    # @return [ChildSpec]
    def worker_spec(id, klass, args: [], kwargs: {}, restart: :permanent,
                    shutdown_timeout: 5.0, start_timeout: 5.0, restart_delay: nil, allow_nil_id: false)
      errors = []
      cause = nil

      check_id(errors, id, allow_nil: allow_nil_id)
      check_worker_class(errors, klass)
      shareable_args, cause = share(errors, "args", args, cause)
      shareable_kwargs, cause = share(errors, "kwargs", kwargs, cause)
      check_restart(errors, restart)
      check_timeout(errors, "shutdown_timeout", shutdown_timeout)
      check_timeout(errors, "start_timeout", start_timeout)
      delay = check_restart_delay(errors, restart_delay)

      fail_spec!(errors, "worker #{id.inspect}", cause)

      build(ChildSpec.new(id: id, type: :worker, start: klass,
                          args: shareable_args, kwargs: shareable_kwargs, restart: restart,
                          shutdown_timeout: shutdown_timeout, start_timeout: start_timeout,
                          restart_delay: delay))
    end

    # @return [ChildSpec] type: :supervisor
    def supervisor_spec(id, kind: :static, strategy: :one_for_one, children: [], max_restarts: 3,
                        max_seconds: 5.0, max_children: nil, on_unresponsive: :escalate,
                        restart: :permanent, shutdown_timeout: :infinity, start_timeout: :infinity,
                        restart_delay: nil, allow_nil_id: false)
      errors = []
      check_id(errors, id, allow_nil: allow_nil_id)
      inner = supervisor_body(errors, kind: kind, strategy: strategy, children: children,
                                      max_restarts: max_restarts, max_seconds: max_seconds,
                                      max_children: max_children, on_unresponsive: on_unresponsive)
      check_restart(errors, restart)
      check_timeout(errors, "shutdown_timeout", shutdown_timeout)
      check_timeout(errors, "start_timeout", start_timeout)
      delay = check_restart_delay(errors, restart_delay)

      fail_spec!(errors, "supervisor #{id.inspect}", nil)

      build(ChildSpec.new(id: id, type: :supervisor, start: inner,
                          args: [], kwargs: {}, restart: restart,
                          shutdown_timeout: shutdown_timeout, start_timeout: start_timeout,
                          restart_delay: delay))
    end

    # For a root supervisor: returns a bare {SupervisorSpec}, not wrapped in a ChildSpec.
    def root_spec(kind: :static, strategy: :one_for_one, children: [], max_restarts: 3,
                  max_seconds: 5.0, max_children: nil, on_unresponsive: :escalate)
      errors = []
      inner = supervisor_body(errors, kind: kind, strategy: strategy, children: children,
                                      max_restarts: max_restarts, max_seconds: max_seconds,
                                      max_children: max_children, on_unresponsive: on_unresponsive)
      fail_spec!(errors, "supervisor", nil)
      build(inner)
    end

    # Child ids must be unique within one supervisor.
    def check_unique_ids(errors, children)
      ids = children.filter_map { |c| c.id if c.respond_to?(:id) }
      dups = ids.tally.select { |_, n| n > 1 }.keys
      errors << "duplicated child ids: #{dups.map(&:inspect).join(", ")}" unless dups.empty?
    end

    def supervisor_body(errors, kind:, strategy:, children:, max_restarts:, max_seconds:,
                        max_children:, on_unresponsive:)
      errors << "kind must be :static or :dynamic (got #{kind.inspect})" unless %i[static dynamic].include?(kind)
      strategy = check_strategy(errors, strategy, kind)
      check_children(errors, children, kind)
      check_non_negative_integer(errors, "max_restarts", max_restarts)
      check_positive_number(errors, "max_seconds", max_seconds)
      check_max_children(errors, max_children)
      unless ON_UNRESPONSIVE.include?(on_unresponsive)
        errors << "on_unresponsive must be one of #{ON_UNRESPONSIVE.inspect} (got #{on_unresponsive.inspect})"
      end

      SupervisorSpec.new(kind: kind, strategy: strategy, children: children.dup.freeze,
                         max_restarts: max_restarts, max_seconds: max_seconds,
                         max_children: max_children, on_unresponsive: on_unresponsive)
    end

    def check_id(errors, id, allow_nil: false)
      return if id.nil? && allow_nil
      return if id.is_a?(Symbol) || id.is_a?(Integer)
      return if id.is_a?(String) && id.frozen?

      errors << "id must be a Symbol, an Integer or a frozen String (got #{id.inspect})"
    end

    def check_worker_class(errors, klass)
      unless klass.is_a?(Class)
        errors << "start must be a Class (got #{klass.inspect})"
        return
      end
      return if klass.include?(Worker)

      errors << "#{klass} must include RactorShepherd::Worker"
    end

    def check_restart(errors, restart)
      return if RESTARTS.include?(restart)

      errors << "restart must be one of #{RESTARTS.inspect} (got #{restart.inspect})"
    end

    def check_strategy(errors, strategy, kind)
      if kind == :dynamic
        errors << "dynamic supervisors only support :one_for_one (got #{strategy.inspect})" unless
          strategy == :one_for_one
        return :one_for_one
      end
      errors << "strategy must be one of #{STRATEGIES.inspect} (got #{strategy.inspect})" unless
        STRATEGIES.include?(strategy)
      strategy
    end

    def check_children(errors, children, kind)
      unless children.is_a?(Array)
        errors << "children must be an Array (got #{children.inspect})"
        return
      end
      if kind == :dynamic && !children.empty?
        errors << "dynamic supervisors must start with no children"
        return
      end
      bad = children.grep_v(ChildSpec)
      errors << "children must all be ChildSpec (got #{bad.map(&:class).uniq.inspect})" unless bad.empty?
      check_unique_ids(errors, children)
    end

    def check_timeout(errors, name, value)
      return if value == :infinity
      return if value.is_a?(Numeric) && value.positive?

      errors << "#{name} must be a positive Numeric or :infinity (got #{value.inspect})"
    end

    def check_non_negative_integer(errors, name, value)
      return if value.is_a?(Integer) && !value.negative?

      errors << "#{name} must be an Integer >= 0 (got #{value.inspect})"
    end

    def check_positive_number(errors, name, value)
      return if value.is_a?(Numeric) && value.positive?

      errors << "#{name} must be a positive Numeric (got #{value.inspect})"
    end

    def check_max_children(errors, value)
      return if value.nil?
      return if value.is_a?(Integer) && value >= 1

      errors << "max_children must be nil or an Integer >= 1 (got #{value.inspect})"
    end

    # @return [nil, Numeric, BackoffSpec]
    def check_restart_delay(errors, value)
      case value
      when nil then nil
      when Numeric
        errors << "restart_delay must be >= 0 (got #{value.inspect})" if value.negative?
        value
      when Hash then backoff_spec(errors, value)
      when BackoffSpec then value
      else
        errors << "restart_delay must be nil, a Numeric or a Hash (got #{value.inspect})"
        nil
      end
    end

    def backoff_spec(errors, hash)
      unknown = hash.keys - %i[initial max factor]
      errors << "restart_delay has unknown keys: #{unknown.inspect}" unless unknown.empty?
      initial = hash.fetch(:initial, 0.1)
      max = hash.fetch(:max, 5.0)
      factor = hash.fetch(:factor, 2.0)
      errors << "restart_delay[:initial] must be a Numeric >= 0 (got #{initial.inspect})" unless
        initial.is_a?(Numeric) && !initial.negative?
      errors << "restart_delay[:max] must be a Numeric >= initial (got #{max.inspect})" unless
        max.is_a?(Numeric) && initial.is_a?(Numeric) && max >= initial
      errors << "restart_delay[:factor] must be a Numeric >= 1 (got #{factor.inspect})" unless
        factor.is_a?(Numeric) && factor >= 1
      BackoffSpec.new(initial: initial, max: max, factor: factor)
    end

    # Make a shareable copy without freezing what the caller passed in.
    def share(errors, name, value, cause)
      [Ractor.make_shareable(value, copy: true), cause]
    # Procs and Threads raise TypeError (allocator undefined); Mutexes raise Ractor::Error.
    rescue Ractor::Error, TypeError => e
      errors << "#{name} cannot be shared with a Ractor (#{e.class}: #{e.message}). #{SHAREABLE_HINT}"
      [value, cause || e]
    end

    def fail_spec!(errors, subject, cause)
      return if errors.empty?

      message = "invalid #{subject}:\n" + errors.map { |e| "  - #{e}" }.join("\n")
      raise InvalidSpec, message, cause: cause
    end

    def build(data)
      Ractor.make_shareable(data)
    end
  end
end
