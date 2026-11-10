# frozen_string_literal: true

require "reeve/integrations"

RSpec.describe Reeve::Integrations do
  let(:recorder) { FakeRecorder.new }

  before do
    Reeve.configure do |c|
      c.audit_recorder = recorder
      c.principal_resolver = ->(_context) { Struct.new(:id).new(1) }
      c.unguarded_tools = :allow_with_warning
    end
  end

  def tool(name)
    Class.new do
      define_singleton_method(:tool_name) { name }
      define_singleton_method(:name) { name }
    end
  end

  describe ".inside?" do
    let(:search) { tool("search") }
    let(:other) { tool("other") }

    it "is true only while an envelope for that tool is open on this thread" do
      seen = Reeve.invoke(tool: search) do
        [described_class.inside?(search), described_class.inside?(other),
         Thread.new { described_class.inside?(search) }.value]
      end

      expect(seen).to eq([true, false, false])
      expect(described_class.inside?(search)).to be(false)
    end

    it "is false after an envelope that raised" do
      expect { Reeve.invoke(tool: search) { raise "boom" } }.to raise_error("boom")

      expect(described_class.inside?(search)).to be(false)
    end
  end

  describe ".require_version!" do
    it "passes a version inside the range" do
      expect { described_class.require_version!("reeve/x", "x", "1.4.0", ">= 1.0", "< 2.0") }
        .not_to raise_error
    end

    it "refuses one outside it, naming the gem, the version and the range" do
      expect { described_class.require_version!("reeve/x", "x", "2.1.0", ">= 1.0", "< 2.0") }
        .to raise_error(Reeve::ConfigurationError) { |e|
          expect(e.message).to include("reeve/x", "x 2.1.0", "< 2.0", ">= 1.0")
        }
    end
  end

  # A tool whose library runs it some other way than `new.call(**arguments)` says how,
  # so the testing kit can run it with no custom `invoke:` (R11).
  describe "the runner hook on Reeve.invoke" do
    it "runs a tool through reeve_run when the class defines it" do
      klass = tool("hooked")
      klass.define_singleton_method(:reeve_run) { |arguments| "ran with #{arguments[:q]}" }

      expect(Reeve.invoke(tool: klass, arguments: { q: "x" })).to eq("ran with x")
    end

    it "falls back to new.call(**arguments) otherwise" do
      klass = tool("plain")
      klass.define_method(:call) { |q:| "called with #{q}" }

      expect(Reeve.invoke(tool: klass, arguments: { q: "x" })).to eq("called with x")
    end
  end

  describe ".install!" do
    let(:base) { Class.new }
    let(:extension) { Module.new }
    let(:inheritance) do
      ext = extension
      hook = Module.new
      hook.define_singleton_method(:wrap) { |klass| klass.prepend(ext) unless klass.include?(ext) }
      hook.define_method(:inherited) do |subclass|
        super(subclass)
        hook.wrap(subclass)
      end
      hook
    end

    it "wraps subclasses at any depth defined before it, and every one defined after" do
      child = Class.new(base)
      grandchild = Class.new(child)

      described_class.install!(base, inheritance)
      later = Class.new(grandchild)

      expect([child, grandchild, later]).to all(satisfy { |k| k.include?(extension) })
    end

    it "gives the base the DSL and marks it abstract" do
      described_class.install!(base, inheritance)

      expect(base).to respond_to(:guard_with)
      expect(Reeve.registry.abstract?(base)).to be(true)
    end

    it "is idempotent" do
      child = Class.new(base)
      2.times { described_class.install!(base, inheritance) }

      expect(child.ancestors.count(extension)).to eq(1)
      expect(base.singleton_class.ancestors.count(inheritance)).to eq(1)
    end
  end
end
