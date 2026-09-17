# frozen_string_literal: true

# A logger that only answers info, warn and error, to prove the duck type is enough.
class RecordingLogger
  attr_reader :lines

  def initialize = @lines = Thread::Queue.new
  def info(message) = @lines << [:info, message]
  def warn(message) = @lines << [:warn, message]
  def error(message) = @lines << [:error, message]
end
