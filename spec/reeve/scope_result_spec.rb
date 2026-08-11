# frozen_string_literal: true

RSpec.describe Reeve::ScopeResult do
  describe ".allow" do
    it "carries the scoped records and what the ledger needs to describe them" do
      result = described_class.allow(
        records: %w[a b], record_type: "Invoice", record_ids: [1, 2], record_count: 2
      )

      expect(result.decision).to be_allowed
      expect(result.records).to eq(%w[a b])
      expect(result.record_type).to eq("Invoice")
      expect(result.record_ids).to eq(%w[1 2])
      expect(result.record_count).to eq(2)
      expect(result).not_to be_truncated
      expect(result).not_to be_derived
    end

    it "defaults the count to the number of identifiers it was given" do
      expect(described_class.allow(records: [], record_ids: [7]).record_count).to eq(1)
    end

    it "marks a derived value, which has no records to enumerate" do
      result = described_class.allow(records: 12, derived: true)

      expect(result).to be_derived
      expect(result.record_ids).to eq([])
      expect(result.records).to eq(12)
    end

    it "marks truncation when the true count exceeds the identifiers recorded" do
      result = described_class.allow(records: [], record_ids: [1, 2], record_count: 900, truncated: true)

      expect(result).to be_truncated
      expect(result.record_count).to eq(900)
    end

    it "requires the allowing rule to be nameable" do
      expect(described_class.allow(records: []).decision.rule).to eq("scoped")
    end
  end

  describe ".deny" do
    it "carries the denying decision and returns no records" do
      result = described_class.deny(rule: Reeve::Decision::OUT_OF_SCOPE_RECORD)

      expect(result.decision).to be_denied
      expect(result.decision.rule).to eq("out_of_scope_record")
      expect(result.records).to be_nil
      expect(result.record_ids).to eq([])
      expect(result.record_count).to eq(0)
    end
  end

  it "is frozen" do
    expect(described_class.allow(records: [])).to be_frozen
  end
end
