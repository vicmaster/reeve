# frozen_string_literal: true

require "support/optional/database"

rails_available = begin
  require "rails/generators"
  require "rails/generators/test_case"
  true
rescue LoadError
  false
end

if rails_available
  require "generators/reeve/install/install_generator"
  require "generators/reeve/upgrade/upgrade_generator"
end

# The upgrade path a host on an older ledger actually takes. The claim worth proving is
# the last one in this file: a table built at contract 1 and upgraded ends up identical to
# one a fresh install creates, because two paths that diverge are two shapes to support.
RSpec.describe "reeve:upgrade generator", if: rails_available do
  let(:destination) { File.join(Dir.tmpdir, "reeve-upgrade-#{Process.pid}") }
  let(:connection) { ActiveRecord::Base.connection }

  # Contract 1, written out rather than derived from the current template by deleting a
  # column: a fixture computed from the thing under test proves nothing about it. This is
  # the table a host that installed reeve 0.1.0 is sitting on.
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- a schema literal is one
  # statement per column; collapsing it into a loop over a column table would hide the
  # thing that makes it useful, which is that it reads as the migration a host ran.
  def create_contract_1_table
    drop_ledger
    connection.create_table :reeve_audit_entries do |t|
      t.string   :invocation_id,  null: false
      t.datetime :occurred_at,    null: false
      t.string   :agent_id,       null: false
      t.string   :agent_name
      t.string   :principal_type
      t.string   :principal_id
      t.string   :tool_name,      null: false
      t.json     :arguments,      null: false
      t.string   :outcome,        null: false
      t.string   :rule,           null: false
      t.text     :detail
      t.string   :record_type
      t.json     :record_ids,     null: false
      t.integer  :record_count,   null: false, default: 0
      t.boolean  :truncated,      null: false, default: false
      t.boolean  :derived,        null: false, default: false
      t.string   :guard,          null: false
      t.integer  :duration_ms
      t.json     :metadata
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  # Contract 2 is contract 1 plus the column the 1 → 2 migration adds, built the way that
  # migration builds it.
  def create_contract_2_table
    create_contract_1_table
    connection.add_column :reeve_audit_entries, :contract_version, :integer, null: false, default: 1
    connection.change_column_default :reeve_audit_entries, :contract_version, from: 1, to: nil
  end

  # Contract 3 is contract 2 plus the chain, built the way the 2 → 3 migration builds it.
  # rubocop:disable-next Metrics/AbcSize -- a schema literal, as for contract 1 above
  def create_contract_3_table
    create_contract_2_table
    connection.add_column :reeve_audit_entries, :chain_sequence, :bigint
    connection.add_column :reeve_audit_entries, :chain_key_id, :string, limit: 16
    connection.add_column :reeve_audit_entries, :chain_digest, :string, limit: 64
    connection.add_index :reeve_audit_entries, :chain_sequence, unique: true
    connection.create_table :reeve_audit_chains do |t|
      t.string   :name,                      null: false
      t.datetime :genesis_at,                null: false, precision: 6
      t.bigint   :pre_chain_count,           null: false
      t.bigint   :pre_chain_unchained_count, null: false
      t.string   :genesis_key_id,            null: false, limit: 16
      t.string   :genesis_digest,            null: false, limit: 64
      t.bigint   :head_sequence,             null: false
      t.string   :head_digest,               null: false, limit: 64
    end
    connection.add_index :reeve_audit_chains, :name, unique: true
  end

  def drop_ledger
    connection.drop_table(:reeve_audit_entries, if_exists: true)
    connection.drop_table(:reeve_audit_chains, if_exists: true)
    connection.drop_table(:reeve_audit_chain_epochs, if_exists: true)
  end

  # Oldest first, which is the order the generator numbers them in and the order a host's
  # db:migrate runs them in.
  def migrate_all_up
    migrations.sort.each do |path|
      load path
      Object.const_get(File.basename(path, ".rb").sub(/\A\d+_/, "").split("_").map(&:capitalize).join)
            .new.migrate(:up)
    end
  end

  def run_upgrade(fresh: true)
    if fresh
      FileUtils.rm_rf(destination)
      FileUtils.mkdir_p(destination)
    end
    capture_say { Reeve::Generators::UpgradeGenerator.start([], destination_root: destination) }
  end

  def capture_say
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def migrations
    Dir[File.join(destination, "db/migrate/*.rb")]
  end

  # The chain's two unique indexes are part of the guarantee (FR-004, FR-022 race), so the
  # two paths must agree on them, not only on columns. The FR-013 query indexes predate
  # contract 2 and are the host's from their original install, so they are not compared.
  def indexes_of
    {
      entries: connection.indexes(:reeve_audit_entries).select { |i| i.columns == ["chain_sequence"] }
                         .map { |i| [i.columns, i.unique] },
      chains: connection.indexes(:reeve_audit_chains).map { |i| [i.columns, i.unique] },
      epochs: connection.indexes(:reeve_audit_chain_epochs).map { |i| [i.columns, i.unique] }.sort
    }
  end

  def shape_of(table)
    connection.columns(table).to_h do |column|
      [column.name, { type: column.type, null: column.null, default: column.default }]
    end
  end

  # This file is the one place that deliberately builds a *wrong-shaped* ledger on the
  # shared connection, so it has to leave nothing behind: a table stuck at contract 1
  # outlives the example and fails every later spec that writes a row, and `Ledger.prepare!`
  # would not repair it because it only rebuilds a table that is missing entirely.
  # Dropping is the only restoration that is certain.
  after do
    FileUtils.rm_rf(destination)
    drop_ledger
    Reeve::Audit::Entry.reset_column_information if defined?(Reeve::Audit::Entry)
    %i[AddContractVersionToReeveAuditEntries AddLedgerChainToReeveAuditEntries
       AddKeyEpochsToReeveAuditEntries].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
  end

  describe "on a ledger two contracts behind (contract 1)" do
    before { create_contract_1_table }

    it "writes every missing step, oldest first" do
      run_upgrade

      written = migrations.sort.map { |path| File.basename(path).sub(/\A\d{14}_/, "") }

      expect(written).to eq(%w[add_contract_version_to_reeve_audit_entries.rb
                               add_ledger_chain_to_reeve_audit_entries.rb
                               add_key_epochs_to_reeve_audit_entries.rb])
    end

    it "says what it wrote and what to run next" do
      output = run_upgrade

      expect(output).to include("audit-entry contract 4")
      expect(output).to include("bin/rails db:migrate")
    end

    it "applies cleanly, stamping existing rows with the contract they were written under" do
      # Built through the connection's own quoting rather than as a SQL literal: `0` is a
      # boolean on SQLite and MySQL and a type error on PostgreSQL, and this row exists to
      # test the migration, not the spec author's SQL.
      connection.insert_fixture(
        {
          "invocation_id" => "old-row", "occurred_at" => "2026-01-01 00:00:00",
          "agent_id" => "a", "tool_name" => "T", "arguments" => "{}", "outcome" => "allow",
          "rule" => "R", "record_ids" => "[]", "record_count" => 0,
          "truncated" => false, "derived" => false, "guard" => "policy"
        },
        "reeve_audit_entries"
      )

      run_upgrade
      migrate_all_up

      version = connection.select_value(
        "SELECT contract_version FROM reeve_audit_entries WHERE invocation_id = 'old-row'"
      )
      expect(version).to eq(1)
    end

    it "rolls back cleanly" do
      run_upgrade
      migrate_all_up
      AddKeyEpochsToReeveAuditEntries.new.migrate(:down)
      AddLedgerChainToReeveAuditEntries.new.migrate(:down)
      AddContractVersionToReeveAuditEntries.new.migrate(:down)

      names = connection.columns(:reeve_audit_entries).map(&:name)
      expect(names).not_to include("contract_version", "chain_sequence", "chain_epoch")
      expect(connection.table_exists?(:reeve_audit_chains)).to be(false)
      expect(connection.table_exists?(:reeve_audit_chain_epochs)).to be(false)
    end
  end

  # specs/002 FR-020, US3: the upgrade a 0.5.0 host makes.
  describe "on a ledger one contract behind (contract 2)" do
    before { create_contract_2_table }

    it "writes the chain step and the key-epoch step" do
      run_upgrade

      expect(migrations.map { |path| File.basename(path) })
        .to contain_exactly(match(/\A\d{14}_add_ledger_chain_to_reeve_audit_entries\.rb\z/),
                            match(/\A\d{14}_add_key_epochs_to_reeve_audit_entries\.rb\z/))
    end

    it "leaves every existing row exactly as it was" do
      connection.insert_fixture(
        {
          "invocation_id" => "old-row", "occurred_at" => "2026-01-01 00:00:00",
          "agent_id" => "a", "tool_name" => "T", "arguments" => "{}", "outcome" => "allow",
          "rule" => "R", "record_ids" => "[]", "record_count" => 0,
          "truncated" => false, "derived" => false, "guard" => "policy", "contract_version" => 2
        },
        "reeve_audit_entries"
      )
      before_upgrade = connection.select_all("SELECT * FROM reeve_audit_entries").to_a

      run_upgrade
      migrate_all_up

      after_upgrade = connection.select_all("SELECT * FROM reeve_audit_entries").to_a
      chain = %w[chain_sequence chain_key_id chain_digest chain_epoch]
      expect(after_upgrade.map { |row| row.except(*chain) }).to eq(before_upgrade)
      expect(after_upgrade.first.values_at(*chain)).to eq([nil, nil, nil, nil])
    end

    # Without the key line, the first guarded call after migrating fails closed. The host
    # learns that here, at the moment they are reading what to do next.
    it "prints the initializer line, the rotation warning and the large-ledger note" do
      output = run_upgrade

      expect(output).to include('config.ledger_key = Rails.application.key_generator.generate_key("reeve audit ledger", 32)')
      expect(output).to match(/secret_key_base/)
      expect(output).to match(/retired_ledger_keys/)
      expect(output).to match(/algorithm: :concurrently/)
    end

    it "is a no-op once applied" do
      run_upgrade
      migrate_all_up
      Object.send(:remove_const, :AddLedgerChainToReeveAuditEntries)
      Object.send(:remove_const, :AddKeyEpochsToReeveAuditEntries)

      output = run_upgrade

      expect(migrations).to be_empty
      expect(output).to include("already at audit-entry contract 4")
    end
  end

  # specs/003 FR-016, US5: the upgrade a 0.6.0 host makes.
  describe "on a ledger one contract behind (contract 3)" do
    before { create_contract_3_table }

    it "writes only the key-epoch step" do
      run_upgrade

      expect(migrations.map { |path| File.basename(path) })
        .to contain_exactly(match(/\A\d{14}_add_key_epochs_to_reeve_audit_entries\.rb\z/))
    end

    it "leaves every existing row exactly as it was" do
      connection.insert_fixture(
        {
          "invocation_id" => "old-row", "occurred_at" => "2026-01-01 00:00:00",
          "agent_id" => "a", "tool_name" => "T", "arguments" => "{}", "outcome" => "allow",
          "rule" => "R", "record_ids" => "[]", "record_count" => 0,
          "truncated" => false, "derived" => false, "guard" => "policy", "contract_version" => 3,
          "chain_sequence" => 1, "chain_key_id" => "0123456789abcdef", "chain_digest" => "a" * 64
        },
        "reeve_audit_entries"
      )
      before_upgrade = connection.select_all("SELECT * FROM reeve_audit_entries").to_a

      run_upgrade
      migrate_all_up

      after_upgrade = connection.select_all("SELECT * FROM reeve_audit_entries").to_a
      expect(after_upgrade.map { |row| row.except("chain_epoch") }).to eq(before_upgrade)
      expect(after_upgrade.first["chain_epoch"]).to be_nil
    end

    it "says the ledger records key epochs and how to rotate" do
      output = run_upgrade

      expect(output).to include("audit-entry contract 4")
      expect(output).to include("bin/rails reeve:rotate_ledger_key")
    end

    it "is a no-op once applied" do
      run_upgrade
      migrate_all_up
      Object.send(:remove_const, :AddKeyEpochsToReeveAuditEntries)

      output = run_upgrade

      expect(migrations).to be_empty
      expect(output).to include("already at audit-entry contract 4")
    end
  end

  describe "on a ledger with the epoch column but no epochs table" do
    before do
      create_contract_3_table
      connection.add_column :reeve_audit_entries, :chain_epoch, :integer
    end

    it "does not report the ledger as current" do
      output = run_upgrade

      expect(output).not_to include("already at audit-entry contract 4")
      expect(migrations.size).to eq(1)
    end
  end

  # The step is applied only when both halves are: a table with the columns but no chain
  # table is half-migrated, and the generator must not call it current.
  describe "on a ledger with the chain columns but no chain table" do
    before do
      create_contract_2_table
      connection.add_column :reeve_audit_entries, :chain_sequence, :bigint
      connection.add_column :reeve_audit_entries, :chain_key_id, :string, limit: 16
      connection.add_column :reeve_audit_entries, :chain_digest, :string, limit: 64
    end

    it "does not report the ledger as current" do
      output = run_upgrade

      expect(output).not_to include("already at audit-entry contract 3")
    end
  end

  describe "when there is no ledger at all" do
    before { drop_ledger }

    it "points at the install generator instead of writing an upgrade" do
      output = run_upgrade

      expect(migrations).to be_empty
      expect(output).to include("reeve:install")
    end
  end

  # Running the generator twice before migrating must not produce two migrations that
  # both add the same column — the second one would fail on migrate.
  describe "running it twice before migrating" do
    before { create_contract_1_table }

    it "leaves one migration per step" do
      run_upgrade
      run_upgrade(fresh: false)

      expect(migrations.size).to eq(3)
    end
  end

  # The claim the whole generator exists to support.
  describe "convergence with a fresh install" do
    it "reaches the same table shape as reeve:install builds from scratch" do
      install_destination = File.join(Dir.tmpdir, "reeve-install-#{Process.pid}")
      FileUtils.rm_rf(install_destination)
      FileUtils.mkdir_p(install_destination)
      capture_say do
        Reeve::Generators::InstallGenerator.start([], destination_root: install_destination)
      end

      # Path A: a fresh install.
      drop_ledger
      load Dir[File.join(install_destination, "db/migrate/*_create_reeve_audit_entries.rb")].first
      CreateReeveAuditEntries.new.migrate(:up)
      fresh = [shape_of(:reeve_audit_entries), shape_of(:reeve_audit_chains),
               shape_of(:reeve_audit_chain_epochs), indexes_of]

      # Path B: a contract 1 table, upgraded through every step.
      create_contract_1_table
      run_upgrade
      migrate_all_up
      upgraded = [shape_of(:reeve_audit_entries), shape_of(:reeve_audit_chains),
                  shape_of(:reeve_audit_chain_epochs), indexes_of]

      expect(upgraded).to eq(fresh)
    ensure
      FileUtils.rm_rf(install_destination)
      Object.send(:remove_const, :CreateReeveAuditEntries) if
        Object.const_defined?(:CreateReeveAuditEntries, false)
    end
  end
end
