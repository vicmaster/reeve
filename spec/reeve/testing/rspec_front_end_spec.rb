# frozen_string_literal: true

require_relative "support/fixtures"
require "reeve/rspec"

# T050. The RSpec front-end holds no logic of its own: every matcher here delegates to a
# check and prints the sentence the check built (FR-019). The specs below therefore assert
# on delegation and on the entry points, not on message wording — that is checks_spec's
# job, and parity_spec proves the two never diverge.
RSpec.describe Reeve::Testing::Matchers, :reeve_fixtures do
  include Reeve::Testing::Matchers

  let(:control) { ReeveFixtures::CompliantInvoiceTool }
  let(:leaker)  { ReeveFixtures::LeakyInvoiceTool }

  describe "deny_access_for" do
    it "passes when the tool returns the principal nothing" do
      expect(ReeveFixtures::UnguardedInvoiceTool).to deny_access_for(bob)
    end

    it "fails when the tool returns records the principal may not see" do
      expect(leaker).not_to deny_access_for(bob)
    end

    it "prints the message the check built" do
      matcher = deny_access_for(bob)
      matcher.matches?(leaker)

      expect(matcher.failure_message).to eq(
        Reeve::Checks::CrossPrincipalLeak
          .new(tool: leaker, principals: [bob], expect: :nothing).call.message
      )
    end

    it "passes the arguments given to .with through to the tool" do
      matcher = deny_access_for(alice).with(query: "B")
      matcher.matches?(control)

      # Alice owns no B-numbered invoice, so a narrowed query returns her nothing.
      expect(matcher.result).to be_passed
    end
  end

  describe "audit_every_call" do
    it "passes for a tool invoked through the envelope" do
      expect(control).to audit_every_call.for_principal(alice)
    end

    it "fails for a tool invoked outside the envelope" do
      expect(ReeveFixtures::BypassingInvoiceTool)
        .not_to audit_every_call.for_principal(alice)
                                .invoked_by(ReeveFixtures::BYPASSING_INVOKER)
    end

    it "falls back to the first compliance principal when none is given" do
      Reeve::Testing.compliance_principals = -> { ReeveFixtures.principals }

      expect(control).to audit_every_call
    end
  end

  # SC-009: every check is reachable from RSpec, not only the two with named matchers.
  describe "pass_reeve_check" do
    it "accepts any check object and reports its result" do
      expect(Reeve::Checks::GuardDeclared.new(tool: control)).to pass_reeve_check
    end

    it "fails with the check's own message" do
      check = Reeve::Checks::GuardDeclared.new(tool: ReeveFixtures::UnguardedInvoiceTool)
      matcher = pass_reeve_check
      matcher.matches?(check)

      expect(matcher.failure_message).to eq(check.call.message)
    end
  end

  describe "the compliance shared example group" do
    it "is registered under the name the contract documents" do
      expect(RSpec.world.shared_example_group_registry.find([:main], "a reeve-compliant server"))
        .not_to be_nil
    end
  end
end

# The contract's own usage, run for real. If the fixtures are compliant this group is
# green; the deliberately broken ones are excluded because they are meant to fail.
RSpec.describe "a compliant server", :reeve_fixtures do
  before do
    Reeve.reset_registry!
    ReeveFixtures::CompliantInvoiceTool.redact(:customer_ssn)
    ReeveFixtures::CompliantInvoiceTool.guard_with(ReeveFixtures::GoodInvoicePolicy)
    Reeve::Testing.compliance_principals = -> { ReeveFixtures.principals }
    Reeve.config.inventory = Reeve::Inventory.new(
      registered: %w[search_invoices],
      routed: { "search_invoices" => ReeveFixtures::CompliantInvoiceTool }
    )
  end

  after { Reeve::Testing.reset! }

  it_behaves_like "a reeve-compliant server"
end

