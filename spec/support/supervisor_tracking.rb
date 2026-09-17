# frozen_string_literal: true

# Stops every supervisor an example started, whatever happened to it.
module SupervisorTracking
  def track(ref)
    tracked_supervisors << ref
    ref
  end

  def tracked_supervisors
    @tracked_supervisors ||= []
  end

  def stop_tracked_supervisors
    tracked_supervisors.reverse_each do |ref|
      ref.stop(:shutdown, timeout: 5)
    rescue StandardError
      nil
    end
    tracked_supervisors.clear
  end
end
