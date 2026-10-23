# frozen_string_literal: true

require "securerandom"
require_relative "../support/envelope"

# specs/002 T037 / US3, FR-020, FR-022, SC-007 — a 0.5.0 ledger, upgraded.
#
# The migration reeve:upgrade writes is run against a ledger that already holds rows, and
# the first guarded call afterwards starts the chain. The old rows must come through
# byte-for-byte: nothing is backfilled into an append-only table.
RSpec.describe "upgrading a contract-2 ledger to the chain" do
  include Envelope

  let(:connection) { ActiveRecord::Base.connection }
  # Both steps a 0.5.0 host's upgrade emits: the chain (3), then key epochs (4).
  let(:upgrade_templates) do
    %w[add_ledger_chain_to_reeve_audit_entries add_key_epochs_to_reeve_audit_entries].map do |name|
      File.expand_path("../../../../lib/generators/reeve/upgrade/templates/#{name}.rb.tt", __dir__)
    end
  end

  # The contract-2 shape: the install template's table, less what contracts 3 and 4 added.
  def downgrade_to_previous_contract
    connection.remove_index(:reeve_audit_entries, :chain_sequence)
    %w[chain_sequence chain_key_id chain_digest chain_epoch].each do |column|
      connection.remove_column(:reeve_audit_entries, column)
    end
    connection.drop_table(:reeve_audit_chains)
    connection.drop_table(:reeve_audit_chain_epochs)
    Reeve::Audit::Entry.reset_column_information
  end

  def legacy_rows!(count)
    rows = Array.new(count) do |i|
      { invocation_id: "legacy-#{i}", occurred_at: Time.utc(2026, 9, 1, 12, 0, i), agent_id: "a",
        tool_name: "InvoiceSearchTool", arguments: { "q" => i }, outcome: "allow", rule: "r",
        record_ids: [i.to_s], record_count: 1, guard: "policy", contract_version: 2 }
    end
    Reeve::Audit::Entry.insert_all!(rows)
  end

  def snapshot
    connection.select_all("SELECT * FROM reeve_audit_entries WHERE contract_version = 2 ORDER BY invocation_id")
              .to_a.map { |row| row.except("chain_sequence", "chain_key_id", "chain_digest", "chain_epoch") }
  end

  def run_upgrade_migration
    upgrade_templates.each { |template| Object.class_eval(File.read(template), template) }
    AddLedgerChainToReeveAuditEntries.new.migrate(:up)
    AddKeyEpochsToReeveAuditEntries.new.migrate(:up)
    Reeve::Audit::Entry.reset_column_information
  end

  before do
    Ledger.prepare!
    downgrade_to_previous_contract
    legacy_rows!(50)
  end

  after do
    %i[AddLedgerChainToReeveAuditEntries AddKeyEpochsToReeveAuditEntries].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
    connection.drop_table(:reeve_audit_entries, if_exists: true)
    connection.drop_table(:reeve_audit_chains, if_exists: true)
    connection.drop_table(:reeve_audit_chain_epochs, if_exists: true)
    Ledger.prepare!
  end

  it "leaves the old rows untouched, starts the chain on the next call, and reports the rest as uncovered" do
    before_upgrade = snapshot

    run_upgrade_migration
    expect(snapshot).to eq(before_upgrade)

    invoke { [] }

    record = Reeve::Audit::ChainRecord.ledger
    expect(record.pre_chain_count).to eq(50)
    expect(snapshot).to eq(before_upgrade)

    result = Reeve::Audit::Chain.verify
    expect(result.status).to eq(:intact)
    expect(result.covered).to eq(1..1)
    expect(result.uncovered_now).to eq(50)
    expect(result.to_s).to include("50 earlier entries not covered (50 when the chain started)")
  end

  # A rolling deploy: servers still on 0.5.0 keep writing contract-2 rows after the chain
  # has started. Uncovered, counted, and not a break.
  it "stays intact while old servers keep writing contract-2 rows" do
    run_upgrade_migration
    invoke { [] }
    legacy_rows_after = Array.new(3) do |i|
      { invocation_id: "late-legacy-#{i}", occurred_at: Time.now, agent_id: "a", tool_name: "T",
        arguments: {}, outcome: "allow", rule: "r", record_ids: [], guard: "policy", contract_version: 2 }
    end
    Reeve::Audit::Entry.insert_all!(legacy_rows_after)
    invoke { [] }

    result = Reeve::Audit::Chain.verify

    expect(result.status).to eq(:intact)
    expect(result.covered).to eq(1..2)
    expect(result.uncovered_now).to eq(53)
    expect(result.uncovered_at_genesis).to eq(50)
  end
end
