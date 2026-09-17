# frozen_string_literal: true

module RactorShepherd
  module Core
    # Builds the event hashes the supervisor and its children publish.
    #
    # Events travel between Ractors, so they are always deeply frozen.
    #
    # @api private
    module Event
      BACKTRACE_LINES = 10

      HINTS = Ractor.make_shareable({
                                      "Ractor::UnsafeError" =>
                                        "the child may be calling a C extension that is not Ractor safe",
                                      "Ractor::IsolationError" =>
                                        "the child may be referencing something unshareable, such as a Proc or an IO",
                                      "Ractor::MovedError" =>
                                        "the child may be referencing an object that was moved to another Ractor"
                                    })

      module_function

      # @param type [Symbol]
      # @param supervisor [String] the supervisor's path, e.g. "root/jobs"
      # @param at [Float] CLOCK_REALTIME
      # @return [Hash] deeply frozen
      def build(type, supervisor:, at:, **data)
        Ractor.make_shareable({ type: type, supervisor: supervisor, at: at }.merge(data), copy: true)
      end

      # Event keys describing an exception.
      #
      # @param error [Exception, Symbol, nil]
      # @return [Hash]
      def error_info(error)
        return {} unless error.is_a?(Exception)

        {
          error_class: error.class.name,
          error_message: error.message.to_s,
          backtrace: (error.backtrace || []).first(BACKTRACE_LINES),
          hint: hint_for(error)
        }.compact
      end

      # @return [String, nil] advice for exceptions we recognise
      def hint_for(error)
        klass = error.is_a?(Exception) ? error.class : error
        klass.ancestors.each do |ancestor|
          hint = HINTS[ancestor.name]
          return hint if hint
        end
        nil
      end

      # Normalise an exit reason to :normal, :shutdown, :error or :unknown.
      def reason_kind(reason)
        case reason
        when :normal, :shutdown then reason
        when Exception then :error
        else :unknown
        end
      end
    end
  end
end
