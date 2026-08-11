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
  end

  after { Reeve::Testing.reset! }

  it_behaves_like "a reeve-compliant server"
end
