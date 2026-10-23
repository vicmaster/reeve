# frozen_string_literal: true

require "securerandom"
require_relative "../support/ledger"

# specs/003, findings of the verification phase — each example failed before its fix.
RSpec.describe "key epochs: verification findings" do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:key_a) { Ledger::TEST_KEY }
  let(:key_b) { "reeve-spec-second-ledger-key-0123456789abcdef" }
  let(:key_c) { "reeve-spec-third-ledger-key-0123456789abcdefgh" }

  before { Ledger.prepare! }

  def row(**overrides)
    { invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
      arguments: {}, outcome: "allow", rule: "r", record_ids: [], guard: "policy",
      contract_version: Reeve::Audit::CONTRACT_VERSION }.merge(overrides)
  end

  def configure(key, retired: [])
    Reeve.config.retired_ledger_keys = []
    Reeve.config.ledger_key = key
    Reeve.config.retired_ledger_keys = retired
  end

  # Review finding A: "strictly increasing" starts made this a permanent false BROKEN.
  it "is intact after two rotations with no write between them" do
    chain.append!(row)
    configure(key_b, retired: [key_a])
    Reeve::Audit::Chain.rotate_key!
    configure(key_c, retired: [key_a, key_b])
    Reeve::Audit::Chain.rotate_key!
    chain.append!(row)

    expect(Reeve::Audit::Chain.verify.status).to eq(:intact)
  end

  it "is intact when a rotation is followed by a first write with yet another key" do
    chain.append!(row)
    configure(key_b, retired: [key_a])
    Reeve::Audit::Chain.rotate_key!
    configure(key_c, retired: [key_a, key_b])
    chain.append!(row)

    expect(Reeve::Audit::Chain.verify.status).to eq(:intact)
  end

  # Both verifiers: a 0.6.0 server's row after epoch 0, signed by a key that never opened an
  # epoch, checked by an auditor without that key, read BROKEN.
  it "leaves a contract-3 straggler whose key the verifier lacks unverifiable, not broken" do
    configure(key_b)
    chain.append!(row)
    configure(key_a)
    chain.append!(row(contract_version: 3))

    expect(Reeve::Audit::Chain.verify(keys: [key_b]).status).to eq(:unverifiable)
  end

  # Review finding C: an upgraded gem on an un-migrated table raised from the verifier.
  it "verifies a ledger without the epochs table as 0.6.0 did" do
    chain.append!(row(contract_version: 3))
    ActiveRecord::Base.connection.drop_table(:reeve_audit_chain_epochs)

    expect(Reeve::Audit::Chain.verify.status).to eq(:intact)
  ensure
    Ledger.prepare!
  end

  # Review finding R4: epochs were read through ActiveRecord::Base, whatever the ledger used.
  it "refuses to verify when ChainEpoch is on a different database than the ledger" do
    chain.append!(row)
    other = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "audit",
                                                                 { adapter: "sqlite3", database: "elsewhere" })
    allow(Reeve::Audit::ChainEpoch).to receive(:connection_db_config).and_return(other)

    expect { Reeve::Audit::Chain.verify }.to raise_error(Reeve::ConfigurationError, /ChainEpoch/)
  end

  # Review finding R8: Recorder builds a Chain per write, so a per-instance memo asked the
  # catalog on every write.
  it "asks the schema nothing on a steady-state write" do
    chain.append!(row)
    schema = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      schema << payload[:sql] if payload[:name] == "SCHEMA"
    end
    Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry).append!(row)

    expect(schema).to eq([])
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "does not keep a chain_epoch a caller put on a contract-3 row" do
    chain.append!(row(contract_version: 3, chain_epoch: 9))

    expect(Reeve::Audit::Entry.last.chain_epoch).to be_nil
  end

  # Test-adequacy findings M20, X2, X5, X7: the digest spec computed its expectation with the
  # function under test. This one writes out the canonical text by hand.
  it "digests an epoch record over its tag, every field, and the previous digest" do
    chain.append!(row)
    epoch = Reeve::Audit::ChainEpoch.find_by(epoch: 0)
    genesis = Reeve::Audit::ChainRecord.ledger.genesis_digest
    micros = (epoch.opened_at.to_r * 1_000_000).floor
    text = "reeve-ledger-epoch-v1\n" \
           "[[\"previous_digest\",\"#{genesis}\"],[\"epoch\",0],[\"key_id\",\"#{epoch.key_id}\"]," \
           "[\"first_sequence\",1],[\"opened_at\",#{micros}]]"

    expect(epoch.epoch_digest).to eq(OpenSSL::HMAC.hexdigest("SHA256", key_a, text))
  end

  # M7, M8, X1: the structural rules on epoch records, checked where no digest can mask them
  # — by a verifier that does not hold the record's key.
  describe "epoch records a verifier cannot check by digest" do
    before do
      chain.append!(row)
      configure(key_b, retired: [key_a])
      2.times { chain.append!(row) }
    end

    def breaks(result)
      result.breaks.map { |b| [b.kind, b.epoch] }
    end

    it "reports one that begins past the head" do
      Reeve::Audit::ChainEpoch.insert_all!([{ epoch: 2, key_id: "0123456789abcdef", first_sequence: 99,
                                              opened_at: Time.now.utc, epoch_digest: "0" * 64 }])

      expect(breaks(Reeve::Audit::Chain.verify)).to include([:epoch_altered, 2])
    end

    it "reports one that begins before the epoch before it" do
      Reeve::Audit::ChainEpoch.where(epoch: 1).update_all(first_sequence: 0)

      expect(breaks(Reeve::Audit::Chain.verify(keys: [key_a]))).to include([:epoch_altered, 1])
    end

    it "reports one that reuses an earlier epoch's key" do
      ActiveRecord::Base.connection.remove_index(:reeve_audit_chain_epochs, :key_id)
      Reeve::Audit::ChainEpoch.insert_all!([{ epoch: 2, key_id: Reeve::LedgerKey.fingerprint(key_a),
                                              first_sequence: 4, opened_at: Time.now.utc,
                                              epoch_digest: "0" * 64 }])

      expect(breaks(Reeve::Audit::Chain.verify(keys: [key_b]))).to include([:epoch_altered, 2])
    ensure
      ActiveRecord::Base.connection.drop_table(:reeve_audit_chain_epochs)
      Ledger.prepare!
    end
  end

  it "still names the missing contract when a row has none" do
    expect { chain.append!(row(contract_version: nil)) }.to raise_error(ArgumentError, /contract/)
  end
end
