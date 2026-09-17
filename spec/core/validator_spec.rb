# frozen_string_literal: true

RSpec.describe RactorShepherd::Validator do
  describe "worker specs" do
    it "builds a shareable ChildSpec" do
      spec = RactorShepherd.worker(:a, NoopWorker, args: [1, "two"])
      expect(spec).to be_a(RactorShepherd::ChildSpec)
      expect(Ractor.shareable?(spec)).to be(true)
      expect([spec.id, spec.type, spec.start, spec.restart]).to eq([:a, :worker, NoopWorker, :permanent])
    end

    it "does not freeze the caller's args (F17)" do
      args = [+"mutable"]
      RactorShepherd.worker(:a, NoopWorker, args: args)
      expect(args.first).not_to be_frozen
    end

    %i[a].each do |id|
      it "accepts a Symbol id (#{id.inspect})" do
        expect(RactorShepherd.worker(id, NoopWorker).id).to eq(id)
      end
    end

    it "accepts an Integer id" do
      expect(RactorShepherd.worker(7, NoopWorker).id).to eq(7)
    end

    it "accepts a frozen String id" do
      expect(RactorShepherd.worker("a", NoopWorker).id).to eq("a")
    end

    it "rejects a mutable String id" do
      expect { RactorShepherd.worker(+"a", NoopWorker) }.to raise_error(RactorShepherd::InvalidSpec, /frozen String/)
    end

    it "rejects a class that does not include Worker" do
      expect { RactorShepherd.worker(:a, PlainClass) }
        .to raise_error(RactorShepherd::InvalidSpec, /must include RactorShepherd::Worker/)
    end

    it "rejects a non-class start" do
      expect { RactorShepherd.worker(:a, :not_a_class) }
        .to raise_error(RactorShepherd::InvalidSpec, /must be a Class/)
    end

    it "rejects an unknown restart kind" do
      expect { RactorShepherd.worker(:a, NoopWorker, restart: :forever) }
        .to raise_error(RactorShepherd::InvalidSpec, /restart must be one of/)
    end

    [0, -1, "5", nil].each do |value|
      it "rejects shutdown_timeout #{value.inspect}" do
        expect { RactorShepherd.worker(:a, NoopWorker, shutdown_timeout: value) }
          .to raise_error(RactorShepherd::InvalidSpec, /shutdown_timeout/)
      end
    end

    it "accepts :infinity timeouts" do
      spec = RactorShepherd.worker(:a, NoopWorker, shutdown_timeout: :infinity, start_timeout: :infinity)
      expect([spec.shutdown_timeout, spec.start_timeout]).to eq(%i[infinity infinity])
    end

    describe "non-shareable args" do
      it "reports the original exception as the cause and adds a hint" do
        error = begin
          RactorShepherd.worker(:a, NoopWorker, args: [-> { 1 }])
          nil
        rescue RactorShepherd::InvalidSpec => e
          e
        end

        expect(error.message).to include("args cannot be shared")
        expect(error.message).to include("Proc")
        # Ruby 4.0 raises TypeError (allocator undefined); 4.1 raises Ractor::Error.
        expect(error.cause).to be_a(TypeError).or be_a(Ractor::Error)
      end

      it "also covers kwargs" do
        expect { RactorShepherd.worker(:a, NoopWorker, kwargs: { lock: Mutex.new }) }
          .to raise_error(RactorShepherd::InvalidSpec, /kwargs cannot be shared/)
      end
    end

    it "lists every violation in one exception" do
      error = begin
        RactorShepherd.worker(+"bad", PlainClass, restart: :forever, shutdown_timeout: -1)
        nil
      rescue RactorShepherd::InvalidSpec => e
        e
      end

      expect(error.message.lines.grep(/^  - /).size).to eq(4)
    end
  end

  describe "restart_delay" do
    it "accepts nil" do
      expect(RactorShepherd.worker(:a, NoopWorker, restart_delay: nil).restart_delay).to be_nil
    end

    it "accepts a Numeric" do
      expect(RactorShepherd.worker(:a, NoopWorker, restart_delay: 0.5).restart_delay).to eq(0.5)
    end

    it "rejects a negative Numeric" do
      expect { RactorShepherd.worker(:a, NoopWorker, restart_delay: -1) }
        .to raise_error(RactorShepherd::InvalidSpec, /restart_delay must be >= 0/)
    end

    it "builds a BackoffSpec from a Hash" do
      spec = RactorShepherd.worker(:a, NoopWorker, restart_delay: { initial: 0.1, max: 5, factor: 3 })
      expect(spec.restart_delay).to eq(RactorShepherd::BackoffSpec.new(initial: 0.1, max: 5, factor: 3))
    end

    it "rejects max < initial" do
      expect { RactorShepherd.worker(:a, NoopWorker, restart_delay: { initial: 5, max: 1 }) }
        .to raise_error(RactorShepherd::InvalidSpec, /:max\] must be a Numeric >= initial/)
    end

    it "rejects factor < 1" do
      expect { RactorShepherd.worker(:a, NoopWorker, restart_delay: { factor: 0.5 }) }
        .to raise_error(RactorShepherd::InvalidSpec, /:factor\] must be a Numeric >= 1/)
    end

    it "rejects unknown keys" do
      expect { RactorShepherd.worker(:a, NoopWorker, restart_delay: { jitter: true }) }
        .to raise_error(RactorShepherd::InvalidSpec, /unknown keys/)
    end
  end

  describe "supervisor specs" do
    it "wraps a SupervisorSpec in a ChildSpec" do
      spec = RactorShepherd.supervisor(:jobs, strategy: :rest_for_one,
                                              children: [RactorShepherd.worker(:a, NoopWorker)])
      expect(spec.type).to eq(:supervisor)
      expect(spec.start).to be_a(RactorShepherd::SupervisorSpec)
      expect(spec.start.strategy).to eq(:rest_for_one)
      expect(Ractor.shareable?(spec)).to be(true)
    end

    it "defaults to :infinity shutdown and start timeouts" do
      spec = RactorShepherd.supervisor(:jobs)
      expect([spec.shutdown_timeout, spec.start_timeout]).to eq(%i[infinity infinity])
    end

    it "rejects an unknown strategy" do
      expect { RactorShepherd.supervisor(:jobs, strategy: :all_for_one) }
        .to raise_error(RactorShepherd::InvalidSpec, /strategy must be one of/)
    end

    it "rejects duplicated child ids" do
      children = [RactorShepherd.worker(:a, NoopWorker), RactorShepherd.worker(:a, NoopWorker)]
      expect { RactorShepherd.supervisor(:jobs, children: children) }
        .to raise_error(RactorShepherd::InvalidSpec, /duplicated child ids: :a/)
    end

    it "rejects children that are not ChildSpec" do
      expect { RactorShepherd.supervisor(:jobs, children: [NoopWorker]) }
        .to raise_error(RactorShepherd::InvalidSpec, /children must all be ChildSpec/)
    end

    it "rejects a negative max_restarts" do
      expect { RactorShepherd.supervisor(:jobs, max_restarts: -1) }
        .to raise_error(RactorShepherd::InvalidSpec, /max_restarts/)
    end

    it "accepts max_restarts: 0" do
      expect(RactorShepherd.supervisor(:jobs, max_restarts: 0).start.max_restarts).to eq(0)
    end

    it "rejects a non-positive max_seconds" do
      expect { RactorShepherd.supervisor(:jobs, max_seconds: 0) }
        .to raise_error(RactorShepherd::InvalidSpec, /max_seconds/)
    end

    it "rejects an unknown on_unresponsive" do
      expect { RactorShepherd.supervisor(:jobs, on_unresponsive: :kill) }
        .to raise_error(RactorShepherd::InvalidSpec, /on_unresponsive/)
    end
  end

  describe "dynamic supervisor specs" do
    it "is always :one_for_one and starts with no children" do
      spec = RactorShepherd.dynamic_supervisor(:pool, max_children: 10)
      expect([spec.start.kind, spec.start.strategy, spec.start.children, spec.start.max_children])
        .to eq([:dynamic, :one_for_one, [], 10])
    end

    it "rejects max_children: 0" do
      expect { RactorShepherd.dynamic_supervisor(:pool, max_children: 0) }
        .to raise_error(RactorShepherd::InvalidSpec, /max_children/)
    end

    it "accepts max_children: nil as unlimited" do
      expect(RactorShepherd.dynamic_supervisor(:pool).start.max_children).to be_nil
    end
  end

  describe ".root_spec" do
    it "returns a bare SupervisorSpec" do
      spec = described_class.root_spec(strategy: :one_for_all)
      expect(spec).to be_a(RactorShepherd::SupervisorSpec)
      expect(Ractor.shareable?(spec)).to be(true)
    end

    it "rejects a dynamic root with children" do
      expect { described_class.root_spec(kind: :dynamic, children: [RactorShepherd.worker(:a, NoopWorker)]) }
        .to raise_error(RactorShepherd::InvalidSpec, /must start with no children/)
    end
  end
end
