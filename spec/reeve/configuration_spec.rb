# frozen_string_literal: true

RSpec.describe Reeve::Configuration do
  subject(:config) { described_class.new }

  describe "defaults" do
    it "denies unguarded tools" do
      expect(config.unguarded_tools).to eq(:deny)
    end

    it "fails the invocation when the ledger write fails" do
      expect(config.audit_failure_mode).to eq(:fail)
    end

    it "has no principal resolver, so every call denies until the host sets one" do
      expect(config.principal_resolver).to be_nil
    end

    it "redacts the argument names that are dangerous by default" do
      expect(config.redact_arguments).to include(:password, :token, :secret)
    end

    it "caps recorded identifiers" do
      expect(config.max_recorded_ids).to eq(1000)
    end

    it "detects the policy adapter" do
      expect(config.policy_adapter).to eq(:auto)
    end

    it "checks :index unless a tool overrides it" do
      expect(config.default_action).to eq(:index)
    end

    it "leaves the recorder and logger to be resolved by the host" do
      expect(config.audit_recorder).to be_nil
      expect(config.logger).to be_nil
    end
  end

  describe "validation" do
    describe "#unguarded_tools=" do
      it "accepts the two documented modes" do
        expect { config.unguarded_tools = :allow_with_warning }.not_to raise_error
        expect(config.unguarded_tools).to eq(:allow_with_warning)
        expect { config.unguarded_tools = :deny }.not_to raise_error
      end

      it "rejects anything else at assignment time" do
        expect { config.unguarded_tools = :allow }.to raise_error(ArgumentError, /unguarded_tools/)
        expect { config.unguarded_tools = nil }.to raise_error(ArgumentError, /unguarded_tools/)
        expect { config.unguarded_tools = "deny" }.to raise_error(ArgumentError, /unguarded_tools/)
      end
    end

    describe "#audit_failure_mode=" do
      it "accepts the two documented modes" do
        expect { config.audit_failure_mode = :warn }.not_to raise_error
        expect(config.audit_failure_mode).to eq(:warn)
      end

      it "rejects anything else" do
        expect { config.audit_failure_mode = :ignore }
          .to raise_error(ArgumentError, /audit_failure_mode/)
      end
    end

    describe "#max_recorded_ids=" do
      it "accepts a positive integer" do
        config.max_recorded_ids = 50
        expect(config.max_recorded_ids).to eq(50)
      end

      it "rejects zero, negatives and non-integers" do
        expect { config.max_recorded_ids = 0 }.to raise_error(ArgumentError, /max_recorded_ids/)
        expect { config.max_recorded_ids = -1 }.to raise_error(ArgumentError, /max_recorded_ids/)
        expect { config.max_recorded_ids = 1.5 }.to raise_error(ArgumentError, /max_recorded_ids/)
        expect { config.max_recorded_ids = "100" }.to raise_error(ArgumentError, /max_recorded_ids/)
      end
    end

    describe "#principal_resolver=" do
      it "accepts anything callable" do
        resolver = ->(context) { context }
        config.principal_resolver = resolver
        expect(config.principal_resolver).to eq(resolver)
      end

      it "accepts nil, which leaves the library denying every call" do
        expect { config.principal_resolver = nil }.not_to raise_error
      end

      it "rejects a non-callable" do
        expect { config.principal_resolver = :current_user }
          .to raise_error(ArgumentError, /principal_resolver/)
      end
    end

    describe "#policy_adapter=" do
      it "accepts the three documented symbols" do
        %i[auto pundit plain].each do |mode|
          expect { config.policy_adapter = mode }.not_to raise_error
        end
      end

      it "accepts an object implementing the adapter protocol" do
        adapter = Class.new do
          def authorize(principal:, policy:, action:, record:); end
          def scope(principal:, policy:, relation:); end
        end.new

        expect { config.policy_adapter = adapter }.not_to raise_error
      end

      it "rejects an unknown symbol" do
        expect { config.policy_adapter = :cancan }
          .to raise_error(ArgumentError, /policy_adapter/)
      end

      it "rejects an object missing part of the protocol" do
        half = Class.new { def authorize(**); end }.new

        expect { config.policy_adapter = half }
          .to raise_error(ArgumentError, /scope/)
      end
    end

    describe "#redact_arguments=" do
      it "coerces names to symbols so hosts may pass strings" do
        config.redact_arguments = ["pin", :otp]
        expect(config.redact_arguments).to contain_exactly(:pin, :otp)
      end

      it "rejects a non-list" do
        expect { config.redact_arguments = :password }
          .to raise_error(ArgumentError, /redact_arguments/)
      end
    end

    describe "#default_action=" do
      it "accepts a symbol" do
        config.default_action = :read
        expect(config.default_action).to eq(:read)
      end

      it "coerces a string" do
        config.default_action = "show"
        expect(config.default_action).to eq(:show)
      end

      it "rejects nil and blank" do
        expect { config.default_action = nil }.to raise_error(ArgumentError, /default_action/)
        expect { config.default_action = "" }.to raise_error(ArgumentError, /default_action/)
      end
    end

    describe "#audit_recorder=" do
      it "accepts anything that responds to #record" do
        recorder = Class.new { def record(attributes); end }.new
        expect { config.audit_recorder = recorder }.not_to raise_error
      end

      it "rejects an object that cannot record" do
        expect { config.audit_recorder = Object.new }
          .to raise_error(ArgumentError, /audit_recorder/)
      end
    end

    describe "#compliance_principals=" do
      it "accepts a callable, because fixtures do not exist when the helper loads" do
        expect { config.compliance_principals = -> { %i[alice bob] } }.not_to raise_error
      end

      it "accepts an array" do
        config.compliance_principals = %i[alice bob]
        expect(config.compliance_principals).to eq(%i[alice bob])
      end

      it "rejects anything else" do
        expect { config.compliance_principals = :alice }
          .to raise_error(ArgumentError, /compliance_principals/)
      end
    end

    describe "#logger=" do
      it "accepts anything that responds to #warn" do
        expect { config.logger = Class.new { def warn(message); end }.new }.not_to raise_error
      end

      it "rejects an object that cannot warn" do
        expect { config.logger = Object.new }.to raise_error(ArgumentError, /logger/)
      end
    end
  end

  describe "Reeve.configure" do
    it "yields the process configuration" do
      Reeve.configure { |c| c.max_recorded_ids = 5 }

      expect(Reeve.config.max_recorded_ids).to eq(5)
    end

    it "may be called more than once, overriding individual settings" do
      Reeve.configure { |c| c.max_recorded_ids = 5 }
      Reeve.configure { |c| c.audit_failure_mode = :warn }

      expect(Reeve.config.max_recorded_ids).to eq(5)
      expect(Reeve.config.audit_failure_mode).to eq(:warn)
    end

    it "raises on an unknown setting rather than silently ignoring it" do
      expect { Reeve.configure { |c| c.audit_evrything = true } }
        .to raise_error(NoMethodError)
    end

    it "returns defaults before it is ever called" do
      expect(Reeve.config).to be_a(described_class)
      expect(Reeve.config.unguarded_tools).to eq(:deny)
    end

    it "is reset between tests by reset_configuration!" do
      Reeve.configure { |c| c.max_recorded_ids = 5 }
      Reeve.reset_configuration!

      expect(Reeve.config.max_recorded_ids).to eq(1000)
    end
  end

  describe "#to_h" do
    # The compliance suite asserts against live settings (contracts/configuration.md).
    it "exposes every setting for inspection" do
      expect(config.to_h.keys).to contain_exactly(
        :principal_resolver, :unguarded_tools, :audit_failure_mode, :redact_arguments,
        :max_recorded_ids, :policy_adapter, :default_action, :audit_recorder, :logger,
        :compliance_principals
      )
    end
  end
end
