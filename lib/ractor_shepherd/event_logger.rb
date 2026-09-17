# frozen_string_literal: true

module RactorShepherd
  # Reads an event port and writes each event to a logger.
  #
  #   events = Ractor::Port.new
  #   RactorShepherd::EventLogger.start(events)                              # to stderr
  #   RactorShepherd::EventLogger.start(events, logger: Logger.new($stdout)) #=> Thread
  #
  # Any object that answers `info`, `warn` and `error` will do. Ruby 4.0 no
  # longer ships logger as a default gem, so this gem never requires it.
  module EventLogger
    # Something went wrong.
    ERROR_TYPES = Ractor.make_shareable(%i[child_unresponsive max_restarts_exceeded])
    # Something is being restarted.
    WARN_TYPES = Ractor.make_shareable(%i[child_start_failed child_restart_scheduled])

    # The default logger: one line per event on stderr.
    class StderrLogger
      def info(message) = write("INFO", message)
      def warn(message) = write("WARN", message)
      def error(message) = write("ERROR", message)

      private

      def write(level, message)
        # Not Kernel#warn: it would collide with StderrLogger#warn.
        $stderr.write("#{level} -- #{message}\n")
      end
    end

    module_function

    # Start a thread, in the calling Ractor, that drains the port.
    #
    # The port must have been created by the calling Ractor, since only its
    # creator may receive from it.
    #
    # @return [Thread]
    def start(port, logger: StderrLogger.new)
      Thread.new(port, logger) do |pt, log|
        while true # `loop do` is forbidden here: Ractor::ClosedError < StopIteration
          event = pt.receive
          log.public_send(EventLogger.level_for(event), EventLogger.format_event(event))
        end
      rescue Ractor::ClosedError
        # The port closed. Stop reading.
        nil
      end
    end

    # @return [Symbol] :info, :warn or :error
    def level_for(event)
      type = event[:type]
      return :error if ERROR_TYPES.include?(type)
      return :error if type == :child_exited && event[:reason] == :error
      return :warn if WARN_TYPES.include?(type)
      return :warn if type == :child_started && event[:attempt].to_i.positive?

      :info
    end

    # @return [String] one line
    def format_event(event)
      head = "[ractor_shepherd] #{event[:supervisor]} #{event[:type]}"
      rest = event.except(:type, :supervisor, :at).map { |key, value| "#{key}=#{value.inspect}" }
      [head, *rest].join(" ")
    end
  end
end
