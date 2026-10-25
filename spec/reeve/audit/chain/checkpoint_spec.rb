# frozen_string_literal: true

require "json"
require "openssl"
require "securerandom"
require "tmpdir"
require_relative "../support/ledger"

# specs/004 FR-001–FR-005, FR-009, contracts/checkpoint-v1.md: what a checkpoint is, and
# Reeve::Audit::Chain.checkpoint!, which makes one.
RSpec.describe "ledger checkpoints" do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:checkpoint_class) { Reeve::Audit::Chain::Checkpoint }
  let(:new_key) { "reeve-spec-second-ledger-key-0123456789abcdef" }

  let(:fields) do
    %w[epoch epoch_digest format genesis_digest head_digest head_sequence key_id ledger made_at
       pre_chain_count pre_chain_unchained_count reeve_version signature]
  end

  before { Ledger.prepare! }

  def row
    { invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
      arguments: { "query" => "acme-secret-content" }, outcome: "allow", rule: "r",
      record_ids: [], guard: "policy", contract_version: Reeve::Audit::CONTRACT_VERSION }
  end

  def fingerprint(key)
    Reeve::LedgerKey.fingerprint(key)
  end

  def configure(key, retired: [])
    Reeve.config.retired_ledger_keys = []
    Reeve.config.ledger_key = key
    Reeve.config.retired_ledger_keys = retired
  end

  def make(anchor: nil)
    Reeve::Audit::Chain.checkpoint!(anchor: anchor)
  end

  def line_of(checkpoint)
    JSON.parse(checkpoint.to_line)
  end

  describe "the line" do
    before { 3.times { chain.append!(row) } }

    let(:checkpoint) { make.checkpoint }

    it "has exactly the format's fields, keys sorted, on one line" do
      line = checkpoint.to_line

      expect(JSON.parse(line).keys).to eq(fields)
      expect(line).not_to include("\n")
      expect(line).not_to match(/":\s|,\s/)
    end

    it "names the genesis, the head and the latest epoch as the ledger has them" do
      record = Reeve::Audit::ChainRecord.ledger
      epoch = Reeve::Audit::ChainEpoch.order(:epoch).last

      expect(line_of(checkpoint)).to include(
        "format" => "reeve-ledger-checkpoint-v1", "ledger" => "ledger",
        "genesis_digest" => record.genesis_digest, "pre_chain_count" => 0,
        "pre_chain_unchained_count" => 0, "head_sequence" => 3, "head_digest" => record.head_digest,
        "epoch" => 0, "epoch_digest" => epoch.epoch_digest, "key_id" => fingerprint(Ledger::TEST_KEY),
        "reeve_version" => Reeve::VERSION
      )
      expect(line_of(checkpoint)["made_at"]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z\z/)
    end

    # FR-004: it can be stored where the ledger's data must not be.
    it "holds no entry content and no key" do
      line = checkpoint.to_line

      expect(line).not_to include("acme-secret-content")
      expect(line).not_to include(Ledger::TEST_KEY)
    end

    it "is signed as contracts/checkpoint-v1.md says, recomputed by hand" do
      values = line_of(checkpoint)
      pairs = Reeve::Audit::Chain::Canonical::CHECKPOINT_FIELDS.map { |field| [field, values[field]] }
      body = Reeve::Audit::Chain::Canonical.dump(pairs)
      expected = OpenSSL::HMAC.hexdigest("SHA256", Ledger::TEST_KEY, "reeve-ledger-checkpoint-v1\n#{body}")

      expect(values["signature"]).to eq(expected)
    end

    it "parses back to the same checkpoint" do
      parsed = checkpoint_class.parse(checkpoint.to_line, position: 1)

      expect(parsed.to_line).to eq(checkpoint.to_line)
      expect([parsed.head_sequence, parsed.epoch]).to eq([3, 0])
    end

    it "is valid under the key that signed it, and altered once a field changes" do
      keyring = Reeve::Audit::Chain::Keyring.from(Reeve.config)
      edited = line_of(checkpoint).merge("head_sequence" => 2)

      expect(checkpoint.signed_by(keyring)).to eq(:valid)
      expect(checkpoint_class.parse(JSON.generate(edited), position: 1).signed_by(keyring)).to eq(:altered)
    end

    it "cannot be checked without the key that signed it" do
      keyring = Reeve::Audit::Chain::Keyring.new(signing: nil, retired: [new_key])

      expect(checkpoint.signed_by(keyring)).to eq(:key_not_configured)
    end
  end

  describe "parsing" do
    let(:valid) do
      chain.append!(row)
      line_of(make.checkpoint)
    end

    def refused(line)
      expect { checkpoint_class.parse(line, position: 4) }
        .to raise_error(Reeve::CheckpointError, /\Acheckpoint 4 cannot be read: /)
    end

    it "refuses a line that is not JSON, or not an object" do
      refused("not a checkpoint")
      refused("[1,2]")
    end

    it "refuses a missing field and an extra one" do
      refused(JSON.generate(valid.except("head_digest")))
      refused(JSON.generate(valid.merge("note" => "x")))
    end

    it "refuses a wrong type" do
      refused(JSON.generate(valid.merge("head_sequence" => "3")))
      refused(JSON.generate(valid.merge("genesis_digest" => nil)))
    end

    # research R5: a newer format is not tampering, and is not skipped either.
    it "refuses a format it does not know" do
      refused(JSON.generate(valid.merge("format" => "reeve-ledger-checkpoint-v2")))
    end

    it "refuses an epoch without its digest" do
      refused(JSON.generate(valid.merge("epoch_digest" => nil)))
    end
  end

  describe "Reeve::Audit::Chain.checkpoint!" do
    it "names the newest epoch after a rotation, before any entry signs under it" do
      chain.append!(row)
      configure(new_key, retired: [Ledger::TEST_KEY])
      Reeve::Audit::Chain.rotate_key!

      checkpoint = make.checkpoint

      expect([checkpoint.head_sequence, checkpoint.epoch, checkpoint.key_id]).to eq([1, 1, fingerprint(new_key)])
    end

    it "refuses with no key, and with no chain, publishing nothing" do
      anchor = Ledger::RecordingAnchor.new
      expect(make(anchor: anchor).reason).to eq(:no_chain)

      Reeve.config.ledger_key = nil
      expect(make(anchor: anchor).reason).to eq(:no_key)
      expect(anchor.lines).to be_empty
    end

    # A chain started by a write that then rolled back has head 0: nothing to pin.
    it "refuses a chain with nothing in it yet" do
      Reeve::Audit::Chain::Head.new(connection: ActiveRecord::Base.connection, entry_class: Reeve::Audit::Entry)
                               .start!(Reeve::Audit::Chain::Keyring.from(Reeve.config))

      expect(make.reason).to eq(:no_chain)
    end

    it "hands the line to the anchor" do
      chain.append!(row)
      anchor = Ledger::RecordingAnchor.new

      result = make(anchor: anchor)

      expect(result).to be_published
      expect(anchor.lines).to eq([result.checkpoint.to_line])
    end

    it "still returns the checkpoint when the anchor fails, with the error" do
      chain.append!(row)

      result = make(anchor: Ledger::RecordingAnchor.new(error: IOError.new("bucket unreachable")))

      expect(result).to be_made
      expect(result).not_to be_published
      expect(result.error).to eq("bucket unreachable (IOError)")
      expect(result.checkpoint.head_sequence).to eq(1)
    end

    # FR-005: the head and the epoch are read as one committed state. A rotation landing between
    # two unlocked reads could otherwise pair a head with an epoch that opened after it.
    it "reads the head and the latest epoch under the head's lock" do
      chain.append!(row)
      locked = false
      allow_any_instance_of(Reeve::Audit::Chain::Head).to receive(:lock!).and_wrap_original do |original|
        locked = true
        original.call
      end
      allow_any_instance_of(Reeve::Audit::Chain::Epochs).to receive(:latest).and_wrap_original do |original|
        expect(locked).to be(true)
        original.call
      end

      make
    end

    # FR-009: the anchor is published to after the lock is released, so a slow store holds no writer.
    it "publishes outside the transaction that holds the lock" do
      chain.append!(row)
      anchor = Ledger::RecordingAnchor.new
      open_transactions = nil
      allow(anchor).to receive(:publish).and_wrap_original do |original, line|
        open_transactions = ActiveRecord::Base.connection.open_transactions
        original.call(line)
      end

      make(anchor: anchor)

      expect(open_transactions).to eq(0)
    end

    # FR-009: nothing on the write path calls the anchor.
    it "is never called by a write" do
      anchor = Ledger::RecordingAnchor.new
      Reeve.config.ledger_anchor = anchor

      chain.append!(row)
      Reeve::Audit::Recorder.new.record(row.except(:contract_version))

      expect(anchor.lines).to be_empty
    end
  end
end
