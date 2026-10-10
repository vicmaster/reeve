# frozen_string_literal: true

require_relative "support/ledger"

# specs/002 T014 / data-model "reeve_audit_chains": the one row that holds the genesis and
# the head. What the model can enforce, it enforces; raw SQL is the verifier's problem.
RSpec.describe Reeve::Audit::ChainRecord do
  before { Ledger.prepare! }

  def create_record(**overrides)
    described_class.create!(
      { name: "ledger", genesis_at: Time.utc(2026, 10, 8), pre_chain_count: 10,
        pre_chain_unchained_count: 0, genesis_key_id: "abcdef0123456789",
        genesis_digest: "a" * 64, head_sequence: 1, head_digest: "b" * 64 }.merge(overrides)
    )
  end

  it "reads the reeve_audit_chains table" do
    expect(described_class.table_name).to eq("reeve_audit_chains")
  end

  it "finds the ledger's record by its fixed name" do
    record = create_record

    expect(described_class.ledger).to eq(record)
  end

  it "returns nil when the chain has not started" do
    expect(described_class.ledger).to be_nil
  end

  # The genesis is link 0. Changing any of it through the model is refused, not saved.
  it "never writes a genesis column after creation" do
    record = create_record

    changes = {
      genesis_at: Time.utc(2027, 1, 1), pre_chain_count: 99, pre_chain_unchained_count: 99,
      genesis_key_id: "x", genesis_digest: "x", name: "x"
    }

    changes.each do |column, value|
      expect { record.update!(column => value) }
        .to raise_error(ActiveRecord::ActiveRecordError), "#{column} was writable"
    end

    record.reload
    expect(record.genesis_digest).to eq("a" * 64)
    expect(record.pre_chain_count).to eq(10)
  end

  it "cannot be destroyed through the model" do
    record = create_record

    expect(record.destroy).to be(false)
    expect(described_class.count).to eq(1)
  end

  it "allows only one record per name" do
    create_record

    expect { create_record }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
