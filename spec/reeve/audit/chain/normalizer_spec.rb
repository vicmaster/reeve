# frozen_string_literal: true

require_relative "../support/ledger"

# specs/002 T008 / FR-003, research R2 step 1: before a row is written it is put into the
# form the database will hand back, so that what is digested is what verification reads.
RSpec.describe Reeve::Audit::Chain::Normalizer do
  subject(:normalizer) { described_class.new(Reeve::Audit::Entry) }

  before { Ledger.prepare! }

  def row(**overrides)
    { invocation_id: "inv-1", occurred_at: Time.utc(2026, 10, 8, 12, 0, 0, 123_456.789r),
      arguments: { query: "acme" }, record_ids: %w[1 2], metadata: nil }.merge(overrides)
  end

  describe "JSON values" do
    it "turns symbol keys and symbol values into strings, at every depth" do
      normalized = normalizer.call(row(arguments: { filters: { status: :open } }))

      expect(normalized[:arguments]).to eq("filters" => { "status" => "open" })
    end

    it "renders a Time inside arguments the way ActiveRecord stores it" do
      normalized = normalizer.call(row(arguments: { since: Time.utc(2026, 1, 1, 12, 0, 0, 123_456r) }))

      expect(normalized[:arguments]["since"]).to eq("2026-01-01T12:00:00.123Z")
    end

    it "turns NaN and Infinity into nil, as the JSON encoder does" do
      normalized = normalizer.call(row(arguments: { a: Float::NAN, b: Float::INFINITY }))

      expect(normalized[:arguments]).to eq("a" => nil, "b" => nil)
    end

    it "keeps nil metadata nil and empty metadata empty — they mean different things" do
      expect(normalizer.call(row(metadata: nil))[:metadata]).to be_nil
      expect(normalizer.call(row(metadata: {}))[:metadata]).to eq({})
    end

    it "leaves every other field alone" do
      normalized = normalizer.call(row(invocation_id: "inv-9", principal_id: "42"))

      expect(normalized).to include(invocation_id: "inv-9", principal_id: "42")
    end
  end

  describe "occurred_at" do
    it "is floored to the column's precision, never rounded" do
      at = Time.utc(2026, 10, 8, 12, 0, 0, 999_999.9r)

      expect(normalizer.call(row(occurred_at: at))[:occurred_at])
        .to eq(Time.utc(2026, 10, 8, 12, 0, 0, 999_999r))
    end

    it "is converted to a plain UTC Time, whatever zone it arrived in" do
      at = Time.new(2026, 10, 8, 7, 0, 0, "-05:00")

      normalized = normalizer.call(row(occurred_at: at))[:occurred_at]
      expect(normalized).to eq(Time.utc(2026, 10, 8, 12, 0, 0))
      expect(normalized).to be_utc
    end
  end

  describe ".effective_precision" do
    def column(precision)
      instance_double(ActiveRecord::ConnectionAdapters::Column, precision: precision)
    end

    it "uses the precision the column declares" do
      expect(described_class.effective_precision(column(3), "postgresql")).to eq(3)
    end

    # A MySQL DATETIME declared without precision is whole seconds, and the server rounds
    # rather than truncates a fraction sent to it. The other engines keep microseconds.
    it "treats an undeclared precision as 0 on MySQL and 6 elsewhere" do
      expect(described_class.effective_precision(column(nil), "mysql2")).to eq(0)
      expect(described_class.effective_precision(column(nil), "trilogy")).to eq(0)
      expect(described_class.effective_precision(column(nil), "postgresql")).to eq(6)
      expect(described_class.effective_precision(column(nil), "sqlite3")).to eq(6)
    end
  end

  it "reads the column's precision once per normalizer, not once per row" do
    normalizer.call(row)
    allow(Reeve::Audit::Entry).to receive(:columns_hash).and_call_original

    2.times { normalizer.call(row) }

    expect(Reeve::Audit::Entry).not_to have_received(:columns_hash)
  end
end