# Without an inventory, endpoint coverage is something the run did not establish. The
# shared group must say so as a pending example — visible in the run's output — rather
# than as a green one.
RSpec.describe "the shared group with no inventory declared", :reeve_fixtures do
  it "marks endpoint coverage pending, with its reason, and passes the rest" do
    Reeve::Testing.compliance_principals = -> { ReeveFixtures.principals }
    Reeve::Testing.compliance_tools = [ReeveFixtures::CompliantInvoiceTool]

    # Set up inside the inner group: spec_helper resets the registry and the configuration
    # before every example, the inner ones included, so a guard or a recorder configured
    # out here would be gone by the time they ran. Before this was moved, every per-tool
    # check in this example passed over no tools at all.
    group = RSpec.describe("inner") do
      before do
        Reeve.config.audit_recorder = Reeve::Audit::Recorder
        ReeveFixtures::CompliantInvoiceTool.redact(:customer_ssn)
        ReeveFixtures::CompliantInvoiceTool.guard_with(ReeveFixtures::GoodInvoicePolicy)
      end

      it_behaves_like "a reeve-compliant server"
    end
    group.run(RSpec::Core::NullReporter)
    statuses = group.descendants.flat_map(&:examples).to_h do |example|
      [example.description[/satisfies (\w+)/, 1], example.execution_result]
    end

    expect(statuses.fetch("EndpointCoverage").status).to eq(:pending)
    expect(statuses.fetch("EndpointCoverage").pending_message)
      .to include("no endpoint inventory is declared")
    expect(statuses.except("EndpointCoverage").values.map(&:status)).to all(eq(:passed))
  ensure
    RSpec.world.example_groups.delete(group) if group
    Reeve::Testing.reset!
  end
end

# With nothing registered, a per-tool check has nothing to look at. The shared group must
# show each one pending with its reason, not green over zero tools.
RSpec.describe "the shared group with no tools to check", :reeve_fixtures do
  it "marks every per-tool check pending, with its reason" do
    Reeve::Testing.compliance_principals = -> { ReeveFixtures.principals }

    group = RSpec.describe("inner") do
      before { Reeve.reset_registry! }

      it_behaves_like "a reeve-compliant server"
    end
    group.run(RSpec::Core::NullReporter)
    statuses = group.descendants.flat_map(&:examples).to_h do |example|
      [example.description[/satisfies (\w+)/, 1], example.execution_result]
    end
    per_tool = statuses.except("ContractVersion", "EndpointCoverage", "LedgerChain")

    expect(per_tool.size).to eq(6)
    expect(per_tool.values.map(&:status)).to all(eq(:pending))
    expect(per_tool.values.map(&:pending_message)).to all(include("no compliance tools to check"))
  ensure
    RSpec.world.example_groups.delete(group) if group
    Reeve::Testing.reset!
  end
end

# specs/002 T041: the same ledger-chain failure through the RSpec shared group carries the
# check's own words, character for character, as it does through Minitest.
RSpec.describe "the shared group's ledger chain with no key configured", :reeve_fixtures do
  it "fails, with the message the check built" do
    Reeve::Testing.compliance_principals = -> { ReeveFixtures.principals }
    Reeve::Testing.compliance_tools = [ReeveFixtures::CompliantInvoiceTool]

    group = RSpec.describe("inner") do
      before do
        Reeve.config.audit_recorder = Reeve::Audit::Recorder
        Reeve.config.ledger_key = nil
        ReeveFixtures::CompliantInvoiceTool.guard_with(ReeveFixtures::GoodInvoicePolicy)
      end

      it_behaves_like "a reeve-compliant server"
    end
    group.run(RSpec::Core::NullReporter)
    ledger = group.descendants.flat_map(&:examples).find { |e| e.description.include?("LedgerChain") }

    Reeve.config.ledger_key = nil
    expected = Reeve::Checks.run(Reeve::Checks::LedgerChain, principals: ReeveFixtures.principals).to_s
    expect(ledger.execution_result.status).to eq(:failed)
    expect(ledger.execution_result.exception.message).to eq(expected)
  ensure
    RSpec.world.example_groups.delete(group) if group
    Reeve::Testing.reset!
  end
end
