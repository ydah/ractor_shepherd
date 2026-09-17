# frozen_string_literal: true

# Workers used by the spec validation examples. Their class bodies stay
# shareable so that they can be handed to a Ractor.
class NoopWorker
  include RactorShepherd::Worker

  def run(ctx)
    ctx.sleep(3600) until ctx.shutdown_requested?
  end
end

# A class that does not include Worker, for the validation examples.
class PlainClass
  def run(_ctx) = nil
end
