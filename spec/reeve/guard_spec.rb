# frozen_string_literal: true

RSpec.describe Reeve::Guard do
  let(:policy) do
    Class.new do
      def self.name = "InvoicePolicy"
      def self.authorize(_principal, _action, _record) = true
      def self.scope(_principal, relation) = relation
    end
  end

  def tool_class(name = "InvoiceSearchTool", &body)
    klass = Class.new do
      include Reeve::Guard

      define_singleton_method(:name) { name }
    end
    klass.class_eval(&body) if body
    klass
  end

  describe ".guard_with" do
    it "registers the tool in the process registry at class-definition time" do
      declared = policy
      klass = tool_class { guard_with declared }

      expect(Reeve.registry.for_class(klass).policy).to eq(declared)
    end

    it "defaults the action to the configured default" do
      declared = policy
      klass = tool_class { guard_with declared }

      expect(Reeve.registry.for_class(klass).action).to eq(:index)
    end

    it "honours a configured default_action" do
      Reeve.configure { |c| c.default_action = :read }
      declared = policy
      klass = tool_class { guard_with declared }

      expect(Reeve.registry.for_class(klass).action).to eq(:read)
    end

    it "accepts a per-tool action override" do
      declared = policy
      klass = tool_class { guard_with declared, action: :show }

      expect(Reeve.registry.for_class(klass).action).to eq(:show)
    end

    it "exposes the declaration on the class" do
      declared = policy
      klass = tool_class { guard_with declared }

      expect(klass.reeve_guard.policy).to eq(declared)
    end

    it "rejects a policy that cannot satisfy the adapter, at declaration time" do
      # Constitution VI: the developer learns immediately, not on the first denial.
      expect { tool_class { guard_with Object.new } }
        .to raise_error(Reeve::ConfigurationError, /authorize|scope/)
    end
  end

  describe ".redact" do
    it "records per-tool redacted argument names" do
      declared = policy
      klass = tool_class do
        guard_with declared
        redact :customer_ssn, "account_number"
      end

      expect(klass.reeve_guard.redacted_arguments).to contain_exactly(:customer_ssn, :account_number)
    end

    it "accumulates across calls" do
      declared = policy
      klass = tool_class do
        guard_with declared
        redact :one
        redact :two
      end

      expect(klass.reeve_guard.redacted_arguments).to contain_exactly(:one, :two)
    end

    it "may be declared before guard_with" do
      declared = policy
      klass = tool_class do
        redact :customer_ssn
        guard_with declared
      end

      expect(klass.reeve_guard.redacted_arguments).to contain_exactly(:customer_ssn)
    end
  end

  describe "inheritance" do
    it "gives a subclass its parent's declaration" do
      declared = policy
      parent = tool_class("ParentTool") { guard_with declared }
      child = Class.new(parent) { define_singleton_method(:name) { "ChildTool" } }

      expect(child.reeve_guard.policy).to eq(declared)
    end

    it "registers the subclass under its own tool name, so the envelope finds it" do
      # Written with real class syntax on purpose: Ruby names a class before calling
      # .inherited, and that is what makes the subclass findable by name.
      declared = policy
      parent = Class.new { include Reeve::Guard }
      stub_const("ParentTool", parent)
      parent.guard_with(declared)
      namespace = Module.new
      stub_const("Tools", namespace)
      namespace.module_eval("class ChildTool < ParentTool; end", __FILE__, __LINE__)

      expect(Reeve.registry.guard_for("tools_child_tool")).not_to be_nil
      expect(Reeve.registry.guard_for("tools_child_tool").policy).to eq(declared)
    end

    it "lets a subclass override the policy without touching the parent" do
      declared = policy
      other = policy
      parent = tool_class("ParentTool") { guard_with declared }
      child = Class.new(parent) do
        define_singleton_method(:name) { "ChildTool" }
        guard_with other
      end

      expect(child.reeve_guard.policy).to eq(other)
      expect(parent.reeve_guard.policy).to eq(declared)
    end
  end

  describe "a tool with no declaration" do
    it "has no guard, which the envelope reads as deny" do
      klass = tool_class("UnguardedTool")

      expect(klass.reeve_guard).to be_nil
      expect(Reeve.registry.guard_for("unguarded_tool")).to be_nil
    end
  end
end
