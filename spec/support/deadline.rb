# frozen_string_literal: true

require "timeout"

module DeadlineHelper
  # Wrap every integration example in this so that a hang fails the test
  # instead of stalling the suite.
  def with_deadline(seconds = 10, &)
    Timeout.timeout(seconds, Timeout::Error, "exceeded deadline of #{seconds}s", &)
  end
end
