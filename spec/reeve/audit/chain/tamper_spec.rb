# frozen_string_literal: true

require "securerandom"
require_relative "../support/envelope"

# specs/002 T023 / FR-013, SC-001 — the spec's "Detected" list, one example per tamper class.
#
# Every change below is made at the relation level (`update_all`, `delete_all`,
# `insert_all!`), which issues SQL directly and bypasses Entry's read-only model, exactly as
# a DBA or a stolen application credential would. None of them touches the key.
#
# Each example was verified red by disabling the check in the verifier that catches it.
RSpec.describe "tampering with a chained ledger" do
  include Envelope

  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:entries) { Reeve::Audit::Entry }

  before do
    Ledger.prepare!
    8.times { chain.append!(row) }
  end

  def row(**overrides)
    { invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
      arguments: { "q" => "x" }, outcome: "allow", rule: "r", record_ids: [], guard: "policy",
      contract_version: Reeve::Audit::CONTRACT_VERSION }.merge(overrides)
  end

  def at(sequence)
    entries.where(chain_sequence: sequence)
  end

  def verify
    Reeve::Audit::Chain.verify
  end

  def breaks
    verify.breaks.map { |b| [b.kind, b.sequence] }
  end

  it "starts intact, or every example below proves nothing" do
    expect(verify.status).to eq(:intact)
    expect(verify.covered).to eq(1..8)
  end

  it "detects an edited value, at exactly that position" do
    at(3).update_all(rule: "AdminPolicy#index?")

    expect(verify.status).to eq(:broken)
    expect(breaks).to eq([[:digest_mismatch, 3]])
  end

  it "detects an edited row that also had its digest rewritten without the key" do
    at(3).update_all(rule: "AdminPolicy#index?", chain_digest: "0" * 64)

    expect(breaks).to include([:digest_mismatch, 3])
  end

  it "detects a row deleted from the middle, as a gap and a broken link after it" do
    at(3).delete_all

    expect(verify.status).to eq(:broken)
    expect(breaks).to eq([[:missing, 3..3], [:digest_mismatch, 4]])
  end

  it "detects two rows whose sequence numbers were swapped, at both positions" do
    at(2).update_all(chain_sequence: -1)
    at(4).update_all(chain_sequence: 2)
    at(-1).update_all(chain_sequence: 4)

    expect(breaks).to include([:digest_mismatch, 2], [:digest_mismatch, 4])
  end

  it "detects a forged row put in place of a real one" do
    at(5).delete_all
    entries.insert_all!([row(chain_sequence: 5, chain_key_id: Reeve.config.ledger_key_id,
                             chain_digest: "a" * 64, arguments: { "q" => "forged" })])

    expect(breaks).to include([:digest_mismatch, 5])
  end

  it "detects the newest rows deleted while the chain record was left alone" do
    entries.where("chain_sequence > 6").delete_all

    expect(verify.status).to eq(:broken)
    expect(breaks).to include([:head_mismatch, 8])
  end

  # The unique index makes a repeated sequence impossible through SQL — until someone with
  # DDL rights drops it. The verifier does not rely on the index being there.
  it "detects a repeated sequence, once the unique index that prevents it is dropped" do
    connection = ActiveRecord::Base.connection
    connection.remove_index(:reeve_audit_entries, :chain_sequence)
    original = at(5).first
    entries.insert_all!([original.attributes.except("id").merge("invocation_id" => SecureRandom.uuid)])

    expect(breaks).to include([:duplicate, 5])
  ensure
    entries.where(chain_sequence: 5).where.not(id: original&.id).delete_all
    connection.add_index(:reeve_audit_entries, :chain_sequence, unique: true)
  end

  it "detects the chain record deleted while chained rows remain" do
    Reeve::Audit::ChainRecord.delete_all

    expect(verify.status).to eq(:broken)
    expect(verify.breaks.map(&:kind)).to include(:chain_record_missing)
  end

  it "detects an altered genesis" do
    Reeve::Audit::ChainRecord.update_all(pre_chain_count: 0, genesis_at: Time.utc(2020, 1, 1))
    Reeve::Audit::ChainRecord.update_all(pre_chain_count: 1)

    expect(verify.breaks.map(&:kind)).to include(:genesis_altered)
  end

  describe "a row forged one past the head" do
    before do
      entries.insert_all!([row(chain_sequence: 9, chain_key_id: Reeve.config.ledger_key_id,
                               chain_digest: "b" * 64)])
    end

    it "is reported as beyond_head" do
      expect(breaks).to include([:beyond_head, 9])
    end

    # The forged row holds the position the next real write needs, so that write fails on
    # the unique sequence — loud on the write path as well as in verification.
    it "makes the next legitimate write fail closed" do
      expect { invoke { [] } }.to raise_error(Reeve::AuditWriteError)
    end
  end

  it "reports every independent break, with complete totals" do
    at(2).update_all(rule: "x")
    at(4).update_all(tool_name: "y")
    at(7).delete_all

    result = verify

    expect(result.breaks.map { |b| [b.kind, b.sequence] }).to eq([
                                                                   [:digest_mismatch, 2], [:digest_mismatch, 4], [:missing, 7..7], [:digest_mismatch, 8]
                                                                 ])
    expect(result.totals).to include(digest_mismatch: 3, missing: 1)
  end
end
