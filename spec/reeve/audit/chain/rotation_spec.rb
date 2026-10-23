# frozen_string_literal: true

require "rake"
require "securerandom"
require "stringio"
require "reeve/tasks"
require_relative "../support/ledger"

# specs/003 FR-006–FR-009, US1 and US3: `bin/rails reeve:rotate_ledger_key`, and
# Reeve::Audit::Chain.rotate_key! behind it.
RSpec.describe "rotating the ledger key" do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:old_key) { Ledger::TEST_KEY }
  let(:new_key) { "reeve-spec-second-ledger-key-0123456789abcdef" }
  let(:out) { StringIO.new }

  before { Ledger.prepare! }

  def row
    { invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
      arguments: {}, outcome: "allow", rule: "r", record_ids: [], guard: "policy",
      contract_version: Reeve::Audit::CONTRACT_VERSION }
  end

  def configure(key, retired: [])
    Reeve.config.retired_ledger_keys = []
    Reeve.config.ledger_key = key
    Reeve.config.retired_ledger_keys = retired
  end

  def fingerprint(key)
    Reeve::LedgerKey.fingerprint(key)
  end

  def rotate(**options)
    Reeve::Audit::Chain.rotate_key!(**options)
  end

  def epochs
    Reeve::Audit::ChainEpoch.order(:epoch).pluck(:epoch, :key_id, :first_sequence)
  end

  def head_sequence
    Reeve::Audit::ChainRecord.ledger.head_sequence
  end

  describe "Reeve::Audit::Chain.rotate_key!" do
    it "opens the next epoch with the configured key, from one past the head" do
      3.times { chain.append!(row) }
      configure(new_key, retired: [old_key])

      rotation = rotate

      expect(rotation.status).to eq(:rotated)
      expect([rotation.epoch, rotation.key_id, rotation.first_sequence]).to eq([1, fingerprint(new_key), 4])
      expect([rotation.previous_epoch, rotation.previous_key_id]).to eq([0, fingerprint(old_key)])
      expect(epochs).to eq([[0, fingerprint(old_key), 1], [1, fingerprint(new_key), 4]])
    end

    # FR-008: the lock is taken without consuming a sequence.
    it "leaves the head where it was, so the next write continues without a gap" do
      3.times { chain.append!(row) }
      configure(new_key, retired: [old_key])
      rotate
      expect(head_sequence).to eq(3)

      chain.append!(row)

      entry = Reeve::Audit::Entry.find_by(chain_sequence: 4)
      expect([entry.chain_epoch, entry.chain_key_id]).to eq([1, fingerprint(new_key)])
      expect(Reeve::Audit::Chain.verify.status).to eq(:intact)
    end

    it "starts the chain and opens epoch 0 on a ledger with no chain yet" do
      rotation = rotate

      expect(rotation.status).to eq(:rotated)
      expect(epochs).to eq([[0, fingerprint(old_key), 1]])
      expect(head_sequence).to eq(0)

      chain.append!(row)
      expect(epochs.size).to eq(1)
      expect(Reeve::Audit::Chain.verify.status).to eq(:intact)
    end

    it "opens epoch 0 after the rows of a ledger chained before key epochs" do
      2.times { chain.append!(row.merge(contract_version: 3)) }

      expect(rotate.first_sequence).to eq(3)
      chain.append!(row)
      expect(Reeve::Audit::Chain.verify.before_first_epoch).to eq(2)
    end

    it "is CURRENT, and writes nothing, when run twice" do
      chain.append!(row)
      configure(new_key, retired: [old_key])
      rotate

      rotation = rotate

      expect(rotation.status).to eq(:current)
      expect(rotation.epoch).to eq(1)
      expect(epochs.size).to eq(2)
    end

    it "is CURRENT when a write already opened the epoch" do
      chain.append!(row)
      configure(new_key, retired: [old_key])
      chain.append!(row)

      expect(rotate.status).to eq(:current)
    end

    it "warns, but does not refuse, when CURRENT and the previous epoch's key is not configured" do
      chain.append!(row)
      configure(new_key)
      chain.append!(row)

      rotation = rotate

      expect(rotation.status).to eq(:current)
      expect(rotation.warnings.join).to include("epoch 0", fingerprint(old_key), "unverifiable")
    end

    it "refuses when the outgoing epoch's key is not configured, writing nothing" do
      chain.append!(row)
      configure(new_key)

      rotation = rotate

      expect([rotation.status, rotation.reason]).to eq(%i[refused outgoing_key_missing])
      expect(epochs.size).to eq(1)
    end

    it "opens the epoch anyway when told the outgoing key is lost" do
      chain.append!(row)
      configure(new_key)

      rotation = rotate(accept_unverifiable: true)

      expect(rotation.status).to eq(:rotated)
      expect(rotation.warnings.join).to include("epoch 0", "unverifiable")
    end

    it "refuses a key that already opened an earlier epoch" do
      chain.append!(row)
      configure(new_key, retired: [old_key])
      rotate
      configure(old_key, retired: [new_key])

      rotation = rotate

      expect([rotation.status, rotation.reason, rotation.epoch]).to eq([:refused, :key_reused, 0])
      expect(epochs.size).to eq(2)
    end

    it "refuses without a ledger key" do
      Reeve.config.ledger_key = nil

      rotation = rotate

      expect([rotation.status, rotation.reason]).to eq(%i[refused no_key])
      expect(Reeve::Audit::ChainRecord.count).to eq(0)
    end
  end

  describe "Reeve::Tasks.rotate_ledger_key" do
    def run(env = {})
      Reeve::Tasks.rotate_ledger_key(env: env, out: out)
    end

    it "exits 0 and says ROTATED, naming the epoch, its key and where it begins" do
      2.times { chain.append!(row) }
      configure(new_key, retired: [old_key])

      expect(run).to eq(0)
      expect(out.string.lines.first).to start_with("reeve ledger key: ROTATED — epoch 1 opened with key " \
                                                   "#{fingerprint(new_key)} from sequence 3")
      expect(out.string).to include("epoch 0 (key #{fingerprint(old_key)})")
    end

    it "exits 0 and says CURRENT when there is nothing to do" do
      chain.append!(row)

      expect(run).to eq(0)
      expect(out.string).to start_with("reeve ledger key: CURRENT — epoch 0 already signs with the configured key")
    end

    it "exits 1 and says REFUSED, with the fix, when the outgoing key is missing" do
      chain.append!(row)
      configure(new_key)

      expect(run).to eq(1)
      expect(out.string).to start_with("reeve ledger key: REFUSED")
      expect(out.string).to include("retired_ledger_keys", "ACCEPT_UNVERIFIABLE=1", "nothing was written")
    end

    it "accepts ACCEPT_UNVERIFIABLE=1, prints warnings on their own lines" do
      chain.append!(row)
      configure(new_key)

      expect(run("ACCEPT_UNVERIFIABLE" => "1")).to eq(0)
      expect(out.string.lines.grep(/\Awarning: /).size).to eq(1)
    end

    it "refuses an ACCEPT_UNVERIFIABLE value it does not know" do
      expect { run("ACCEPT_UNVERIFIABLE" => "yes") }.to raise_error(ArgumentError, /ACCEPT_UNVERIFIABLE/)
    end

    # FR-007.
    it "never prints a key, only fingerprints" do
      chain.append!(row)
      configure(new_key)
      run
      run("ACCEPT_UNVERIFIABLE" => "1")
      run

      expect(out.string).not_to include(old_key)
      expect(out.string).not_to include(new_key)
    end

    it "is defined as a Rake task that exits with the rotation's status" do
      rake = Rake::Application.new
      Rake.application = rake
      rake.define_task(Rake::Task, :environment)
      Reeve::Tasks.define
      chain.append!(row)

      task = rake["reeve:rotate_ledger_key"]
      expect(task.prerequisites).to eq(["environment"])
      expect { task.invoke }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(0) }
        .and output(/CURRENT/).to_stdout
    ensure
      Rake.application = Rake::Application.new
    end
  end
end
