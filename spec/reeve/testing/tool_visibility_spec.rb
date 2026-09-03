# frozen_string_literal: true

require_relative "support/fixtures"

# What population the compliance suite walks.
#
# It used to walk the guard registry, which holds one entry per `guard_with` — so every
# subject it checked had a guard by construction, and `GuardDeclared`, the check whose
# whole job is naming the tools that lack one, could not fail. An application with three
# guarded tools and one that was forgotten reported "4 checks, 4 passed": a green
# compliance run offered as evidence for a claim it never tested.
RSpec.describe "which tools the compliance suite can see", :reeve_fixtures do
  def guarded_tool
    stub_const("GuardedThing", Class.new do
      include Reeve::Guard

      guard_with ReeveFixtures::GoodInvoicePolicy
      def call = []
    end)
  end

  def forgotten_tool
    stub_const("ForgottenThing", Class.new do
      include Reeve::Guard

      def call = []
    end)
  end

  describe "the registry" do
    it "knows a tool that included the DSL but declared nothing" do
      guarded_tool
      forgotten_tool

      expect(Reeve.registry.tool_classes).to include(GuardedThing, ForgottenThing)
      expect(Reeve.registry.unguarded_tool_classes).to eq([ForgottenThing])
    end

    it "counts a declared tool once, however it arrived" do
      guarded_tool

      expect(Reeve.registry.tool_classes.count(GuardedThing)).to eq(1)
    end

    it "follows inheritance, which is how an adapter's tools acquire the DSL" do
      base = stub_const("BaseThing", Class.new { include Reeve::Guard })
      base.reeve_abstract!
      child = stub_const("ChildThing", Class.new(base) { def call = [] })

      expect(Reeve.registry.tool_classes).to include(child)
      expect(Reeve.registry.tool_classes).not_to include(base)
    end

    it "forgets a tool that is removed, so a fixture cannot outlive its example" do
      forgotten_tool
      Reeve.registry.remove(ForgottenThing)

      expect(Reeve.registry.tool_classes).not_to include(ForgottenThing)
    end
  end

  describe "Checks.run_all" do
    before do
      guarded_tool
      forgotten_tool
    end

    it "fails, naming the tool that has no guard" do
      report = Reeve::Checks.run(Reeve::Checks::GuardDeclared, principals: [alice, bob])

      expect(report).to be_failed
      expect(report.failures.map(&:message).join).to include("ForgottenThing")
    end

    it "still checks the guarded tool rather than stopping at the first gap" do
      report = Reeve::Checks.run(Reeve::Checks::GuardDeclared, principals: [alice, bob])

      expect(report.passes.map(&:message).join).to include("GuardedThing")
    end
  end

  # A retrofit is the normal state of an application adopting this. Reporting every
  # unguarded tool is right, and a build that is expected to be red is a build nobody
  # reads — so the host says what it has certified so far.
  describe "compliance_tools" do
    before do
      guarded_tool
      forgotten_tool
    end

    it "narrows the population to what the host claims" do
      Reeve.config.compliance_tools = -> { [GuardedThing] }

      report = Reeve::Checks.run(Reeve::Checks::GuardDeclared, principals: [alice, bob])

      expect(report).to be_passed
    end

    it "accepts a plain array as well as a callable" do
      Reeve.config.compliance_tools = [GuardedThing]

      expect(Reeve::Testing.compliance_tools).to eq([GuardedThing])
    end

    it "rejects anything that is neither" do
      expect { Reeve.config.compliance_tools = "GuardedThing" }
        .to raise_error(ArgumentError, /compliance_tools/)
    end

    it "defaults to every tool reeve knows about" do
      expect(Reeve::Testing.compliance_tools).to include(GuardedThing, ForgottenThing)
    end
  end
end
