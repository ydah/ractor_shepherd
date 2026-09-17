# frozen_string_literal: true

# Reads an event port and waits for the event an example cares about.
#
# Events that do not match are kept in a buffer rather than dropped, so an
# example can wait for something that has already gone past.
class EventWaiter
  TIMEOUT_TAG = :"$spec_wait_timeout"

  attr_reader :port, :buffer

  def initialize(port = Ractor::Port.new)
    @port = port
    @buffer = []
    @token = 0
  end

  # @return [Hash] the matching event
  def wait_for(type:, child: nil, timeout: 5, &extra)
    found = take_from_buffer(type, child, extra)
    return found if found

    @token += 1
    token = @token
    timer = Thread.new(port, token, timeout) do |pt, tk, sec|
      sleep sec
      pt << [TIMEOUT_TAG, tk]
    rescue Ractor::ClosedError
      nil
    end

    begin
      while true
        msg = port.receive
        if msg.is_a?(Array) && msg[0] == TIMEOUT_TAG
          next unless msg[1] == token

          raise Timeout::Error,
                "event #{type.inspect}#{" for #{child.inspect}" if child} did not arrive in #{timeout}s; " \
                "seen: #{buffer.map { |e| [e[:type], e[:child]] }.inspect}"
        end
        return msg if match?(msg, type, child, extra)

        buffer << msg
      end
    ensure
      timer.kill
    end
  end

  # Read until the condition holds, keeping everything in the buffer so that
  # the order events arrived in can still be checked afterwards.
  def wait_until(timeout: 5, &condition)
    return buffer if condition.call(buffer)

    @token += 1
    token = @token
    timer = Thread.new(port, token, timeout) do |pt, tk, sec|
      sleep sec
      pt << [TIMEOUT_TAG, tk]
    rescue Ractor::ClosedError
      nil
    end

    begin
      while true
        msg = port.receive
        if msg.is_a?(Array) && msg[0] == TIMEOUT_TAG
          next unless msg[1] == token

          raise Timeout::Error, "condition not met in #{timeout}s; " \
                                "seen: #{buffer.map { |e| [e[:type], e[:child]] }.inspect}"
        end
        buffer << msg
        return buffer if condition.call(buffer)
      end
    ensure
      timer.kill
    end
  end

  # Forget everything seen so far.
  def clear
    drain
    buffer.clear
    self
  end

  # Read everything that has already arrived, without blocking.
  def drain
    @token += 1
    token = @token
    port << [TIMEOUT_TAG, token] # mark the end of the queue and read up to it
    while true
      msg = port.receive
      break if msg.is_a?(Array) && msg[0] == TIMEOUT_TAG && msg[1] == token
      next if msg.is_a?(Array) && msg[0] == TIMEOUT_TAG # a stale mark we failed to cancel

      buffer << msg
    end
    buffer
  end

  # Every event of one type, in the order they arrived.
  def collected(type)
    drain.select { |e| e[:type] == type }
  end

  private

  def take_from_buffer(type, child, extra)
    index = buffer.index { |e| match?(e, type, child, extra) }
    index && buffer.delete_at(index)
  end

  def match?(event, type, child, extra)
    return false unless event.is_a?(Hash)
    return false unless event[:type] == type
    return false if child && event[:child] != child

    extra.nil? || extra.call(event)
  end
end
