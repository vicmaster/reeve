# frozen_string_literal: true

require "securerandom"
require_relative "../support/ledger"

# specs/003, code review R2/R3: the reads a write or a rotation makes under the chain
# record's lock must see rows another writer committed while this one queued for it.
#
# InnoDB at REPEATABLE READ — MySQL's default — serves a plain SELECT from the snapshot the
# transaction took at its first read. Under the default Recorder the ledger write runs inside
# the host's transaction, which has usually read already. So a writer whose snapshot predates
# a new epoch would not see it, try to open that epoch again, and fail on the unique index;
# a rotation would take a head from before writes that had committed. Chain::Head.current
# makes those reads locking reads on MySQL. PostgreSQL (READ COMMITTED) and SQLite (one
# writer, no snapshot) read the latest rows anyway, so this is MySQL's alone.
#
# The "other process" is a thread on its own pooled connection, committing on its own.
RSpec.describe "chain reads under the lock see the latest committed rows (MySQL)" do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:key_a) { Ledger::TEST_KEY }
  let(:key_b) { "reeve-spec-second-ledger-key-0123456789abcdef" }
  let(:key_c) { "reeve-spec-third-ledger-key-0123456789abcdefgh" }

  before do
    skip("InnoDB REPEATABLE READ snapshots: MySQL only") unless SpecDatabase.adapter == "mysql2"
    Ledger.prepare!
    chain.append!(row)
  end

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

  # Runs the block as another process would: its own connection, committed on its own.
  def elsewhere(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.join
  end

  # Opens the host's transaction and takes its snapshot with a first read, as a tool that
  # queried before the guarded call returned would.
  def inside_a_host_transaction_that_has_read(&block)
    Reeve::Audit::Entry.transaction do
      Reeve::Audit::Entry.connection.select_value("SELECT COUNT(*) FROM reeve_audit_chain_epochs")
      block.call
    end
  end

  it "signs under an epoch another writer opened after the host's snapshot" do
    configure(key_b, retired: [key_a])

    entry = inside_a_host_transaction_that_has_read do
      elsewhere { chain.append!(row) } # opens epoch 1 with key B and commits
      chain.append!(row)
    end

    expect(entry.chain_epoch).to eq(1)
    expect(Reeve::Audit::ChainEpoch.order(:epoch).pluck(:epoch)).to eq([0, 1])
    expect(Reeve::Audit::Chain.verify.status).to eq(:intact)
  end

  it "opens the next epoch number, not one another writer already took" do
    configure(key_b, retired: [key_a])

    entry = inside_a_host_transaction_that_has_read do
      elsewhere { chain.append!(row) } # epoch 1, key B
      configure(key_c, retired: [key_a, key_b])
      chain.append!(row) # key C: must open epoch 2, seeing epoch 1
    end

    expect(entry.chain_epoch).to eq(2)
    expect(Reeve::Audit::Chain.verify.status).to eq(:intact)
  end

  it "rotates from the head as committed, not as the host's snapshot saw it" do
    rotation = inside_a_host_transaction_that_has_read do
      Reeve::Audit::ChainRecord.uncached { Reeve::Audit::ChainRecord.ledger.head_sequence }
      elsewhere { 2.times { chain.append!(row) } } # head 1 → 3, committed
      configure(key_b, retired: [key_a])
      Reeve::Audit::Chain.rotate_key!
    end

    expect(rotation.first_sequence).to eq(4)
    chain.append!(row)
    expect(Reeve::Audit::Chain.verify.status).to eq(:intact)
  end
end
