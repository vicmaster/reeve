# frozen_string_literal: true

RSpec.describe "Reeve errors" do
  describe Reeve::Error do
    it "is the single ancestor every reeve error descends from" do
      expect(Reeve::DeniedError.ancestors).to include(Reeve::Error)
      expect(Reeve::AuditWriteError.ancestors).to include(Reeve::Error)
      expect(Reeve::Error.ancestors).to include(StandardError)
    end
  end

  describe Reeve::DeniedError do
    subject(:error) do
      described_class.new(
        tool_name: "invoice_search",
        principal_id: "42",
        rule: Reeve::Decision::NO_GUARD_DECLARED,
        detail: "InvoiceSearchTool has no guard_with declaration"
      )
    end

    # Constitution VI: errors name the principal, the tool, and the rule that denied.
    it "exposes the four facts a developer needs to fix the denial" do
      expect(error.tool_name).to eq("invoice_search")
      expect(error.principal_id).to eq("42")
      expect(error.rule).to eq("no_guard_declared")
      expect(error.detail).to eq("InvoiceSearchTool has no guard_with declaration")
    end

    it "names all four in the message" do
      expect(error.message).to include("invoice_search")
      expect(error.message).to include("42")
      expect(error.message).to include("no_guard_declared")
      expect(error.message).to include("has no guard_with declaration")
    end

    it "reads as a denial rather than a failure" do
      expect(error.message).to match(/denied/i)
    end

    it "builds from a decision" do
      decision = Reeve::Decision.deny(rule: "InvoicePolicy#index?", detail: "not the owner")
      built = described_class.from(decision, tool_name: "invoice_search", principal_id: 42)

      expect(built.rule).to eq("InvoicePolicy#index?")
      expect(built.detail).to eq("not the owner")
      expect(built.principal_id).to eq("42")
    end

    it "refuses to be built from an allowed decision" do
      allowed = Reeve::Decision.allow(rule: "InvoicePolicy#index?")

      expect { described_class.from(allowed, tool_name: "t", principal_id: 1) }
        .to raise_error(ArgumentError, /allow/)
    end

    it "renders an anonymous principal when none was resolved" do
      error = described_class.new(
        tool_name: "invoice_search", principal_id: nil, rule: Reeve::Decision::NO_PRINCIPAL
      )

      expect(error.principal_id).to be_nil
      expect(error.message).to include("no_principal")
      expect(error.message).to match(/principal/i)
    end

    it "tolerates a missing detail" do
      error = described_class.new(tool_name: "t", principal_id: "1", rule: "policy_error")

      expect(error.detail).to be_nil
      expect(error.message).not_to include("()")
    end
  end

  # FR-006: a record the principal may not see must not be revealed by the denial.
  describe "out-of-scope denials" do
    it "produces an identical message whichever record was asked for" do
      one = Reeve::DeniedError.out_of_scope(tool_name: "invoice_show", principal_id: "42")
      two = Reeve::DeniedError.out_of_scope(tool_name: "invoice_show", principal_id: "42")

      expect(one.message).to eq(two.message)
      expect(one.rule).to eq(Reeve::Decision::OUT_OF_SCOPE_RECORD)
    end

    it "accepts no record argument at all, so none can leak into the message" do
      expect(Reeve::DeniedError.method(:out_of_scope).parameters.map(&:last))
        .to contain_exactly(:tool_name, :principal_id)
    end

    it "says nothing about whether the record exists" do
      message = Reeve::DeniedError.out_of_scope(tool_name: "invoice_show", principal_id: "42").message

      expect(message).not_to match(/not found|missing|exists|deleted/i)
    end
  end

  describe Reeve::AuditWriteError do
    it "carries the invocation it failed to record and the cause" do
      cause = StandardError.new("connection reset")
      error = described_class.new(invocation_id: "abc-123", cause: cause)

      expect(error.invocation_id).to eq("abc-123")
      expect(error.original_error).to eq(cause)
      expect(error.message).to include("abc-123")
      expect(error.message).to include("connection reset")
    end
  end

  describe Reeve::ConfigurationError do
    it "is raised for misconfiguration and descends from Reeve::Error" do
      expect(described_class.ancestors).to include(Reeve::Error)
    end
  end
end
