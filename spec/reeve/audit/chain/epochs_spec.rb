# frozen_string_literal: true

require "securerandom"
require_relative "../support/ledger"

# specs/003 FR-001–FR-005, US1 scenario 3, US4 scenario 1.
#
# Writes open key epochs: the first chained write opens epoch 0 with the configured key, a
# key that has never signed opens the next one, and a key that already opened one keeps
# writing under it. None of that ever makes a write fail.
RSpec.describe "key epochs on the write path" do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:canonical) { Reeve::Audit::Chain::Canonical }
  let(:new_key) { "reeve-spec-second-ledger-key-0123456789abcdef" }
  let(:old_key) { Ledger::TEST_KEY }

  before { Ledger.prepare! }

  def row(**overrides)
    {
      invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "claude-desktop",
      tool_name: "invoice_search", arguments: { query: "acme" }, outcome: "allow",
      rule: "InvoicePolicy#index?", record_ids: %w[1 2], record_count: 2, guard: "policy",
      contract_version: Reeve::Audit::CONTRACT_VERSION
    }.merge(overrides)
  end

  def entries
    Reeve::Audit::Entry.where.not(chain_sequence: nil).order(:chain_sequence).to_a
  end

  def epochs
    Reeve::Audit::ChainEpoch.order(:epoch).to_a
  end

  def fingerprint(key)
    Reeve::LedgerKey.fingerprint(key)
  end

  # Cleared first: a key may not be both the signing key and a retired one, even briefly.
  def rotate_config_to(key, retired: [])
    Reeve.config.retired_ledger_keys = []
    Reeve.config.ledger_key = key
    Reeve.config.retired_ledger_keys = retired
  end

  it "opens epoch 0 with the configured key on the first chained write" do
    chain.append!(row)

    expect(epochs.map { |e| [e.epoch, e.key_id, e.first_sequence] })
      .to eq([[0, fingerprint(old_key), 1]])
    expect(entries.map(&:chain_epoch)).to eq([0])
  end

  it "links epoch 0's digest to the genesis, under the epoch's own key" do
    chain.append!(row)
    epoch = epochs.first
    genesis = Reeve::Audit::ChainRecord.ledger.genesis_digest

    expect(epoch.epoch_digest).to eq(canonical.epoch_digest(old_key, epoch, previous_digest: genesis))
  end

  it "opens the next epoch at the first write with a key that has never signed" do
    2.times { chain.append!(row) }
    rotate_config_to(new_key, retired: [old_key])
    2.times { chain.append!(row) }

    expect(epochs.map { |e| [e.epoch, e.key_id, e.first_sequence] })
      .to eq([[0, fingerprint(old_key), 1], [1, fingerprint(new_key), 3]])
    expect(entries.map { |e| [e.chain_epoch, e.chain_key_id] })
      .to eq(([[0, fingerprint(old_key)]] * 2) + ([[1, fingerprint(new_key)]] * 2))
    expect(epochs.last.epoch_digest)
      .to eq(canonical.epoch_digest(new_key, epochs.last, previous_digest: epochs.first.epoch_digest))
  end

  it "puts chain_epoch inside the digest" do
    chain.append!(row)
    entry = entries.first
    tampered = entry.attributes.merge("chain_epoch" => 1)
    previous = Reeve::Audit::ChainRecord.ledger.genesis_digest

    expect(canonical.entry_digest(old_key, tampered, previous_digest: previous)).not_to eq(entry.chain_digest)
  end

  # A rolling deploy: a server still on the old key writes after the new key opened epoch 1.
  it "writes a straggler under the earlier epoch its key opened, opening nothing" do
    chain.append!(row)
    rotate_config_to(new_key, retired: [old_key])
    chain.append!(row)
    rotate_config_to(old_key)
    chain.append!(row)

    expect(epochs.size).to eq(2)
    expect(entries.map(&:chain_epoch)).to eq([0, 1, 0])
    expect(entries.last.chain_key_id).to eq(fingerprint(old_key))
  end

  it "chains a contract-3 row from a custom recorder without an epoch" do
    chain.append!(row(contract_version: 3))

    expect(entries.map(&:chain_epoch)).to eq([nil])
    expect(epochs).to be_empty
  end

  it "rolls the epoch back with a write that fails" do
    chain.append!(row)
    rotate_config_to(new_key, retired: [old_key])

    expect { chain.append!(row(tool_name: nil)) }.to raise_error(ActiveRecord::ActiveRecordError)
    expect(epochs.size).to eq(1)

    chain.append!(row)
    expect(epochs.map { |e| [e.epoch, e.first_sequence] }).to eq([[0, 1], [1, 2]])
  end

  it "opens one epoch for one key however many writes use it" do
    rotate_config_to(new_key)
    5.times { chain.append!(row) }

    expect(epochs.map(&:epoch)).to eq([0])
  end

  it "refuses to change an epoch through the model" do
    chain.append!(row)

    expect { epochs.first.update!(first_sequence: 9) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(epochs.first.destroy).to be(false)
  end

  # specs/003 FR-018 / US5 scenario 4.
  it "names the upgrade when the epochs table is missing" do
    ActiveRecord::Base.connection.drop_table(:reeve_audit_chain_epochs)

    expect { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry).append!(row) }
      .to raise_error(Reeve::ConfigurationError, /reeve_audit_chain_epochs.*reeve:upgrade/)
  ensure
    Ledger.prepare!
  end
end
