# frozen_string_literal: true

module RactorShepherd
  # The low level worker interface: you write the loop yourself.
  #
  #   class Poller
  #     include RactorShepherd::Worker
  #
  #     def initialize(url) = @url = url
  #
  #     def run(ctx)
  #       until ctx.shutdown_requested?
  #         fetch(@url)
  #         ctx.sleep(1.0)
  #       end
  #     end
  #   end
  #
  # `initialize` plays the role of OTP's `init`. Do not make a synchronous call
  # to the supervisor from there: the supervisor is waiting for this child to
  # finish starting, so the call would deadlock until `start_timeout` fires.
  module Worker
    # @param ctx [RactorShepherd::Runtime::Context]
    def run(ctx)
      raise NotImplementedError, "#{self.class} must implement #run(ctx)"
    end

    # Optional cleanup hook.
    #
    # @param reason [Symbol, Exception] :normal, :shutdown, or the exception that killed the worker
    def terminate(reason) = nil # rubocop:disable Lint/UnusedMethodArgument
  end
end
