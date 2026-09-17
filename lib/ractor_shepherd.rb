# frozen_string_literal: true

require_relative "ractor_shepherd/version"
require_relative "ractor_shepherd/errors"
require_relative "ractor_shepherd/runtime/compat"

RactorShepherd::Runtime::Compat.check!

require_relative "ractor_shepherd/worker"
require_relative "ractor_shepherd/core/backoff"
require_relative "ractor_shepherd/core/event"
require_relative "ractor_shepherd/core/restart_intensity"
require_relative "ractor_shepherd/core/restart_policy"
require_relative "ractor_shepherd/core/strategy_planner"
require_relative "ractor_shepherd/spec"
require_relative "ractor_shepherd/runtime/protocol"
require_relative "ractor_shepherd/runtime/timer"
require_relative "ractor_shepherd/runtime/call"
require_relative "ractor_shepherd/runtime/context"
require_relative "ractor_shepherd/server"
require_relative "ractor_shepherd/runtime/child_state"
require_relative "ractor_shepherd/runtime/child_runner"
require_relative "ractor_shepherd/runtime/supervisor_server"
require_relative "ractor_shepherd/supervisor_ref"
require_relative "ractor_shepherd/address"
require_relative "ractor_shepherd/event_logger"
require_relative "ractor_shepherd/facade"

# Supervise Ractors the way Erlang/OTP supervisors do.
#
# A supervisor starts its children, watches them, restarts them according to a
# declared policy, and escalates to its own parent when restarting stops helping.
# Supervisors can themselves be children, so trees are just supervisors all the way down.
#
# @see DESIGN.md
module RactorShepherd
end
