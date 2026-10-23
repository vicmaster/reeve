# frozen_string_literal: true

require "openssl"
require "reeve/audit"

# specs/002 T010 / FR-002, FR-003, research R1–R2 step 2, data-model "Canonical entry".
RSpec.describe Reeve::Audit::Chain::Canonical do
  let(:key) { "k" * 32 }
  let(:previous) { "0" * 64 }

  def entry(**overrides)
    {
      invocation_id: "inv-1", occurred_at: Time.utc(2026, 10, 8, 12, 0, 0, 123_456r),
      agent_id: "claude-desktop", agent_name: nil, principal_type: "User", principal_id: "7",
      tool_name: "invoice_search", arguments: { "query" => "acme" }, outcome: "allow",
      rule: "InvoicePolicy#index?", detail: nil, record_type: "Invoice", record_ids: %w[1 2],
      record_count: 2, truncated: false, derived: false, guard: "policy", duration_ms: 3,
      metadata: nil, contract_version: 3, chain_sequence: 1, chain_key_id: "abcdef0123456789"
    }.merge(overrides)
  end

  def digest(row = entry, previous_digest: previous)
    described_class.entry_digest(key, row, previous_digest: previous_digest)
  end

  describe ".dump" do
    it "sorts object keys at every depth" do
      expect(described_class.dump("b" => 1, "a" => { "d" => 2, "c" => 3 }))
        .to eq('{"a":{"c":3,"d":2},"b":1}')
    end

    it "treats symbol and string keys alike, since the database returns strings" do
      expect(described_class.dump(a: 1)).to eq(described_class.dump("a" => 1))
    end

    it "writes one number one way, however the database spelled it back" do
      spellings = [1.0e20, 100_000_000_000_000_000_000, BigDecimal("1e20")]

      expect(spellings.map { |n| described_class.dump(n) }.uniq).to eq(["100000000000000000000"])
      expect(described_class.dump(1.0)).to eq(described_class.dump(1))
      expect(described_class.dump(0.1)).to eq("0.1")
      expect(described_class.dump(1.0e-07)).to eq("0.0000001")
      expect(described_class.dump(-0.0)).to eq("0")
    end

    it "keeps a string and a number apart" do
      expect(described_class.dump("1")).not_to eq(described_class.dump(1))
    end

    it "keeps nil, an empty object and an empty list apart" do
      expect([nil, {}, []].map { |value| described_class.dump(value) }.uniq.size).to eq(3)
    end

    it "keeps true and false typed rather than stringified" do
      expect(described_class.dump([true, false, "true"])).to eq('[true,false,"true"]')
    end

    it "escapes strings the same way every time, non-ASCII included" do
      expect(described_class.dump("añ\"\n")).to eq('"añ\\"\\n"')
    end

    it "refuses a value it has no canonical form for, rather than guessing one" do
      expect { described_class.dump(Object.new) }.to raise_error(ArgumentError, /canonical/)
    end
  end

  describe ".microseconds" do
    it "turns a time into integer microseconds since the epoch, in UTC" do
      local = Time.new(2026, 10, 8, 7, 0, 0.5r, "-05:00")

      expect(described_class.microseconds(local)).to eq(described_class.microseconds(Time.utc(2026, 10, 8, 12, 0, 0.5r)))
      expect(described_class.microseconds(Time.utc(1970, 1, 1, 0, 0, 1))).to eq(1_000_000)
    end
  end

  describe ".entry_digest" do
    it "is a hex HMAC-SHA256" do
      expect(digest).to match(/\A\h{64}\z/)
    end

    it "is the same for the same entry, read with string or symbol keys" do
      expect(digest(entry.transform_keys(&:to_s))).to eq(digest)
    end

    # Every field in the list, so a field cannot be skipped by forgetting to name it here.
    # contract_version is the exception: it selects the field list, and a version with no
    # list is refused (see "refuses a contract version" below) rather than digested.
    it "changes with every field it covers" do
      different = {
        occurred_at: Time.utc(2026, 10, 8, 12, 0, 0, 123_457r), arguments: { "query" => "acmf" },
        record_ids: %w[1 3], record_count: 3, truncated: true, derived: true, duration_ms: 4,
        metadata: {}, chain_sequence: 2, agent_name: "x", detail: "x"
      }
      fields = described_class::ENTRY_FIELDS.fetch(3) - %w[contract_version]

      fields.each do |field|
        value = different.fetch(field.to_sym) { "#{entry[field.to_sym]}-changed" }
        expect(digest(entry(field.to_sym => value))).not_to eq(digest), "#{field} is not covered"
      end
    end

    it "changes with the predecessor's digest, which is what links the chain" do
      expect(digest(previous_digest: "1" * 64)).not_to eq(digest)
    end

    it "ignores the primary key and the stored digest, which the database or the chain assigns" do
      expect(digest(entry(id: 99, chain_digest: "f" * 64))).to eq(digest)
    end

    it "depends on the key" do
      other = described_class.entry_digest("x" * 32, entry, previous_digest: previous)

      expect(other).not_to eq(digest)
    end

    it "matches the documented construction exactly" do
      expected = OpenSSL::HMAC.hexdigest(
        "SHA256", key, "reeve-ledger-entry-v1\n#{described_class.entry_message_body(entry, previous)}"
      )

      expect(digest).to eq(expected)
    end
  end

  describe "the field list" do
    it "is written out in data-model order, not derived from the table" do
      expect(described_class::ENTRY_FIELDS.fetch(3)).to eq(%w[
                                                             chain_sequence chain_key_id contract_version
                                                             invocation_id occurred_at agent_id agent_name principal_type principal_id
                                                             tool_name arguments outcome rule detail record_type record_ids record_count
                                                             truncated derived guard duration_ms metadata
                                                           ])
    end

    # A future column must be added to the digest on purpose. If the install template
    # gains one and this list does not, this fails rather than leaving it uncovered.
    it "covers every column the install template creates, except id and chain_digest" do
      require_relative "../support/ledger"
      Ledger.prepare!

      columns = Reeve::Audit::Entry.column_names - %w[id chain_digest]
      expect(columns - described_class::ENTRY_FIELDS.fetch(Reeve::Audit::CONTRACT_VERSION)).to eq([])
    end

    it "refuses a contract version it has no field list for" do
      expect { digest(entry(contract_version: 2)) }.to raise_error(ArgumentError, /contract/)
    end
  end

  describe ".genesis_digest" do
    let(:genesis) do
      { genesis_at: Time.utc(2026, 10, 8), pre_chain_count: 5000, pre_chain_unchained_count: 0,
        genesis_key_id: "abcdef0123456789" }
    end

    it "covers every genesis field, under its own tag" do
      base = described_class.genesis_digest(key, genesis)

      expect(base).to match(/\A\h{64}\z/)
      genesis.each_key do |field|
        tampered = genesis.merge(field => field == :genesis_at ? Time.utc(2026, 10, 9) : "x")
        expect(described_class.genesis_digest(key, tampered)).not_to eq(base), "#{field} is not covered"
      end
    end

    it "can never equal an entry digest over the same text, because the tags differ" do
      expect(OpenSSL::HMAC.hexdigest("SHA256", key, "reeve-ledger-genesis-v1\n[]"))
        .not_to eq(OpenSSL::HMAC.hexdigest("SHA256", key, "reeve-ledger-entry-v1\n[]"))
    end
  end
end
