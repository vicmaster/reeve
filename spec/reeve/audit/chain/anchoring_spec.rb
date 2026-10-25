# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "../support/ledger"

# specs/004 US1–US3, FR-010–FR-013, SC-001, SC-002: verification against checkpoints.
#
# Every case that a checkpoint catches is pinned beside its twin without one, which still
# verifies as 0.7.0 did. The old limit stays visible next to the new guarantee, and a spec
# that passed because the case was never tampering at all would show up as two passes.
RSpec.describe "verifying the ledger against checkpoints" do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:new_key) { "reeve-spec-second-ledger-key-0123456789abcdef" }
  let(:third_key) { "reeve-spec-third-ledger-key-0123456789abcdefgh" }

  before { Ledger.prepare! }

  def row
    { invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
      arguments: { "n" => SecureRandom.hex(4) }, outcome: "allow", rule: "r", record_ids: [],
      guard: "policy", contract_version: Reeve::Audit::CONTRACT_VERSION }
  end

  def write(count)
    count.times { chain.append!(row) }
  end

  def checkpoint
    Reeve::Audit::Chain.checkpoint!(anchor: nil).checkpoint
  end

  def verify(checkpoints = [])
    Reeve::Audit::Chain.verify(checkpoints: checkpoints)
  end

  def kinds(verification)
    verification.breaks.map(&:kind)
  end

  def statuses(verification)
    verification.checkpoints.to_h { |result| [result.head_sequence, result.status] }
  end

  def configure(key, retired: [])
    Reeve.config.retired_ledger_keys = []
    Reeve.config.ledger_key = key
    Reeve.config.retired_ledger_keys = retired
  end

  describe "an untampered ledger (SC-002)" do
    it "is intact with any number of checkpoints, anchored at the highest" do
      write(3)
      first = checkpoint
      write(4)
      second = checkpoint
      write(2)

      result = verify([second, first])

      expect(result.status).to eq(:intact)
      expect(statuses(result)).to eq(3 => :checked, 7 => :checked)
      expect(result.anchored_at.head_sequence).to eq(7)
      expect(result.beyond_anchor).to eq(2)
    end

    it "is intact across rotations, with stragglers, and with checkpoints made by either key" do
      write(2)
      before = checkpoint
      configure(new_key, retired: [Ledger::TEST_KEY])
      Reeve::Audit::Chain.rotate_key!
      write(2)
      after = checkpoint
      configure(Ledger::TEST_KEY, retired: [new_key]) # a server still on the old key
      write(1)
      straggler = checkpoint

      result = verify([before, after, straggler])

      expect(result.status).to eq(:intact)
      expect(statuses(result).values).to all(eq(:checked))
      expect(straggler.key_id).to eq(Reeve::LedgerKey.fingerprint(Ledger::TEST_KEY))
    end

    it "reads checkpoints given as lines" do
      write(2)

      expect(verify([checkpoint.to_line]).status).to eq(:intact)
    end

    it "refuses a line that is not a checkpoint, naming its position" do
      write(2)

      expect { verify([checkpoint.to_line, "garbage"]) }
        .to raise_error(Reeve::CheckpointError, /\Acheckpoint 2 cannot be read/)
    end

    it "uses the configured anchor's checkpoints when none are given" do
      write(2)
      anchor = Ledger::RecordingAnchor.new
      Reeve.config.ledger_anchor = anchor
      Reeve::Audit::Chain.checkpoint!
      Ledger.truncate_tail!(after: 1)

      expect(Reeve::Audit::Chain.verify.status).to eq(:broken)
      expect(Reeve::Audit::Chain.verify(checkpoints: []).status).to eq(:intact)
    end
  end

  # US1: a truncated tail with a rewound head.
  describe "a truncated tail" do
    before do
      write(500)
      @at500 = checkpoint
      write(300)
    end

    it "verifies intact without the checkpoint: the 0.7.0 limit, pinned" do
      Ledger.truncate_tail!(after: 400)

      expect(verify.status).to eq(:intact)
    end

    it "is broken with it, naming the checkpoint the ledger no longer reaches" do
      Ledger.truncate_tail!(after: 400)

      result = verify([@at500])

      expect(result.status).to eq(:broken)
      expect(kinds(result)).to eq([:checkpoint_not_reached])
      expect(result.breaks.first.checkpoint).to eq(500)
      expect(statuses(result)).to eq(500 => :not_reached)
    end

    # Guarantee item 1: what comes after the latest checkpoint is not covered.
    it "is intact when only entries after the checkpoint were removed, anchored with none after it" do
      Ledger.truncate_tail!(after: 500)

      result = verify([@at500])

      expect(result.status).to eq(:intact)
      expect(result.anchored_at.head_sequence).to eq(500)
      expect(result.beyond_anchor).to eq(0)
    end

    # Without the key, an edit leaves the recorded digest alone: the chain catches it, and the
    # checkpoint still matches the digest it saw.
    it "leaves an edit without the key to the chain's digest check" do
      ActiveRecord::Base.connection.update(
        "UPDATE reeve_audit_entries SET tool_name = 'edited' WHERE chain_sequence = 500"
      )

      result = verify([@at500])

      expect(kinds(result)).to eq([:digest_mismatch])
      expect(statuses(result)).to eq(500 => :checked)
    end

    # Guarantee item 3: a key holder can re-sign an entry, but not the checkpoint made before.
    it "is broken against the checkpoint when its entry was re-signed with the key" do
      entry = Reeve::Audit::Entry.find_by(chain_sequence: 500)
      previous = Reeve::Audit::Entry.find_by(chain_sequence: 499).chain_digest
      ActiveRecord::Base.connection.update(
        "UPDATE reeve_audit_entries SET tool_name = 'edited' WHERE chain_sequence = 500"
      )
      entry.reload
      digest = Reeve::Audit::Chain::Canonical.entry_digest(Ledger::TEST_KEY, entry, previous_digest: previous)
      ActiveRecord::Base.connection.update(
        "UPDATE reeve_audit_entries SET chain_digest = '#{digest}' WHERE chain_sequence = 500"
      )

      result = verify([@at500])

      expect(verify.breaks.map(&:sequence)).to eq([501])
      expect(kinds(result)).to contain_exactly(:digest_mismatch, :checkpoint_mismatch)
    end

    it "names only the checkpoints the ledger no longer reaches" do
      write(100)
      at900 = checkpoint
      Ledger.truncate_tail!(after: 700)

      result = verify([@at500, at900])

      expect(kinds(result)).to eq([:checkpoint_not_reached])
      expect(statuses(result)).to eq(500 => :checked, 900 => :not_reached)
      expect(result.anchored_at.head_sequence).to eq(500)
    end

    # The tail was cut and new entries written past the checkpoint: the entry at its sequence is
    # a different one now.
    it "is broken when the ledger was truncated and then grew past the checkpoint" do
      Ledger.truncate_tail!(after: 400)
      write(200)

      result = verify([@at500])

      expect(verify.status).to eq(:intact)
      expect(kinds(result)).to eq([:checkpoint_mismatch])
    end

    # spec amendment 2: checkpoints are checked on their own, never against each other.
    it "flags only the wrong one of two checkpoints at one sequence" do
      forged = JSON.parse(@at500.to_line).merge("head_digest" => "0" * 64)
      signature = Reeve::Audit::Chain::Canonical.checkpoint_signature(Ledger::TEST_KEY, forged)
      wrong = Reeve::Audit::Chain::Checkpoint.parse(JSON.generate(forged.merge("signature" => signature)),
                                                    position: 1)

      result = verify([@at500, wrong])

      expect(kinds(result)).to eq([:checkpoint_mismatch])
      expect(result.checkpoints.map(&:status)).to eq(%i[checked mismatch])
    end

    it "is broken when a checkpoint was edited" do
      edited = JSON.parse(@at500.to_line).merge("head_sequence" => 400)

      result = verify([JSON.generate(edited)])

      expect(kinds(result)).to eq([:checkpoint_altered])
      expect(statuses(result)).to eq(400 => :altered)
    end

    # A checkpoint whose key this verifier lacks cannot be checked, and is not used for anything.
    it "is unverifiable, never intact, with a checkpoint signed by a key not configured" do
      configure(new_key, retired: [Ledger::TEST_KEY])
      Reeve::Audit::Chain.rotate_key!
      write(1)
      unknown = checkpoint

      result = Reeve::Audit::Chain.verify(keys: [Ledger::TEST_KEY, new_key], checkpoints: [unknown])
      expect(result.status).to eq(:intact)

      result = Reeve::Audit::Chain.verify(keys: [Ledger::TEST_KEY], checkpoints: [unknown])
      checkpoint_break = result.breaks.find(&:checkpoint)
      expect(result.status).to eq(:unverifiable)
      expect([checkpoint_break.kind, checkpoint_break.key_id]).to eq([:unknown_key, Reeve::LedgerKey.fingerprint(new_key)])
      expect(result.checkpoints.map(&:status)).to eq([:key_not_configured])
      expect(result.anchored_at).to be_nil
    end
  end

  # US2: the whole ledger deleted, or replaced.
  describe "a deleted ledger" do
    before { write(5) }

    it "has no chain without a checkpoint: the 0.7.0 limit, pinned" do
      Ledger.empty!

      expect(verify.status).to eq(:no_chain)
    end

    it "is broken with a checkpoint, not 'no chain'" do
      at5 = checkpoint
      Ledger.empty!

      result = verify([at5])

      expect(result.status).to eq(:broken)
      expect(kinds(result)).to eq([:checkpoint_not_reached])
      expect(result.breaks.first.detail).to include("the ledger has no chain")
    end

    it "is broken when a new chain replaced it: the genesis is not the one the checkpoint names" do
      at5 = checkpoint
      Ledger.empty!
      write(7)

      result = verify([at5])

      expect(verify.status).to eq(:intact)
      expect(kinds(result)).to eq([:checkpoint_mismatch])
      expect(result.breaks.first.detail).to include("genesis")
    end

    it "is broken with both the missing record and the checkpoint when only the chain record is gone" do
      at5 = checkpoint
      ActiveRecord::Base.connection.delete("DELETE FROM reeve_audit_chains")

      result = verify([at5])

      expect(kinds(result)).to include(:chain_record_missing, :checkpoint_mismatch)
    end

    it "is broken when a chain was started but its first write never landed" do
      at5 = checkpoint
      Ledger.empty!
      Reeve::Audit::Chain::Head.new(connection: ActiveRecord::Base.connection, entry_class: Reeve::Audit::Entry)
                               .start!(Reeve::Audit::Chain::Keyring.from(Reeve.config))

      expect(verify.status).to eq(:no_chain)
      expect(verify([at5]).status).to eq(:broken)
    end
  end

  # US5: verifying from a checkpoint instead of the genesis.
  describe "from a checkpoint" do
    def verify_from(checkpoints, from: :latest)
      Reeve::Audit::Chain.verify(checkpoints: checkpoints, from: from)
    end

    before do
      write(10)
      @at10 = checkpoint
      write(4)
    end

    it "walks only what came after it, and says what it did not walk" do
      result = verify_from([@at10])

      expect(result.status).to eq(:intact)
      expect(result.covered).to eq(11..14)
      expect(result.walked_from.head_sequence).to eq(10)
      expect(result.to_s).to start_with("reeve ledger: INTACT — sequences 11–14 verified from checkpoint #10 (")
      expect(result.to_s.lines.first).to include("10 earlier chained entries not walked by this run")
    end

    it "picks the highest checkpoint for :latest" do
      write(2)
      later = checkpoint
      write(1)

      expect(verify_from([later, @at10]).covered).to eq(17..17)
    end

    it "is broken, walking nothing, when its own entry's digest changed" do
      ActiveRecord::Base.connection.update(
        "UPDATE reeve_audit_entries SET chain_digest = '#{'0' * 64}' WHERE chain_sequence = 10"
      )

      result = verify_from([@at10])

      expect(result.status).to eq(:broken)
      expect(kinds(result)).not_to include(:digest_mismatch)
      expect(kinds(result)).to include(:checkpoint_mismatch)
    end

    it "is broken at the first entry after it when that entry no longer links to it" do
      ActiveRecord::Base.connection.update(
        "UPDATE reeve_audit_entries SET tool_name = 'edited' WHERE chain_sequence = 11"
      )

      result = verify_from([@at10])

      expect(result.breaks.map { |found| [found.kind, found.sequence] }).to eq([[:digest_mismatch, 11]])
    end

    it "checks its starting point first, and walks nothing from one that does not hold" do
      Ledger.truncate_tail!(after: 5)

      result = verify_from([@at10])

      expect(result.status).to eq(:broken)
      expect(kinds(result)).to eq([:checkpoint_not_reached])
      expect(result.covered).to be_nil
      expect(result.walked_from).to be_nil
    end

    it "walks nothing from a checkpoint at the head, and is intact" do
      at14 = checkpoint

      result = verify_from([at14])

      expect(result.status).to eq(:intact)
      expect(result.covered).to be_nil
      expect(result.to_s).to start_with("reeve ledger: INTACT — no entries after checkpoint #14 (")
    end

    it "needs a checkpoint to start from" do
      expect { verify_from([]) }.to raise_error(Reeve::CheckpointError, /FROM=latest needs a checkpoint/)
    end
  end

  # US3: epoch records pinned.
  describe "epoch records" do
    before do
      write(3)
      configure(new_key, retired: [Ledger::TEST_KEY])
      Reeve::Audit::Chain.rotate_key!
      write(2)
      configure(third_key, retired: [Ledger::TEST_KEY, new_key])
      Reeve::Audit::Chain.rotate_key!
      @after_rotation = checkpoint # names epoch 2, which no entry names yet
    end

    it "loses a fresh epoch without trace when no checkpoint names it: the specs/003 limit, pinned" do
      Ledger.delete_epoch!(2)

      expect(verify.status).to eq(:intact)
    end

    it "is broken when the epoch a checkpoint names is deleted" do
      Ledger.delete_epoch!(2)

      result = verify([@after_rotation])

      expect(kinds(result)).to eq([:checkpoint_mismatch])
      expect(result.breaks.first.detail).to include("epoch 2")
    end

    it "is broken, also against the checkpoint, when an earlier epoch record is edited" do
      ActiveRecord::Base.connection.update("UPDATE reeve_audit_chain_epochs SET first_sequence = 2 WHERE epoch = 1")

      result = verify([@after_rotation])

      expect(result.status).to eq(:broken)
      expect(kinds(result)).to include(:epoch_altered)
    end

    it "keeps a checkpoint made before any epoch existed checked after epochs open" do
      Ledger.prepare!
      Reeve.config.retired_ledger_keys = []
      Reeve.config.ledger_key = Ledger::TEST_KEY
      legacy = row.merge(contract_version: 3)
      2.times { chain.append!(legacy.merge(invocation_id: SecureRandom.uuid)) }
      early = checkpoint
      write(2)

      expect(early.epoch).to be_nil
      expect(statuses(verify([early]))).to eq(2 => :checked)
    end
  end
end
