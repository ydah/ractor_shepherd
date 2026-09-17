# frozen_string_literal: true

module RactorShepherd
  # A GenServer style worker: `run` is already written for you, and you only
  # fill in the message handlers.
  #
  #   class Counter
  #     include RactorShepherd::Server
  #
  #     def initialize(start = 0) = @count = start
  #
  #     def handle_call(msg)
  #       case msg
  #       in :get then @count
  #       end
  #     end
  #
  #     def handle_cast(msg)
  #       case msg
  #       in [:add, n] then @count += n
  #       end
  #     end
  #   end
  module Server
    include Worker

    # Receive loop. It ends when `ctx.receive` raises ShutdownSignal.
    def run(ctx)
      @context = ctx
      while true # `loop do` is forbidden here: Ractor::ClosedError < StopIteration
        message = ctx.receive
        case message
        in [Runtime::Protocol::CALL, reply_port, request] then respond(reply_port, request)
        else handle_cast(message)
        end
      end
    end

    # The current {RactorShepherd::Runtime::Context}.
    def context = @context

    # The return value becomes the reply. An exception kills this child.
    def handle_call(message)
      raise NotImplementedError, "#{self.class} must implement #handle_call(message)"
    end

    # The return value is ignored. Left unimplemented, it emits :unhandled_message and moves on.
    def handle_cast(message)
      context&.emit_system(:unhandled_message, message_class: message.class.name)
      nil
    end

    private

    def respond(reply_port, request)
      reply_port << Runtime::Protocol.reply(handle_call(request))
    rescue Ractor::ClosedError
      # The caller already timed out and closed its reply port. Drop the answer.
      nil
    end
  end
end
