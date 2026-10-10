# frozen_string_literal: true

require_relative "support/fixtures"
require "minitest"
require "reeve/minitest"

# T051. The acceptance bar is a stock `rails new` application — Minitest, no RSpec —
# proving every guarantee. So these examples drive real Minitest::Test instances rather
# than calling the assertion methods on a bare object: if `assert` behaved differently
# under a real test case, this spec would be measuring the wrong thing.
RSpec.describe Reeve::Testing::Assertions, :reeve_fixtures do
  let(:control) { ReeveFixtures::CompliantInvoiceTool }
  let(:leaker)  { ReeveFixtures::LeakyInvoiceTool }

  # Runs one assertion inside a real Minitest::Test and reports how it went.
  def run_assertion(&block)
    test_case = Class.new(Minitest::Test) do
      include Reeve::Testing::Assertions

      define_method(:test_subject, &block)
    end

    test_case.new(:test_subject).test_subject
    [:passed, nil]
  rescue Minitest::Assertion => e
    [:failed, e.message]
  end

  describe "assert_denies_access_for" do
    it "passes when the tool returns the principal nothing" do
      tool = ReeveFixtures::UnguardedInvoiceTool
      principal = bob

      expect(run_assertion { assert_denies_access_for(tool, principal) }).to eq([:passed, nil])
    end

    it "fails with the check's own message" do
      tool = leaker
      principal = bob
      expected = Reeve::Checks::CrossPrincipalLeak
                 .new(tool: tool, principals: [principal], expect: :nothing).call.message

      outcome, message = run_assertion { assert_denies_access_for(tool, principal) }

      expect(outcome).to eq(:failed)
      expect(message).to eq(expected)
    end

    it "forwards keyword arguments to the tool" do
      tool = control
      principal = alice

      expect(run_assertion { assert_denies_access_for(tool, principal, query: "B") })
        .to eq([:passed, nil])
    end
  end

  describe "assert_audits_every_call" do
    it "passes for a tool invoked through the envelope" do
      tool = control
      principal = alice

      expect(run_assertion { assert_audits_every_call(tool, principal: principal) })
        .to eq([:passed, nil])
    end

    it "fails, naming the bypass, for a tool invoked outside the envelope" do
      tool = ReeveFixtures::BypassingInvoiceTool
      principal = alice
      invoker = ReeveFixtures::BYPASSING_INVOKER

      outcome, message = run_assertion do
        assert_audits_every_call(tool, principal: principal, invoke: invoker)
      end

      expect(outcome).to eq(:failed)
      expect(message).to include("it is invoked outside Reeve.invoke")
    end
  end

  # SC-009: all seven reachable, not only the two with named assertions.
  describe "assert_reeve_check" do
    it "passes a check that holds" do
      check = Reeve::Checks::GuardDeclared.new(tool: control)

      expect(run_assertion { assert_reeve_check(check) }).to eq([:passed, nil])
    end

    it "fails with the check's own message" do
      check = Reeve::Checks::GuardDeclared.new(tool: ReeveFixtures::UnguardedInvoiceTool)
      expected = check.call.message

      outcome, message = run_assertion { assert_reeve_check(check) }

      expect(outcome).to eq(:failed)
      expect(message).to eq(expected)
    end
  end

  describe Reeve::Testing::ComplianceAssertions do
    def reeve_test_methods(klass)
      klass.public_instance_methods.grep(/^test_reeve_/).map(&:to_s)
    end

    let(:test_case) do
      Class.new(Minitest::Test) { include Reeve::Testing::ComplianceAssertions }
    end

    before do
      Reeve.reset_registry!
      ReeveFixtures::CompliantInvoiceTool.redact(:customer_ssn)
      ReeveFixtures::CompliantInvoiceTool.guard_with(ReeveFixtures::GoodInvoicePolicy)
      Reeve::Testing.compliance_principals = -> { ReeveFixtures.principals }
    end

    after { Reeve::Testing.reset! }

    it "defines one runnable test method per check" do
      expect(reeve_test_methods(test_case)).to contain_exactly(
        "test_reeve_cross_principal_leak", "test_reeve_audit_coverage",
        "test_reeve_guard_declared", "test_reeve_rule_present",
        "test_reeve_redaction_holds", "test_reeve_principal_required",
        "test_reeve_contract_version", "test_reeve_endpoint_coverage",
        "test_reeve_ledger_chain"
      )
    end

    it "passes every one of them against a compliant registry" do
      Reeve.config.inventory = Reeve::Inventory.new(
        registered: %w[search_invoices],
        routed: { "search_invoices" => ReeveFixtures::CompliantInvoiceTool }
      )

      results = reeve_test_methods(test_case).map do |method|
        test_case.new(method).public_send(method)
        :passed
      rescue Minitest::Assertion => e
        [:failed, e.message]
      end

      expect(results).to all(eq(:passed))
    end

    it "skips endpoint coverage, with its reason, when no inventory is declared" do
      expect { test_case.new("x").test_reeve_endpoint_coverage }
        .to raise_error(Minitest::Skip, /no endpoint inventory is declared/)
    end

    # specs/002 T041 / FR-018: the ledger chain, from Minitest.
    it "skips the ledger chain, with its reason, when there is no tool to write with" do
      Reeve::Testing.compliance_tools = []

      expect { test_case.new("x").test_reeve_ledger_chain }
        .to raise_error(Minitest::Skip, /the ledger chain was not verified/)
    end

    it "fails the ledger chain with the check's own words when no key is configured" do
      Reeve.config.ledger_key = nil
      expected = Reeve::Checks.run(Reeve::Checks::LedgerChain, principals: ReeveFixtures.principals).to_s

      expect { test_case.new("x").test_reeve_ledger_chain }
        .to raise_error(Minitest::Assertion) { |error| expect(error.message).to eq(expected) }
      expect(expected).to include("config.ledger_key")
    end

    it "skips every per-tool method, with its reason, when there is no tool to check" do
      Reeve.reset_registry!
      global = Reeve::Checks::GLOBAL.map { |check| "test_reeve_#{check.check_name.gsub(/([a-z])([A-Z])/, '\\1_\\2').downcase}" }
      per_tool = reeve_test_methods(test_case) - global

      expect(per_tool.size).to eq(6)
      per_tool.each do |method|
        expect { test_case.new(method).public_send(method) }
          .to raise_error(Minitest::Skip, /no compliance tools to check/)
      end
    end

    it "fails the matching method, and names the tool, when a tool leaks" do
      ReeveFixtures::LeakyInvoiceTool.guard_with(ReeveFixtures::LeakyInvoicePolicy)

      expect { test_case.new("x").test_reeve_cross_principal_leak }
        .to raise_error(Minitest::Assertion, /ReeveFixtures::LeakyInvoiceTool/)
    end
  end

  it "loads without RSpec being what makes it work" do
    expect(Reeve::Testing::Assertions.instance_methods).to include(
      :assert_denies_access_for, :assert_audits_every_call, :assert_reeve_check
    )
  end
end
