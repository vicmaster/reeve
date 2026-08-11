# frozen_string_literal: true

RSpec.describe Reeve::Authorization::Registry do
  subject(:registry) { described_class.new }

  let(:policy) { Class.new { def self.name = "InvoicePolicy" } }

  def tool_class(name = "InvoiceSearchTool", &body)
    Class.new do
      include Reeve::Guard

      define_singleton_method(:name) { name }
      class_eval(&body) if body
    end
  end

  describe "#register" do
    it "records a declaration against the tool class" do
      klass = tool_class
      declaration = registry.register(tool_class: klass, policy: policy, action: :index)

      expect(registry.for_class(klass)).to eq(declaration)
      expect(declaration.policy).to eq(policy)
      expect(declaration.action).to eq(:index)
    end

    it "derives the tool name from the class name" do
      declaration = registry.register(tool_class: tool_class("InvoiceSearchTool"), policy: policy)

      expect(declaration.tool_name).to eq("invoice_search_tool")
    end

    it "prefers a tool_name the class declares itself, as MCP server libraries do" do
      klass = tool_class { def self.tool_name = "invoice_search" }
      declaration = registry.register(tool_class: klass, policy: policy)

      expect(declaration.tool_name).to eq("invoice_search")
    end

    it "handles namespaced class names" do
      declaration = registry.register(tool_class: tool_class("Billing::InvoiceTool"), policy: policy)

      expect(declaration.tool_name).to eq("billing_invoice_tool")
    end

    it "replaces an earlier declaration for the same class and warns" do
      klass = tool_class
      other_policy = Class.new
      registry.register(tool_class: klass, policy: policy)

      logger = CapturingLogger.new
      Reeve.configure { |c| c.logger = logger }
      registry.register(tool_class: klass, policy: other_policy)

      expect(registry.for_class(klass).policy).to eq(other_policy)
      expect(registry.size).to eq(1)
      expect(logger.warnings.join).to match(/redeclar|replac/i)
    end
  end

  it "does not cry redeclaration when a declaration is merely updated" do
    # `redact` after `guard_with` replaces the stored declaration with a wider one. That
    # is one declaration being refined, not two competing ones, and warning about it
    # trains people to ignore the warning that matters.
    klass = tool_class
    declaration = registry.register(tool_class: klass, policy: policy)

    logger = CapturingLogger.new
    Reeve.configure { |c| c.logger = logger }
    registry.add(declaration.with(redacted_arguments: [:ssn]))

    expect(logger.warnings).to be_empty
    expect(registry.for_class(klass).redacted_arguments).to eq([:ssn])
  end

  describe "#guard_for" do
    it "finds a declaration by tool name — the name the envelope has" do
      klass = tool_class { def self.tool_name = "invoice_search" }
      declaration = registry.register(tool_class: klass, policy: policy)

      expect(registry.guard_for("invoice_search")).to eq(declaration)
    end

    it "returns nil for an unregistered tool, so the envelope denies" do
      expect(registry.guard_for("nothing_declared")).to be_nil
    end

    it "sees a declaration registered after an earlier lookup missed" do
      expect(registry.guard_for("invoice_search")).to be_nil
      klass = tool_class { def self.tool_name = "invoice_search" }
      declaration = registry.register(tool_class: klass, policy: policy)

      expect(registry.guard_for("invoice_search")).to eq(declaration)
    end
  end

  describe "inheritance" do
    it "finds the parent's declaration for an unregistered subclass" do
      parent = tool_class("ParentTool")
      declaration = registry.register(tool_class: parent, policy: policy)
      child = Class.new(parent) { define_singleton_method(:name) { "ChildTool" } }

      expect(registry.for_class(child)).to eq(declaration)
    end

    it "prefers the subclass's own declaration when it overrides" do
      parent = tool_class("ParentTool")
      registry.register(tool_class: parent, policy: policy)
      child = Class.new(parent) { define_singleton_method(:name) { "ChildTool" } }
      own = registry.register(tool_class: child, policy: Class.new)

      expect(registry.for_class(child)).to eq(own)
    end
  end

  describe "enumeration" do
    # The compliance suite walks this to assert every declared tool is covered.
    it "is enumerable over its declarations" do
      registry.register(tool_class: tool_class("OneTool"), policy: policy)
      registry.register(tool_class: tool_class("TwoTool"), policy: policy)

      expect(registry.map(&:tool_name)).to contain_exactly("one_tool", "two_tool")
      expect(registry.size).to eq(2)
      expect(registry).to be_a(Enumerable)
    end

    it "starts empty" do
      expect(registry.to_a).to be_empty
      expect(registry).to be_empty
    end
  end

  describe "#remove" do
    # A host that builds a throwaway tool inside one test needs it gone before the
    # compliance suite, which walks the whole registry, runs against it.
    it "forgets one tool without disturbing the others" do
      keep = tool_class("KeepTool")
      drop = tool_class("DropTool")
      registry.register(tool_class: keep, policy: policy)
      registry.register(tool_class: drop, policy: policy)

      registry.remove(drop)

      expect(registry.for_class(drop)).to be_nil
      expect(registry.guard_for("drop_tool")).to be_nil
      expect(registry.for_class(keep)).not_to be_nil
    end

    it "is quiet about a tool it never knew" do
      expect { registry.remove(tool_class("NeverTool")) }.not_to raise_error
    end
  end

  describe "#reset!" do
    it "empties the registry, so one test's tools do not leak into the next" do
      registry.register(tool_class: tool_class, policy: policy)
      registry.reset!

      expect(registry).to be_empty
      expect(registry.guard_for("invoice_search_tool")).to be_nil
    end
  end

  describe "Reeve.registry" do
    it "is the process-wide registry the DSL writes to" do
      expect(Reeve.registry).to be_a(described_class)
      expect(Reeve.registry).to equal(Reeve.registry)
    end
  end
end
