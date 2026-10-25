# frozen_string_literal: true

require "openssl"
require "securerandom"
require_relative "../support/ledger"

# specs/005 FR-005, FR-009, data-model "reeve_audit_retentions": the retention record, its
# digest, and the checks verification applies to it; and the retention connection's guard.
RSpec.describe "retention records" do
  let(:canonical) { Reeve::Audit::Chain::Canonical }
  let(:keyring) { Reeve::Audit::Chain::Keyring.from(Reeve.config) }
  let(:genesis) { "g" * 64 }
  let(:breaks) { [] }
  let(:report) { ->(*args, **options) { breaks << [args, options] } }

  before { Ledger.prepare! }

  def fields(purge:, through:, previous: 0, **overrides)
    { "purge" => purge, "through_sequence" => through, "through_digest" => "d" * 64,
      "previous_through" => previous, "removed_chained" => through - previous,
      "removed_pre_chain" => 0, "archived" => true, "archive_sha256" => "a" * 64,
      "purged_at" => Time.utc(2026, 10, 25, 12, 0, 0, 123_456), "key_id" => keyring.signing_id }
      .merge(overrides)
  end

  # Signed and inserted as the purge does, linked to `previous_digest`.
  def record!(previous_digest:, **options)
    values = fields(**options)
    digest = Reeve::Audit::Chain::Retention::Digest.call(Ledger::TEST_KEY, values, previous_digest: previous_digest)
    ActiveRecord::Base.connection.insert_fixture(values.merge("retention_digest" => digest),
                                                 "reeve_audit_retentions")
    digest
  end

  def records
    Reeve::Audit::Chain::Retention::Records.read(entry_class: Reeve::Audit::Entry)
  end

  def check(keys: keyring)
    Reeve::Audit::Chain::Retention::Check.new(keyring: keys, report: report)
                                         .call(records, genesis_digest: genesis)
  end

  def kinds
    breaks.map { |args, _| args.first }
  end

  describe "the digest" do
    it "is the HMAC data-model.md gives, recomputed by hand" do
      values = fields(purge: 0, through: 6_000)
      pairs = Reeve::Audit::Chain::Retention::Digest::FIELDS.map do |field|
        [field, field == "purged_at" ? canonical.microseconds(values[field]) : values[field]]
      end
      body = canonical.dump([["previous_digest", genesis], *pairs])
      expected = OpenSSL::HMAC.hexdigest("SHA256", Ledger::TEST_KEY, "reeve-ledger-retention-v1\n#{body}")

      expect(Reeve::Audit::Chain::Retention::Digest.call(Ledger::TEST_KEY, values, previous_digest: genesis)).to eq(expected)
    end
  end

  describe Reeve::Audit::Chain::Retention::Check do
    it "accepts a chain of records, the first linked to the genesis, and names the boundary" do
      first = record!(previous_digest: genesis, purge: 0, through: 6_000)
      record!(previous_digest: first, purge: 1, through: 9_000, previous: 6_000)

      result = check

      expect(breaks).to be_empty
      expect(result.boundary.through_sequence).to eq(9_000)
      expect(result.summaries.map(&:status)).to eq(%i[verified verified])
    end

    it "has no boundary and nothing to say for a ledger never purged" do
      result = check

      expect(result.boundary).to be_nil
      expect(result.summaries).to be_empty
    end

    it "reports an edited record, and keeps the boundary at the record before it" do
      first = record!(previous_digest: genesis, purge: 0, through: 6_000)
      record!(previous_digest: first, purge: 1, through: 9_000, previous: 6_000)
      ActiveRecord::Base.connection.update("UPDATE reeve_audit_retentions SET through_sequence = 9500 WHERE purge = 1")

      result = check

      expect(kinds).to eq([:retention_altered])
      expect(result.boundary.through_sequence).to eq(6_000)
    end

    it "reports a deleted record by the break in the chain after it" do
      first = record!(previous_digest: genesis, purge: 0, through: 6_000)
      record!(previous_digest: first, purge: 1, through: 9_000, previous: 6_000)
      ActiveRecord::Base.connection.delete("DELETE FROM reeve_audit_retentions WHERE purge = 0")

      result = check

      expect(kinds).to eq([:retention_altered])
      expect(result.boundary).to be_nil
    end

    it "reports a record that does not link to the genesis" do
      record!(previous_digest: "x" * 64, purge: 0, through: 6_000)

      expect { check }.to change(self, :kinds).to([:retention_altered])
    end

    it "reports boundaries that do not follow on from each other" do
      first = record!(previous_digest: genesis, purge: 0, through: 6_000)
      record!(previous_digest: first, purge: 1, through: 5_000, previous: 6_000)

      expect(check.boundary.through_sequence).to eq(6_000)
      expect(kinds).to eq([:retention_altered])
    end

    # A key not held cannot check the record: unverifiable, never altered, never verified.
    it "reports a record signed by a key not configured as unknown, keeping it as the boundary" do
      record!(previous_digest: genesis, purge: 0, through: 6_000)
      other = Reeve::Audit::Chain::Keyring.new(signing: nil, retired: ["another-ledger-key-not-a-secret-0123456789"])

      result = check(keys: other)

      expect(kinds).to eq([:unknown_key])
      expect(result.boundary.through_sequence).to eq(6_000)
      expect(result.summaries.map(&:status)).to eq([:key_not_configured])
    end
  end

  describe Reeve::Audit::Chain::Retention::Connection do
    def connection_for(retention)
      described_class.new(retention, entry_class: Reeve::Audit::Entry)
    end

    it "needs one to be configured" do
      expect(connection_for(nil).problem).to eq(:no_retention_connection)
    end

    it "accepts the spec's retention connection" do
      guard = connection_for(Ledger.retention_connection)

      expect(guard.problem).to be_nil
      expect(guard.warnings).to eq(SpecDatabase.sqlite? ? [described_class::SQLITE_WARNING] : [])
    end

    it "refuses one that reaches another database" do
      other = Class.new(ActiveRecord::Base) { self.abstract_class = true }
      stub_const("OtherDatabaseRecord", other)
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      other.establish_connection(config.merge(database: SpecDatabase.sqlite? ? "#{config[:database]}.other" : "reeve_other"))

      expect(connection_for(other).problem).to eq(:other_database)
    end

    it "refuses the application's own role where roles exist" do
      skip("SQLite has no roles") if SpecDatabase.sqlite?
      own = Class.new(ActiveRecord::Base) { self.abstract_class = true }
      stub_const("OwnRoleRecord", own)
      own.establish_connection(ActiveRecord::Base.connection_db_config.configuration_hash)

      expect(connection_for(own).problem).to eq(:application_role)
    end
  end
end
