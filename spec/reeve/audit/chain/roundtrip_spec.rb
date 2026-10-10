# frozen_string_literal: true

require_relative "../support/ledger"

# specs/002 T015 / FR-003, SC-002 — the gate for Phase 3.
#
# Every value below is one a database has a reason to hand back differently from how it
# was written: reordered JSON keys, a number respelled, a time rounded. Each is written
# through the Normalizer into the real table, read back, and must produce byte-identical
# canonical text. Run on SQLite locally and on PostgreSQL and MySQL in CI; if this is not
# green on all three, no chain code is written on top of it.
RSpec.describe "a ledger row's canonical form survives the database" do
  let(:normalizer) { Reeve::Audit::Chain::Normalizer.new(Reeve::Audit::Entry) }
  let(:previous) { "0" * 64 }

  before { Ledger.prepare! }

  def row(index, **overrides)
    {
      invocation_id: "roundtrip-#{index}",
      occurred_at: Time.utc(2026, 10, 8, 12, 0, 0, 123_456.789r),
      agent_id: "claude-desktop", agent_name: nil, principal_type: "User", principal_id: "7",
      tool_name: "invoice_search", arguments: { "query" => "acme" }, outcome: "allow",
      rule: "InvoicePolicy#index?", detail: nil, record_type: "Invoice", record_ids: %w[1 2],
      record_count: 2, truncated: false, derived: false, guard: "policy", duration_ms: 3,
      metadata: nil, contract_version: 3, chain_sequence: index, chain_key_id: "abcdef0123456789"
    }.merge(overrides)
  end

  def round_trip(written)
    normalized = normalizer.call(written)
    Reeve::Audit::Entry.create!(normalized)
    read_back = Reeve::Audit::Entry.find_by!(invocation_id: written[:invocation_id])

    [Reeve::Audit::Chain::Canonical.entry_message_body(normalized, previous),
     Reeve::Audit::Chain::Canonical.entry_message_body(read_back, previous)]
  end

  CORPUS = {
    "nested objects with keys in reverse order" =>
      { arguments: { "z" => 1, "m" => { "y" => 2, "b" => { "q" => 3, "a" => 4 } }, "a" => 0 } },
    "symbol keys and symbol values" => { arguments: { query: :acme, filters: { status: :open } } },
    "non-ASCII and four-byte characters" =>
      { arguments: { "name" => "añ 日本語 🎉" }, detail: "réservé — ✓", agent_name: "Agënt 🤖" },
    "quotes, backslashes, newlines and tabs" =>
      { arguments: { "q" => "a \"quoted\" \\ back\nslash\tand tab" } },
    "fractions and whole floats" => { arguments: { "a" => 0.1, "b" => 1.0, "c" => -2.5, "d" => 1.0e-07 } },
    "a float written with an exponent" => { arguments: { "big" => 1.0e20, "small" => 3.0e-12 } },
    "integers up to 2**53" => { arguments: { "n" => 2**53, "m" => -123_456_789_012, "z" => 0 } },
    "negative zero" => { arguments: { "z" => -0.0 } },
    "booleans and nulls inside JSON" => { arguments: { "list" => [true, false, nil], "t" => true } },
    "an empty object as metadata, which is not nil" => { metadata: {} },
    "metadata with nested transport detail" =>
      { metadata: { "headers" => { "X-Request-Id" => "abc", "Accept" => "*/*" }, "transport" => "http" } },
    "a Time inside the arguments" => { arguments: { "since" => Time.utc(2026, 1, 1, 0, 0, 0, 999_999.5r) } },
    "NaN and Infinity inside the arguments" => { arguments: { "nan" => Float::NAN, "inf" => -Float::INFINITY } },
    "an occurred_at with nanoseconds and a zone" =>
      { occurred_at: Time.new(2026, 10, 8, 7, 59, 59, "-05:00") + 0.999_999_999r },
    "a long identifier list" => { record_ids: (1..1000).map(&:to_s), record_count: 5000, truncated: true },
    "an empty argument object and empty identifier list" => { arguments: {}, record_ids: [], record_count: 0 },
    "a denied call with every optional field nil" =>
      { outcome: "deny", principal_type: nil, principal_id: nil, record_type: nil, duration_ms: nil,
        rule: "no_principal", derived: true }
  }.freeze

  CORPUS.each_with_index do |(label, overrides), index|
    it "is identical before and after for #{label}" do
      written, read = round_trip(row(index + 1, **overrides))

      expect(read).to eq(written)
    end
  end

  # `t.json` is PostgreSQL's `json` type, which keeps the text exactly as written. `jsonb` —
  # what many hosts switch to — reorders keys and respells numbers (1.0e+20 comes back as
  # an Integer), which is the case the canonical form exists for. The same corpus, through
  # a jsonb copy of the table.
  context "on a PostgreSQL ledger whose JSON columns are jsonb" do
    let(:jsonb_entry) do
      Class.new(Reeve::Audit::Entry) { self.table_name = "reeve_audit_entries_jsonb" }
    end
    let(:normalizer) { Reeve::Audit::Chain::Normalizer.new(jsonb_entry) }

    before do
      skip("jsonb is PostgreSQL's") unless SpecDatabase.adapter == "postgresql"

      connection = ActiveRecord::Base.connection
      connection.execute("DROP TABLE IF EXISTS reeve_audit_entries_jsonb")
      connection.execute("CREATE TABLE reeve_audit_entries_jsonb (LIKE reeve_audit_entries INCLUDING ALL)")
      %w[arguments record_ids metadata].each do |column|
        connection.execute("ALTER TABLE reeve_audit_entries_jsonb ALTER COLUMN #{column} " \
                           "TYPE jsonb USING #{column}::jsonb")
      end
    end

    after do
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS reeve_audit_entries_jsonb")
    end

    def round_trip(written)
      normalized = normalizer.call(written)
      jsonb_entry.create!(normalized)
      read_back = jsonb_entry.find_by!(invocation_id: written[:invocation_id])

      [Reeve::Audit::Chain::Canonical.entry_message_body(normalized, previous),
       Reeve::Audit::Chain::Canonical.entry_message_body(read_back, previous)]
    end

    it "really is reordering keys and respelling numbers, or this context proves nothing" do
      jsonb_entry.create!(normalizer.call(row(1, arguments: { "z" => 1, "a" => 1.0e20 })))
      stored = ActiveRecord::Base.connection.select_value(
        "SELECT arguments::text FROM reeve_audit_entries_jsonb WHERE invocation_id = 'roundtrip-1'"
      )

      expect(stored).to eq('{"a": 100000000000000000000, "z": 1}')
    end

    CORPUS.each_with_index do |(label, overrides), index|
      it "is identical before and after for #{label}" do
        written, read = round_trip(row(index + 1, **overrides))

        expect(read).to eq(written)
      end
    end
  end

  # The known limit, pinned rather than hidden (research R2). MySQL's JSON type stores a
  # number beyond double precision as a double, so the value read back is not the value
  # written. The chain reports such a row as a break — a false alarm, never a false pass.
  it "documents that an integer beyond double precision does not survive MySQL's JSON type" do
    written, read = round_trip(row(999, arguments: { "huge" => (2**64) + 1 }))

    if SpecDatabase.adapter == "mysql2"
      expect(read).not_to eq(written)
    else
      expect(read).to eq(written)
    end
  end
end
