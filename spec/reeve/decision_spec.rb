# frozen_string_literal: true

RSpec.describe Reeve::Decision do
  describe ".allow" do
    it "builds an allowed decision carrying the rule that allowed it" do
      decision = described_class.allow(rule: "InvoicePolicy#index?")

      expect(decision).to be_allowed
      expect(decision).not_to be_denied
      expect(decision.outcome).to eq(:allow)
      expect(decision.rule).to eq("InvoicePolicy#index?")
      expect(decision.detail).to be_nil
    end

    it "accepts an optional human-readable detail" do
      decision = described_class.allow(rule: "InvoicePolicy#index?", detail: "scoped to owner")

      expect(decision.detail).to eq("scoped to owner")
    end
  end

  describe ".deny" do
    it "builds a denied decision carrying the rule that denied it" do
      decision = described_class.deny(rule: Reeve::Decision::NO_PRINCIPAL)

      expect(decision).to be_denied
      expect(decision).not_to be_allowed
      expect(decision.outcome).to eq(:deny)
      expect(decision.rule).to eq("no_principal")
    end
  end

  # Constitution I and FR-009: a decision with no rule is not a decision.
  describe "the rule requirement" do
    it "rejects a nil rule on allow" do
      expect { described_class.allow(rule: nil) }
        .to raise_error(ArgumentError, /rule/)
    end

    it "rejects a nil rule on deny" do
      expect { described_class.deny(rule: nil) }
        .to raise_error(ArgumentError, /rule/)
    end

    it "rejects a blank rule" do
      expect { described_class.deny(rule: "   ") }.to raise_error(ArgumentError, /rule/)
      expect { described_class.deny(rule: "") }.to raise_error(ArgumentError, /rule/)
    end

    it "coerces a symbol rule to a string so ledger values stay comparable" do
      expect(described_class.deny(rule: :no_principal).rule).to eq("no_principal")
    end

    it "rejects an outcome that is neither allow nor deny" do
      expect { described_class.new(outcome: :maybe, rule: "x") }
        .to raise_error(ArgumentError, /outcome/)
    end
  end

  describe "reserved rule identifiers" do
    # These strings are matched on by the testing kit and by host applications.
    # Renaming one is a breaking change; this spec is the tripwire.
    it "names every core deny path from data-model.md" do
      expect(described_class::RESERVED_RULES).to contain_exactly(
        "no_guard_declared",
        "no_principal",
        "policy_error",
        "unknown_record_type",
        "unscoped_derived_result",
        "out_of_scope_record",
        "audit_write_failed",
        "tool_error"
      )
    end

    it "exposes each one as a constant" do
      expect(described_class::NO_GUARD_DECLARED).to eq("no_guard_declared")
      expect(described_class::NO_PRINCIPAL).to eq("no_principal")
      expect(described_class::POLICY_ERROR).to eq("policy_error")
      expect(described_class::UNKNOWN_RECORD_TYPE).to eq("unknown_record_type")
      expect(described_class::UNSCOPED_DERIVED_RESULT).to eq("unscoped_derived_result")
      expect(described_class::OUT_OF_SCOPE_RECORD).to eq("out_of_scope_record")
      expect(described_class::AUDIT_WRITE_FAILED).to eq("audit_write_failed")
      expect(described_class::TOOL_ERROR).to eq("tool_error")
    end

    it "names the one reserved allow rule separately from the deny paths" do
      expect(described_class::UNGUARDED_TOOL).to eq("unguarded_tool")
      expect(described_class::RESERVED_RULES).not_to include("unguarded_tool")
    end

    it "reports whether a rule came from the core rather than a policy" do
      expect(described_class.deny(rule: "no_principal")).to be_reserved_rule
      expect(described_class.deny(rule: "InvoicePolicy#index?")).not_to be_reserved_rule
    end

    it "does not restrict rules to the reserved set — policies name their own" do
      expect(described_class.deny(rule: "InvoicePolicy::Scope").rule).to eq("InvoicePolicy::Scope")
    end
  end

  describe "immutability" do
    it "is frozen on construction" do
      expect(described_class.allow(rule: "ok")).to be_frozen
    end

    it "exposes no writers" do
      decision = described_class.allow(rule: "ok")

      expect(decision).not_to respond_to(:rule=)
      expect(decision).not_to respond_to(:outcome=)
      expect(decision).not_to respond_to(:detail=)
    end
  end

  describe "value semantics" do
    it "is equal to another decision with the same outcome, rule and detail" do
      expect(described_class.deny(rule: "no_principal"))
        .to eq(described_class.deny(rule: "no_principal"))
    end

    it "differs when the rule differs" do
      expect(described_class.deny(rule: "no_principal"))
        .not_to eq(described_class.deny(rule: "policy_error"))
    end

    it "differs when the outcome differs" do
      expect(described_class.allow(rule: "same")).not_to eq(described_class.deny(rule: "same"))
    end
  end

  describe "#to_h" do
    it "returns the ledger-facing shape" do
      decision = described_class.deny(rule: "policy_error", detail: "boom")

      expect(decision.to_h).to eq(outcome: "deny", rule: "policy_error", detail: "boom")
    end
  end
end
