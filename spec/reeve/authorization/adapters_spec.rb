# frozen_string_literal: true

# Pundit is a development dependency, never a runtime one. Loading it here is what makes
# the bridge genuinely exercised rather than merely skipped; the specs still skip cleanly
# where it is absent, which is how a host without Pundit runs them.
begin
  require "pundit"
rescue LoadError
  nil
end

RSpec.describe "policy adapters" do
  let(:principal) { double("User", id: 7) }

  describe Reeve::Authorization::Adapters::Plain do
    subject(:adapter) { described_class.new }

    let(:policy) do
      Class.new do
        def self.name = "InvoicePolicy"

        def self.authorize(principal, action, record)
          !principal.nil? && action == :index && record.nil?
        end

        def self.scope(_principal, relation) = relation.select(&:even?)
      end
    end

    describe ".supports?" do
      it "accepts any object answering to authorize and scope" do
        expect(described_class.supports?(policy)).to be(true)
      end

      it "rejects an object missing either method, and names what is missing" do
        half = Class.new { def self.authorize(*) = true }

        expect(described_class.supports?(half)).to be(false)
        expect(described_class.missing_methods(half)).to eq([:scope])
        expect(described_class.missing_methods(Object.new)).to contain_exactly(:authorize, :scope)
      end
    end

    describe "#authorize" do
      it "wraps a truthy return in an allow naming the policy and action" do
        decision = adapter.authorize(principal: principal, policy: policy, action: :index)

        expect(decision).to be_allowed
        expect(decision.rule).to eq("InvoicePolicy#index")
      end

      it "wraps a falsy return in a deny carrying the same rule" do
        decision = adapter.authorize(principal: principal, policy: policy, action: :destroy)

        expect(decision).to be_denied
        expect(decision.rule).to eq("InvoicePolicy#destroy")
      end

      it "passes the record through for a per-record check" do
        checked = nil
        recording_policy = Class.new do
          define_singleton_method(:authorize) { |_p, _a, record| checked = record }
          def self.scope(_principal, relation) = relation
          def self.name = "P"
        end
        allow(recording_policy).to receive(:authorize).and_wrap_original do |original, *args|
          checked = args.last
          original.call(*args)
        end

        adapter.authorize(principal: principal, policy: recording_policy, action: :show, record: :the_record)

        expect(checked).to eq(:the_record)
      end
    end

    describe "#scope" do
      it "returns what the policy narrowed" do
        expect(adapter.scope(principal: principal, policy: policy, relation: [1, 2, 3, 4])).to eq([2, 4])
      end

      # Reading nil as "everything" is the dangerous interpretation, so it is an error.
      it "refuses a nil scope rather than treating it as no restriction" do
        nil_policy = Class.new do
          def self.name = "NilPolicy"
          def self.authorize(*) = true
          def self.scope(*) = nil
        end

        expect { adapter.scope(principal: principal, policy: nil_policy, relation: []) }
          .to raise_error(Reeve::Error, /returned nil/)
      end
    end

    describe "#policy_for" do
      it "finds the conventional policy for another returned type" do
        stub_const("Thing", Class.new)
        stub_const("ThingPolicy", Class.new do
          def self.authorize(*) = true
          def self.scope(_principal, relation) = relation
        end)

        expect(adapter.policy_for(Thing)).to eq(ThingPolicy)
      end

      it "returns nil when there is no such policy, which denies as unknown_record_type" do
        stub_const("Ungoverned", Class.new)

        expect(adapter.policy_for(Ungoverned)).to be_nil
      end

      it "returns nil when the conventional constant is not a usable policy" do
        stub_const("Weird", Class.new)
        stub_const("WeirdPolicy", Class.new)

        expect(adapter.policy_for(Weird)).to be_nil
      end
    end
  end

  describe Reeve::Authorization::Adapters::Pundit do
    subject(:adapter) { described_class.new }

    before { skip("Pundit is not loaded") unless described_class.pundit_loaded? }

    let(:pundit_policy) do
      stub_const("Widget", Class.new)
      policy = Class.new do
        attr_reader :user, :record

        def initialize(user, record)
          @user = user
          @record = record
        end

        def index? = !user.nil?
        def destroy? = false
      end
      # const_set rather than `class Scope` inside the block: a class keyword in a block
      # defines the constant at file scope, not under the anonymous class.
      policy.const_set(:Scope, Class.new do
        def initialize(user, scope)
          @user = user
          @scope = scope
        end

        def resolve = @scope.select(&:odd?)
      end)
      stub_const("WidgetPolicy", policy)
    end

    it "recognises a Pundit-shaped policy" do
      expect(described_class.supports?(pundit_policy)).to be(true)
    end

    it "does not recognise a plain policy object" do
      plain = Class.new do
        def self.authorize(*) = true
        def self.scope(_principal, relation) = relation
      end

      expect(described_class.supports?(plain)).to be(false)
    end

    it "reports a missing Scope class, which is a declaration-time error" do
      stub_const("NoScopePolicy", Class.new { def index? = true })

      expect(described_class.supports?(NoScopePolicy)).to be(false)
      expect(described_class.missing_methods(NoScopePolicy)).to include(:Scope)
    end

    it "asks the query method and names it as the rule" do
      decision = adapter.authorize(principal: principal, policy: pundit_policy, action: :index)

      expect(decision).to be_allowed
      expect(decision.rule).to eq("WidgetPolicy#index?")
    end

    it "denies through the same query method" do
      expect(adapter.authorize(principal: principal, policy: pundit_policy, action: :destroy))
        .to be_denied
    end

    it "resolves the scope and names it" do
      expect(adapter.scope(principal: principal, policy: pundit_policy, relation: [1, 2, 3])).to eq([1, 3])
      expect(adapter.scope_rule(pundit_policy)).to eq("WidgetPolicy::Scope")
    end

    it "finds a policy for another type by Pundit's own convention" do
      pundit_policy

      expect(adapter.policy_for(Widget)).to eq(WidgetPolicy)
    end
  end

  describe Reeve::Authorization::Adapter do
    let(:plain_policy) do
      Class.new do
        def self.name = "PlainPolicy"
        def self.authorize(*) = true
        def self.scope(_principal, relation) = relation
      end
    end

    it "uses the plain adapter for a plain policy under :auto" do
      expect(described_class.resolve(plain_policy)).to be_a(Reeve::Authorization::Adapters::Plain)
      expect(described_class.resolve_name(plain_policy)).to eq(:plain)
    end

    it "honours an explicit :plain setting" do
      Reeve.configure { |c| c.policy_adapter = :plain }

      expect(described_class.resolve(plain_policy)).to be_a(Reeve::Authorization::Adapters::Plain)
    end

    it "returns a host-supplied adapter object unchanged" do
      custom = Class.new do
        def authorize(principal:, policy:, action:, record: nil); end
        def scope(principal:, policy:, relation:); end
      end.new
      Reeve.configure { |c| c.policy_adapter = custom }

      expect(described_class.resolve(plain_policy)).to equal(custom)
    end

    # Constitution VI: the developer learns at declaration time, not on the first denial.
    it "refuses a policy no adapter can serve, naming what it needed" do
      expect { described_class.validate!(Object.new) }
        .to raise_error(Reeve::ConfigurationError, /#authorize and #scope/)
    end

    it "reports which adapter :auto chose, so the choice is never a mystery" do
      expect(Reeve.config.resolved_policy_adapter(plain_policy)).to eq(:plain)
    end
  end
end
