# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "../support/ledger"

# specs/003 FR-010–FR-014, US2, US4, US5 scenario 3; SC-001–SC-003.
#
# Tampering is made at the relation level (`update_all`, `delete_all`), as a DBA or a stolen
# application credential would, and never with a key. Every legitimate sequence — rotation,
# stragglers, a verifier missing a key, an upgraded 0.6.0 ledger — must not read as BROKEN.
RSpec.describe "verifying a ledger across key epochs" do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:entries) { Reeve::Audit::Entry }
  let(:old_key) { Ledger::TEST_KEY }
  let(:new_key) { "reeve-spec-second-ledger-key-0123456789abcdef" }
  let(:stranger) { Reeve::LedgerKey.fingerprint("reeve-spec-key-nobody-configured-0123456789") }

  before { Ledger.prepare! }

  def row(**overrides)
    { invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
      arguments: { "q" => "x" }, outcome: "allow", rule: "r", record_ids: [], guard: "policy",
      contract_version: Reeve::Audit::CONTRACT_VERSION }.merge(overrides)
  end

  def configure(key, retired: [])
    Reeve.config.retired_ledger_keys = []
    Reeve.config.ledger_key = key
    Reeve.config.retired_ledger_keys = retired
  end

  # Epoch 0 (old key) over 1–3, epoch 1 (new key) from 4 on, both keys configured.
  def rotated_ledger!(before: 3, after: 3)
    before.times { chain.append!(row) }
    configure(new_key, retired: [old_key])
    after.times { chain.append!(row) }
  end

  def at(sequence)
    entries.where(chain_sequence: sequence)
  end

  def epochs_table
    Reeve::Audit::ChainEpoch
  end

  def verify(keys: nil)
    Reeve::Audit::Chain.verify(keys: keys)
  end

  def breaks(result = verify)
    result.breaks.map { |b| [b.kind, b.sequence || b.epoch] }
  end

  describe "a legitimate ledger" do
    it "is intact across a rotation, and lists both epochs as verified" do
      rotated_ledger!

      result = verify

      expect(result.status).to eq(:intact)
      expect(result.covered).to eq(1..6)
      expect(result.epochs.map { |e| [e.epoch, e.first_sequence, e.entry_count, e.status] })
        .to eq([[0, 1, 3, :verified], [1, 4, 3, :verified]])
    end

    it "is intact with stragglers from a process still on the old key" do
      rotated_ledger!(before: 2, after: 1)
      configure(old_key)
      chain.append!(row)
      configure(new_key, retired: [old_key])
      chain.append!(row)

      result = verify

      expect(result.status).to eq(:intact)
      expect(result.epochs.map(&:entry_count)).to eq([3, 2])
    end

    it "is intact after many rotations" do
      keys = Array.new(4) { |i| "reeve-spec-rotation-key-#{i}-0123456789abcdef" }
      keys.each_with_index do |key, i|
        configure(key, retired: [old_key, *keys.first(i)])
        2.times { chain.append!(row) }
      end

      result = verify

      expect(result.status).to eq(:intact)
      expect(result.epochs.map(&:epoch)).to eq([0, 1, 2, 3])
    end

    # US4 scenario 2: an auditor with only the newest key.
    it "is unverifiable, naming the epoch, for a verifier without an earlier epoch's key" do
      rotated_ledger!

      result = verify(keys: [new_key])

      expect(result.status).to eq(:unverifiable)
      expect(result.breaks.map(&:kind).uniq).to eq([:unknown_key])
      expect(result.epochs.map(&:status)).to eq(%i[key_not_configured verified])
    end

    it "is unverifiable, not intact, when an epoch record's key is missing and it signed nothing" do
      chain.append!(row)
      configure(new_key, retired: [old_key])
      Reeve::Audit::Chain.rotate_key!

      result = verify(keys: [old_key])

      expect(result.status).to eq(:unverifiable)
      expect(result.epochs.last.status).to eq(:key_not_configured)
    end

    # US4 scenario 3: a 0.6.0 server still writing contract-3 rows after epoch 0 opened.
    it "verifies contract-3 rows chained after epoch 0 opened" do
      chain.append!(row)
      chain.append!(row(contract_version: 3))
      chain.append!(row)

      expect(verify.status).to eq(:intact)
    end

    it "counts rows chained before the first epoch separately and checks them as 0.6.0 did" do
      2.times { chain.append!(row(contract_version: 3)) }
      chain.append!(row)

      result = verify

      expect(result.status).to eq(:intact)
      expect(result.before_first_epoch).to eq(2)
      expect(result.epochs.map(&:first_sequence)).to eq([3])
    end

    it "leaves a pre-epoch row with an unknown key unverifiable, as 0.6.0 did" do
      chain.append!(row(contract_version: 3))
      chain.append!(row)
      at(1).update_all(chain_key_id: stranger)

      expect(verify.status).to eq(:unverifiable)
    end
  end

  describe "tampering (US2)" do
    before { rotated_ledger! }

    it "starts intact, or every example below proves nothing" do
      expect(verify.status).to eq(:intact)
    end

    # The 0.6.0 gap (specs/002 verification.md): this read as UNVERIFIABLE.
    it "reports a key id rewritten to an unknown fingerprint as tampering" do
      at(5).update_all(chain_key_id: stranger)

      expect(verify.status).to eq(:broken)
      expect(breaks).to eq([[:epoch_mismatch, 5]])
    end

    it "reports a key id rewritten to another epoch's key as tampering" do
      at(5).update_all(chain_key_id: Reeve::LedgerKey.fingerprint(old_key))

      expect(verify.status).to eq(:broken)
      expect(breaks).to eq([[:epoch_mismatch, 5]])
    end

    it "reports it even when the verifier lacks the other epoch's key" do
      at(5).update_all(chain_key_id: Reeve::LedgerKey.fingerprint(old_key))

      expect(verify(keys: [new_key]).status).to eq(:broken)
    end

    it "reports a row moved to an epoch with no record" do
      at(5).update_all(chain_epoch: 7)

      expect(breaks).to eq([[:epoch_missing, 5]])
    end

    it "reports a chained contract-4 row with no epoch" do
      at(5).update_all(chain_epoch: nil)

      expect(breaks).to eq([[:epoch_missing, 5]])
    end

    it "reports a row that names a later epoch than its position allows" do
      at(2).update_all(chain_epoch: 1, chain_key_id: Reeve::LedgerKey.fingerprint(new_key))

      expect(breaks).to eq([[:epoch_mismatch, 2]])
    end

    it "reports a row whose epoch number alone was changed to another real epoch" do
      at(5).update_all(chain_epoch: 0)

      expect(verify.status).to eq(:broken)
      expect(breaks).to eq([[:epoch_mismatch, 5]])
    end

    it "reports a deleted epoch record from the entries that point at it" do
      epochs_table.where(epoch: 1).delete_all

      result = verify

      expect(result.status).to eq(:broken)
      expect(breaks(result)).to eq([[:epoch_missing, 4], [:epoch_missing, 5], [:epoch_missing, 6]])
    end

    it "reports every epoch record deleted" do
      epochs_table.delete_all

      expect(verify.status).to eq(:broken)
      expect(breaks.map(&:first).uniq).to eq([:epoch_missing])
    end

    it "reports an epoch record whose start was moved" do
      epochs_table.where(epoch: 1).update_all(first_sequence: 3)

      expect(verify.status).to eq(:broken)
      expect(breaks).to include([:epoch_altered, 1])
    end

    it "reports an epoch record whose key id was swapped" do
      epochs_table.where(epoch: 1).update_all(key_id: stranger)

      expect(verify.status).to eq(:broken)
      expect(breaks.map(&:first)).to include(:epoch_mismatch)
    end

    it "reports a gap in the epoch numbering" do
      epochs_table.where(epoch: 1).update_all(epoch: 2)

      expect(verify.status).to eq(:broken)
      expect(breaks).to include([:epoch_missing, 1])
    end

    it "reports a forged epoch record" do
      epochs_table.insert_all!([{ epoch: 2, key_id: stranger, first_sequence: 7,
                                  opened_at: Time.now.utc, epoch_digest: "0" * 64 }])

      result = verify

      expect(result.status).not_to eq(:intact)
      expect(result.epochs.last.status).to eq(:key_not_configured)
    end

    # A second epoch for a key the verifier holds: the unique key_id index refuses it outright.
    it "cannot be given a second epoch for a key that already opened one" do
      forged = { epoch: 2, key_id: Reeve::LedgerKey.fingerprint(old_key), first_sequence: 7,
                 opened_at: Time.now.utc, epoch_digest: "0" * 64 }

      expect { epochs_table.insert_all!([forged]) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "reports a forged epoch record that reuses a held key once the unique index is dropped" do
      ActiveRecord::Base.connection.remove_index(:reeve_audit_chain_epochs, :key_id)
      epochs_table.insert_all!([{ epoch: 2, key_id: Reeve::LedgerKey.fingerprint(old_key), first_sequence: 7,
                                  opened_at: Time.now.utc, epoch_digest: "0" * 64 }])

      expect(verify.status).to eq(:broken)
      expect(breaks).to include([:epoch_altered, 2])
    ensure
      ActiveRecord::Base.connection.drop_table(:reeve_audit_chain_epochs)
      Ledger.prepare!
    end

    it "reports an epoch record whose digest was rewritten" do
      epochs_table.where(epoch: 0).update_all(epoch_digest: "0" * 64)

      expect(breaks).to include([:epoch_altered, 0])
    end
  end

  describe "the report (FR-013)" do
    it "prints nothing new for a ledger with a single verified epoch" do
      2.times { chain.append!(row) }

      text = verify.to_s

      expect(text.lines.size).to eq(1)
      expect(text).not_to include("epoch")
    end

    it "lists one line per epoch once there are two" do
      rotated_ledger!

      lines = verify.to_s.lines.map(&:strip)

      expect(lines.grep(/\Aepoch 0/).first).to match(/key #{Reeve::LedgerKey.fingerprint(old_key)}.*from sequence 1.*3 entries.*verified/)
      expect(lines.grep(/\Aepoch 1/).first).to match(/key #{Reeve::LedgerKey.fingerprint(new_key)}.*from sequence 4.*3 entries.*verified/)
    end

    it "lists the epochs, and the rows before them, on an upgraded ledger" do
      2.times { chain.append!(row(contract_version: 3)) }
      chain.append!(row)

      expect(verify.to_s).to match(/before epoch 0.*2 entries/)
    end

    it "says which epoch's key is missing" do
      rotated_ledger!

      expect(verify(keys: [new_key]).to_s).to match(/epoch 0 .*key not configured/)
    end

    it "adds epochs and before_first_epoch to the JSON, keeping every existing key" do
      rotated_ledger!

      json = JSON.parse(JSON.generate(verify.as_json))

      expect(json["epochs"].first).to eq(
        "epoch" => 0, "key_id" => Reeve::LedgerKey.fingerprint(old_key), "first_sequence" => 1,
        "entries" => 3, "status" => "verified"
      )
      expect(json["before_first_epoch"]).to eq(0)
      expect(json.keys).to include("status", "covered", "breaks", "totals", "unverifiable_count")
    end
  end
end
