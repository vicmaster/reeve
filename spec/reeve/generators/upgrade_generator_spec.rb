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
    connection.drop_table(:reeve_audit_entries, if_exists: true)
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
    connection.drop_table(:reeve_audit_entries, if_exists: true)
    Reeve::Audit::Entry.reset_column_information if defined?(Reeve::Audit::Entry)
    Object.send(:remove_const, :AddContractVersionToReeveAuditEntries) if
      Object.const_defined?(:AddContractVersionToReeveAuditEntries, false)
  end

  describe "on a ledger that is a contract behind" do
    before { create_contract_1_table }

    it "writes the migration that adds what is missing" do
      run_upgrade

      expect(migrations.size).to eq(1)
      expect(File.basename(migrations.first))
        .to match(/\A\d{14}_add_contract_version_to_reeve_audit_entries\.rb\z/)
    end

    it "says what it wrote and what to run next" do
      output = run_upgrade

      expect(output).to include("audit-entry contract 2")
      expect(output).to include("bin/rails db:migrate")
    end

    it "applies cleanly, stamping existing rows with the contract they were written under" do
      connection.execute(<<~SQL)
        INSERT INTO reeve_audit_entries
          (invocation_id, occurred_at, agent_id, tool_name, arguments, outcome, rule,
           record_ids, record_count, truncated, derived, guard)
        VALUES ('old-row', '2026-01-01 00:00:00', 'a', 'T', '{}', 'allow', 'R',
                '[]', 0, 0, 0, 'policy')
      SQL

      run_upgrade
      load migrations.first
      AddContractVersionToReeveAuditEntries.new.migrate(:up)

      version = connection.select_value(
        "SELECT contract_version FROM reeve_audit_entries WHERE invocation_id = 'old-row'"
      )
      expect(version).to eq(1)
    end

    it "rolls back cleanly" do
      run_upgrade
      load migrations.first
      AddContractVersionToReeveAuditEntries.new.migrate(:up)
      AddContractVersionToReeveAuditEntries.new.migrate(:down)

      expect(connection.columns(:reeve_audit_entries).map(&:name)).not_to include("contract_version")
    end
  end

  describe "on a ledger that is already current" do
    before do
      create_contract_1_table
      connection.add_column :reeve_audit_entries, :contract_version, :integer, null: false, default: 1
      connection.change_column_default :reeve_audit_entries, :contract_version, from: 1, to: nil
    end

    it "writes nothing and says so" do
      output = run_upgrade

      expect(migrations).to be_empty
      expect(output).to include("already at audit-entry contract 2")
    end
  end

  describe "when there is no ledger at all" do
    before { connection.drop_table(:reeve_audit_entries, if_exists: true) }

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

    it "leaves one migration" do
      run_upgrade
      run_upgrade(fresh: false)

      expect(migrations.size).to eq(1)
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
      connection.drop_table(:reeve_audit_entries, if_exists: true)
      load Dir[File.join(install_destination, "db/migrate/*_create_reeve_audit_entries.rb")].first
      CreateReeveAuditEntries.new.migrate(:up)
      fresh = shape_of(:reeve_audit_entries)

      # Path B: a contract 1 table, upgraded.
      create_contract_1_table
      run_upgrade
      load migrations.first
      AddContractVersionToReeveAuditEntries.new.migrate(:up)
      upgraded = shape_of(:reeve_audit_entries)

      expect(upgraded).to eq(fresh)
    ensure
      FileUtils.rm_rf(install_destination)
      Object.send(:remove_const, :CreateReeveAuditEntries) if
        Object.const_defined?(:CreateReeveAuditEntries, false)
    end
  end
end
