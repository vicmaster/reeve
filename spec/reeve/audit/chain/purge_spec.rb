# frozen_string_literal: true

require "json"
require "securerandom"
require "tmpdir"
require_relative "../support/ledger"

# specs/005 US1 and US3 (FR-001–FR-008, FR-010, SC-001, SC-003): purging a prefix of the
# chain up to a checkpoint, verifying what remains, and refusing what cannot be proven.
RSpec.describe "purging the ledger" do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:anchor) { Ledger::RecordingAnchor.new }
  let(:new_key) { "reeve-spec-second-ledger-key-0123456789abcdef" }

  around do |example|
    Dir.mktmpdir("reeve-archive") do |dir|
      @dir = dir
      example.run
    end
  end

  before do
    Ledger.prepare!
    Reeve.config.ledger_anchor = anchor
    Reeve.config.ledger_retention_connection = Ledger.retention_connection
  end

  def row(**overrides)
    { invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
      arguments: { "n" => SecureRandom.hex(4) }, outcome: "allow", rule: "r", record_ids: [],
      guard: "policy", contract_version: Reeve::Audit::CONTRACT_VERSION }.merge(overrides)
  end

  # `count` entries, a checkpoint after every `every`.
  def write(count, every: nil, **overrides)
    count.times do |index|
      chain.append!(row(**overrides))
      Reeve::Audit::Chain.checkpoint! if every && ((index + 1) % every).zero?
    end
  end

  def archive_path(name = "ledger.jsonl")
    File.join(@dir, name)
  end

  def purge(**options)
    Reeve::Audit::Chain.purge!(archive: archive_path, confirm: true, **options)
  end

  def verify
    Reeve::Audit::Chain.verify
  end

  def sequences
    Reeve::Audit::Entry.where.not(chain_sequence: nil).order(:chain_sequence).pluck(:chain_sequence)
  end

  # Every row of every ledger table, for "nothing changed".
  def snapshot
    %w[reeve_audit_entries reeve_audit_chains reeve_audit_chain_epochs reeve_audit_retentions].to_h do |table|
      [table, ActiveRecord::Base.connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a]
    end
  end

  def configure(key, retired: [])
    Reeve.config.retired_ledger_keys = []
    Reeve.config.ledger_key = key
    Reeve.config.retired_ledger_keys = retired
  end

  # US1
  describe "a legitimate purge" do
    before { write(100, every: 10) }

    it "removes the prefix through the checkpoint, records it, and the rest verifies intact" do
      result = purge(through: 60)

      expect(result).to be_purged
      expect([result.through, result.removed_chained, result.purge]).to eq([60, 60, 0])
      expect(sequences).to eq((61..100).to_a)
      expect(Reeve::Audit::RetentionRecord.count).to eq(1)

      verification = verify
      expect(verification.status).to eq(:intact)
      expect(verification.covered).to eq(61..100)
      expect(verification.retention.boundary.through_sequence).to eq(60)
      expect(verification.to_s.lines.first).to include("sequences 61–100 verified", "1–60 purged (retention record 0, ")
    end

    it "reports what it would remove without CONFIRM, removing nothing" do
      before = snapshot

      result = purge(through: 60, confirm: false)

      expect(result).to be_dry_run
      expect(result.to_s).to start_with("reeve ledger purge: WOULD PURGE — sequences 1–60 through checkpoint #60 (")
      expect(snapshot).to eq(before)
      expect(File.exist?(archive_path)).to be(false)
    end

    # Written old, not backdated: occurred_at is inside the digest, so backdating is tampering
    # and the purge would refuse the ledger.
    it "picks the newest checkpoint whose entry is older than the cutoff" do
      Ledger.prepare!
      Reeve.config.ledger_anchor = Ledger::RecordingAnchor.new # the first ledger's checkpoints are gone with it
      write(45, every: 10, occurred_at: Time.now - (400 * 86_400))
      write(55, every: 10)

      result = purge(older_than: 365)

      expect(result.through).to eq(40)
    end

    it "says there is nothing to purge when no checkpoint is older than the cutoff" do
      result = purge(older_than: 365)

      expect(result.status).to eq(:nothing_to_purge)
      expect(sequences.size).to eq(100)
    end

    it "moves the boundary forward on a second purge, keeping the first record" do
      purge(through: 30)
      result = purge(through: 70, archive: archive_path("second.jsonl"))

      expect([result.purge, result.removed_chained]).to eq([1, 40])
      verification = verify
      expect(verification.status).to eq(:intact)
      expect(verification.retention.summaries.map(&:through_sequence)).to eq([30, 70])
      expect(verification.covered).to eq(71..100)
    end

    it "keeps verifying as new entries are written after it" do
      purge(through: 60)
      write(5)

      expect(verify.status).to eq(:intact)
      expect(verify.covered).to eq(61..105)
    end

    it "can purge without an archive when told to, and says so" do
      result = purge(through: 60, archive: nil, no_archive: true)

      expect(result.to_s).to include("no archive written (NO_ARCHIVE=1)")
      expect(Reeve::Audit::RetentionRecord.last.archived).to be(false)
      expect(verify.status).to eq(:intact)
    end

    it "writes the archive before anything is removed, and records its digest" do
      result = purge(through: 60)

      expect(File.exist?(archive_path)).to be(true)
      expect(Reeve::Audit::RetentionRecord.last.archive_sha256).to eq(Digest::SHA256.file(archive_path).hexdigest)
      expect(result.archive_sha256).to eq(Reeve::Audit::RetentionRecord.last.archive_sha256)
    end

    it "reports checkpoints below the boundary as purged and the one at it as checked" do
      purge(through: 60)

      statuses = verify.checkpoints.to_h { |found| [found.head_sequence, found.status] }

      expect(statuses.values_at(10, 50)).to all(eq(:purged))
      expect(statuses.values_at(60, 70, 100)).to all(eq(:checked))
      expect(verify.anchored_at.head_sequence).to eq(100)
    end
  end

  describe "rows outside the chain" do
    it "removes pre-chain rows with the first purge, and the summary says so" do
      Ledger.prepare!
      3.times { Reeve::Audit::Entry.create!(row(contract_version: 2)) }
      write(20, every: 10)

      result = purge(through: 10)

      expect(result.removed_pre_chain).to eq(3)
      expect(Reeve::Audit::Entry.where("contract_version < 3").count).to eq(0)
      expect(verify.status).to eq(:intact)
      expect(verify.to_s.lines.first).to include("(3 when the chain started, 3 purged)")
    end

    # Their place in time is known only by clock, so the purge leaves them (spec Clarifications).
    # One written after the chain began is a break of its own (specs/002) and the purge refuses
    # the ledger; one from before it is counted at the genesis and stays put.
    it "leaves unchained contract-3+ rows where they are" do
      Ledger.prepare!
      chain.append_unchained!(row) # what audit_failure_mode :warn writes without a key
      write(20, every: 10)

      expect { purge(through: 10) }.not_to(change { Reeve::Audit::Entry.where(chain_sequence: nil).count })
      expect(verify.status).to eq(:intact)
    end
  end

  describe "across rotations and stragglers" do
    it "purges through an epoch boundary and verifies" do
      write(10, every: 10)
      configure(new_key, retired: [Ledger::TEST_KEY])
      Reeve::Audit::Chain.rotate_key!
      write(10, every: 10)
      configure(Ledger::TEST_KEY, retired: [new_key]) # a straggler
      write(10, every: 10)

      expect(purge(through: 20)).to be_purged
      expect(verify.status).to eq(:intact)
    end
  end

  # FR-010: a purge stopped midway, or a restore that puts purged rows back.
  describe "rows still below the boundary" do
    before { write(100, every: 10) }

    it "reads as awaiting purge, not broken, and a rerun finishes and says it resumed" do
      calls = 0
      allow_any_instance_of(Reeve::Audit::Chain::Retention::Purge)
        .to receive(:delete_batch).and_wrap_original do |original, *args|
          calls += 1
          raise IOError, "the connection dropped" if calls > 1

          original.call(*args)
        end

      expect { purge(through: 60, batch_size: 10) }.to raise_error(IOError)
      expect(verify.status).to eq(:intact)
      expect(verify.awaiting_purge).to eq(50)
      expect(verify.to_s.lines.first).to include("50 entries awaiting purge")

      RSpec::Mocks.space.reset_all
      result = purge(through: 60)

      expect(result.to_s).to include("resumed; 50 rows removed this run")
      expect(sequences.first).to eq(61)
      expect(Reeve::Audit::RetentionRecord.count).to eq(1)
      expect(verify.awaiting_purge).to eq(0)
    end
  end

  # US2, SC-002: a removal no retention record accounts for, or an edited record, is BROKEN;
  # each beside the same removal done through the task, which is INTACT.
  describe "tampering passed off as a purge" do
    before { write(100, every: 10) }

    def kinds(verification = verify)
      verification.breaks.map(&:kind).uniq
    end

    def delete_rows(range)
      ActiveRecord::Base.connection.delete(
        "DELETE FROM reeve_audit_entries WHERE chain_sequence BETWEEN #{range.first} AND #{range.last}"
      )
    end

    it "is broken when old entries are deleted by hand, where the task's purge is intact" do
      delete_rows(1..60)
      expect(kinds).to include(:missing)
      expect(verify.status).to eq(:broken)
    end

    it "(twin) is intact when the same entries go through the task" do
      purge(through: 60)
      expect(verify.status).to eq(:intact)
    end

    it "is broken when entries above the boundary are also deleted" do
      purge(through: 60)
      delete_rows(61..70)

      expect(kinds).to include(:missing)
      expect(verify.breaks.find { |found| found.kind == :missing }.sequence).to eq(61..70)
    end

    it "is broken when the record's boundary is edited to cover more" do
      purge(through: 60)
      delete_rows(61..70)
      ActiveRecord::Base.connection.update("UPDATE reeve_audit_retentions SET through_sequence = 70")

      expect(kinds).to include(:retention_altered, :missing)
      expect(verify.status).to eq(:broken)
    end

    it "is broken when the record is deleted, leaving the purged range unaccounted for" do
      purge(through: 60)
      ActiveRecord::Base.connection.delete("DELETE FROM reeve_audit_retentions")

      expect(kinds).to include(:missing)
      expect(verify.breaks.find { |found| found.kind == :missing }.sequence).to eq(1..60)
    end

    it "is broken when a record is forged by someone without a key" do
      delete_rows(1..60)
      record = { "purge_number" => 0, "through_sequence" => 60, "through_digest" => "0" * 64, "previous_through" => 0,
                 "removed_chained" => 60, "removed_pre_chain" => 0, "archived" => false,
                 "archive_sha256" => nil, "purged_at" => Time.now.utc, "key_id" => Reeve.config.ledger_key_id,
                 "retention_digest" => SecureRandom.hex(32) }
      ActiveRecord::Base.connection.insert_fixture(record, "reeve_audit_retentions")

      expect(kinds).to include(:retention_altered, :missing)
    end

    # A record forged under a key nobody holds reads as unverifiable, not broken; a resumed
    # purge must not take it at its word and delete the rows below it.
    # The forger copies entry 60's real digest, so the anchor's checkpoint there agrees with it.
    it "refuses to resume from a record signed by a key this host does not hold" do
      real = Reeve::Audit::Entry.find_by(chain_sequence: 60).chain_digest
      record = { "purge_number" => 0, "through_sequence" => 60, "through_digest" => real, "previous_through" => 0,
                 "removed_chained" => 60, "removed_pre_chain" => 0, "archived" => false,
                 "archive_sha256" => nil, "purged_at" => Time.now.utc, "key_id" => "0123456789abcdef",
                 "retention_digest" => SecureRandom.hex(32) }
      ActiveRecord::Base.connection.insert_fixture(record, "reeve_audit_retentions")
      expect(verify.status).to eq(:unverifiable)
      expect(verify.awaiting_purge).to eq(60)

      result = purge(through: 60)

      expect(result.reason).to eq(:not_intact)
      expect(sequences.size).to eq(100)
    end

    # A record whose key is gone from this host can't be checked: never intact, never broken.
    # The entries verify with the old key; only the record needs the new one.
    it "is unverifiable when the record was signed by a key not configured here" do
      configure(new_key, retired: [Ledger::TEST_KEY])
      purge(through: 60)
      result = Reeve::Audit::Chain.verify(keys: [Ledger::TEST_KEY], checkpoints: [])

      expect(result.status).to eq(:unverifiable)
      expect(result.to_s).to include("1–60 purged (retention record 0, ")
      expect(result.breaks.map(&:kind)).to eq([:unknown_key])
      expect(result.breaks.first.retention).to eq(0)
      expect(result.covered).to eq(61..100)
    end
  end

  # US3, SC-003: every refusal leaves the ledger byte-identical.
  describe "refusals" do
    before { write(30, every: 10) }

    def refused(reason, **options)
      before = snapshot
      result = purge(**options)

      expect(result).to be_refused
      expect(result.reason).to eq(reason)
      expect(result.to_s).to start_with("reeve ledger purge: REFUSED —").and end_with("nothing was removed")
      expect(snapshot).to eq(before)
      result
    end

    it "with no key" do
      Reeve.config.ledger_key = nil
      refused(:no_key, through: 20)
    end

    it "with no anchor, naming the setting" do
      Reeve.config.ledger_anchor = nil
      expect(refused(:no_anchor, through: 20).to_s).to include("config.ledger_anchor")
    end

    it "with no retention connection, naming the setting" do
      Reeve.config.ledger_retention_connection = nil
      expect(refused(:no_retention_connection, through: 20).to_s).to include("config.ledger_retention_connection")
    end

    it "with the application's own role" do
      skip("SQLite has no roles") if SpecDatabase.sqlite?
      own = Class.new(ActiveRecord::Base) { self.abstract_class = true }
      stub_const("OwnRoleRecord", own)
      own.establish_connection(ActiveRecord::Base.connection_db_config.configuration_hash)
      Reeve.config.ledger_retention_connection = own

      refused(:application_role, through: 20)
    end

    it "at a sequence no checkpoint names, naming the nearest below and above" do
      expect(refused(:no_checkpoint, through: 25).to_s).to include("#20", "#30")
    end

    it "when the ledger does not verify intact, with its summary line" do
      ActiveRecord::Base.connection.update("UPDATE reeve_audit_entries SET tool_name = 'x' WHERE chain_sequence = 5")
      expect(refused(:not_intact, through: 20).to_s).to include("BROKEN")
    end

    it "when part of the range is signed by a key this host does not hold" do
      configure(new_key) # the old key is gone from this host
      refused(:not_intact, through: 20)
    end

    it "without ARCHIVE or NO_ARCHIVE" do
      expect(refused(:no_archive_choice, through: 20, archive: nil).to_s).to include("ARCHIVE=", "NO_ARCHIVE=1")
    end

    it "with an archive path that already exists" do
      File.write(archive_path, "kept")
      refused(:archive_exists, through: 20)
      expect(File.read(archive_path)).to eq("kept")
    end

    it "with an archive path that cannot be written" do
      refused(:archive_unwritable, through: 20, archive: File.join(@dir, "missing", "ledger.jsonl"))
    end

    it "with both or neither of THROUGH and OLDER_THAN" do
      expect { purge(through: 20, older_than: 30) }.to raise_error(ArgumentError, /exactly one/)
      expect { purge }.to raise_error(ArgumentError, /exactly one/)
    end

    it "while another purge holds the next record number" do
      allow_any_instance_of(Reeve::Audit::Chain::Retention::Purge)
        .to receive(:insert_record).and_raise(ActiveRecord::RecordNotUnique, "duplicate purge")

      refused(:purge_running, through: 20)
    end
  end
end
