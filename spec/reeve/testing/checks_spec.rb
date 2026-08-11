# frozen_string_literal: true

require_relative "support/fixtures"

# T045 / FR-016, FR-017, FR-019. One group per check in the contracts/testing-kit.md
# table: green on the control tool, red on a purpose-built violation, with the message and
# the structured details the contract promises.
RSpec.describe Reeve::Checks, :reeve_fixtures do
  let(:control)   { ReeveFixtures::CompliantInvoiceTool }
  let(:leaker)    { ReeveFixtures::LeakyInvoiceTool }
  let(:bypassing) { ReeveFixtures::BypassingInvoiceTool }

  describe Reeve::Checks::GuardDeclared do
    it "passes for a tool that declares a guard, naming the policy" do
      result = described_class.new(tool: control).call

      expect(result).to be_passed
      expect(result.message).to include("InvoicePolicy")
      expect(result.check).to eq("GuardDeclared")
    end

    it "fails for a tool with no guard_with declaration, naming the tool" do
      result = described_class.new(tool: ReeveFixtures::UnguardedInvoiceTool).call

      expect(result).not_to be_passed
      expect(result.message).to eq(
        "expected ReeveFixtures::UnguardedInvoiceTool to declare a guard, but it has no " \
        "guard_with declaration — reeve denies every call to an unguarded tool"
      )
      expect(result.details[:tool]).to eq("ReeveFixtures::UnguardedInvoiceTool")
    end
  end

  describe Reeve::Checks::CrossPrincipalLeak do
    it "passes when two principals' results are disjoint" do
      result = described_class.new(tool: control, principals: [alice, bob]).call

      expect(result).to be_passed
      expect(result.details[:leaked]).to eq([])
    end

    it "fails when a record reaches both principals, naming the leaked identifiers" do
      result = described_class.new(tool: leaker, principals: [alice, bob]).call

      expect(result).not_to be_passed
      expect(result.message).to start_with(
        "expected ReeveFixtures::LeakyInvoiceTool to return no records belonging to " \
        "another principal, but it returned 3 records to Owner#1 that also belong to Owner#2: "
      )
      expect(result.message).to include("(guard: InvoicePolicy, decision: allow via InvoicePolicy#index)")
      expect(result.details[:leaked].map(&:first).uniq).to eq(["Invoice"])
      expect(result.details[:leaked].size).to eq(3)
      expect(result.details[:rule]).to eq("InvoicePolicy#index")
    end

    # The `deny_access_for` front-end: one principal who must receive nothing at all.
    it "fails in :nothing mode when the principal receives any record" do
      result = described_class.new(tool: leaker, principals: [bob], expect: :nothing).call

      expect(result).not_to be_passed
      expect(result.message).to start_with(
        "expected ReeveFixtures::LeakyInvoiceTool to deny access for Owner#2, but it " \
        "returned 3 records that principal may not see: "
      )
    end

    it "passes in :nothing mode when the call is denied outright" do
      result = described_class.new(
        tool: ReeveFixtures::UnguardedInvoiceTool, principals: [bob], expect: :nothing
      ).call

      expect(result).to be_passed
      expect(result.details[:denials]).to eq(["no_guard_declared"])
    end
  end

  describe Reeve::Checks::AuditCoverage do
    it "passes when one invocation leaves exactly one ledger entry" do
      result = described_class.new(tool: control, principal: alice).call

      expect(result).to be_passed
      expect(result.details[:entries]).to eq(1)
    end

    it "fails when the tool is invoked outside the envelope, naming the tool" do
      result = described_class.new(
        tool: bypassing, principal: alice, invoke: ReeveFixtures::BYPASSING_INVOKER
      ).call

      expect(result).not_to be_passed
      expect(result.message).to eq(
        "expected every call to be audited, but ReeveFixtures::BypassingInvoiceTool " \
        "produced 0 audit entries for 1 invocation — it is invoked outside Reeve.invoke"
      )
    end

    it "fails, rather than passing silently, when the ledger cannot be read" do
      result = described_class.new(
        tool: control, principal: alice,
        ledger: ReeveFixtures::FakeLedger.new(available: false)
      ).call

      expect(result).not_to be_passed
      expect(result.message).to include("the audit ledger is not loaded")
    end
  end

  describe Reeve::Checks::RulePresent do
    it "passes when the entry names the rule that decided" do
      result = described_class.new(tool: control, principal: alice).call

      expect(result).to be_passed
      expect(result.details[:rules]).to eq(["InvoicePolicy#index"])
    end

    it "fails when an entry carries no rule" do
      entry = ReeveFixtures::RuleLessEntry.new(id: 9, rule: nil, outcome: "allow")
      result = described_class.new(
        tool: control, principal: alice, ledger: ReeveFixtures::FakeLedger.new(entries: [entry])
      ).call

      expect(result).not_to be_passed
      expect(result.message).to eq(
        "expected every audit entry for ReeveFixtures::CompliantInvoiceTool to name the " \
        "rule that decided, but entry 9 has no rule"
      )
    end
  end

  describe Reeve::Checks::RedactionHolds do
    it "passes when the declared-sensitive value reaches no column of the entry" do
      result = described_class.new(tool: control, principal: alice).call

      expect(result).to be_passed
      expect(result.details[:redacted]).to eq([:customer_ssn])
    end

    it "fails when a declared name is not an argument the tool accepts" do
      result = described_class.new(
        tool: ReeveFixtures::MisdeclaredRedactionTool, principal: alice
      ).call

      expect(result).not_to be_passed
      expect(result.message).to eq(
        "expected ReeveFixtures::MisdeclaredRedactionTool to redact ssn, but #call accepts " \
        "no such argument (it accepts query, customer_ssn), so the declaration redacts nothing"
      )
    end

    it "fails when the value survives into the written entry" do
      Reeve.config.audit_recorder = ReeveFixtures::UnredactingRecorder

      result = described_class.new(tool: control, principal: alice).call

      expect(result).not_to be_passed
      expect(result.message).to start_with(
        "expected ReeveFixtures::CompliantInvoiceTool to redact customer_ssn, but the " \
        "value passed for it appears in audit entry "
      )
    end
  end

  describe Reeve::Checks::PrincipalRequired do
    it "passes when an unresolvable principal denies with no_principal" do
      result = described_class.new(tool: control).call

      expect(result).to be_passed
      expect(result.details[:rule]).to eq("no_principal")
    end

    it "fails when the tool runs anyway, naming what it returned" do
      result = described_class.new(
        tool: bypassing, invoke: ReeveFixtures::BYPASSING_INVOKER
      ).call

      expect(result).not_to be_passed
      expect(result.message).to start_with(
        "expected ReeveFixtures::BypassingInvoiceTool to deny when no principal resolves, " \
        "but it allowed the call and returned 3 records: "
      )
    end
  end

  describe Reeve::Checks::ContractVersion do
    it "passes against the ledger this gem's migration creates" do
      result = described_class.new.call

      expect(result).to be_passed
      expect(result.details[:version]).to eq(Reeve::Audit::CONTRACT_VERSION)
    end

    # The expectation is written out rather than read off Entry, so the check is not
    # comparing the gem to itself. This is what keeps the two from drifting apart.
    it "expects the version the audit module actually implements" do
      expect(described_class::EXPECTED_VERSION).to eq(Reeve::Audit::CONTRACT_VERSION)
    end

    it "fails when the table is missing a column the contract requires" do
      short = described_class::COLUMNS - %w[guard metadata]
      result = described_class.new(ledger: ReeveFixtures::FakeLedger.new(columns: short)).call

      expect(result).not_to be_passed
      expect(result.message).to eq(
        "expected the ledger to implement audit-entry contract version 1, but " \
        "reeve_audit_entries is missing: guard, metadata — run `rails g reeve:install` " \
        "and migrate"
      )
    end

    it "fails when the ledger reports a different contract version" do
      result = described_class.new(
        ledger: ReeveFixtures::FakeLedger.new(contract_version: 2)
      ).call

      expect(result).not_to be_passed
      expect(result.message).to eq(
        "expected the ledger to implement audit-entry contract version 1, but it reports " \
        "version 2 — this reeve version cannot read that shape"
      )
    end
  end

  describe "the layer as a whole" do
    it "enumerates the seven checks the contract names" do
      expect(Reeve::Checks::ALL.map(&:check_name)).to contain_exactly(
        "CrossPrincipalLeak", "AuditCoverage", "GuardDeclared", "RulePresent",
        "RedactionHolds", "PrincipalRequired", "ContractVersion"
      )
    end

    it "raises nothing on failure — a check reports, it does not blow up" do
      expect { Reeve::Checks::CrossPrincipalLeak.new(tool: leaker, principals: [alice, bob]).call }
        .not_to raise_error
    end
  end
end
