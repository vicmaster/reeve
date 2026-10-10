# frozen_string_literal: true

require_relative "support/ledger"

# T036 / FR-015. The generated migration is the only thing standing between a host
# application and an unusable ledger, so the table it creates is pinned column by column
# and index by index against data-model.md.
RSpec.describe "the audit entries migration" do
  before { Ledger.prepare! }

  def column(name)
    Ledger.columns.find { |c| c.name == name }
  end

  def index_columns
    Ledger.indexes.map(&:columns)
  end

  it "creates the reeve_audit_entries table" do
    expect(Ledger.table_exists?).to be(true)
    expect(Reeve::Audit::Entry.table_name).to eq("reeve_audit_entries")
  end

  # rubocop:disable-next Layout/HashAlignment
  {
    "invocation_id"  => { type: :string,   null: false },
    "occurred_at"    => { type: :datetime, null: false },
    "agent_id"       => { type: :string,   null: false },
    "agent_name"     => { type: :string,   null: true },
    "principal_type" => { type: :string,   null: true },
    "principal_id"   => { type: :string,   null: true },
    "tool_name"      => { type: :string,   null: false },
    "arguments"      => { type: :json,     null: false },
    "outcome"        => { type: :string,   null: false },
    "rule"           => { type: :string,   null: false },
    "record_type"    => { type: :string,   null: true },
    "record_ids"     => { type: :json,     null: false },
    "record_count"   => { type: :integer,  null: false },
    "truncated"      => { type: :boolean,  null: false },
    "derived"        => { type: :boolean,  null: false },
    "guard"          => { type: :string,   null: false },
    "duration_ms"    => { type: :integer,  null: true },
    "metadata"       => { type: :json,     null: true },
    "contract_version" => { type: :integer, null: false },
    # Contract 3 (specs/002): nullable, because every row written before the upgrade has
    # no honest value for them, and an unchained contract-3 row is reported, not refused.
    "chain_sequence" => { type: :integer,  null: true },
    "chain_key_id"   => { type: :string,   null: true },
    "chain_digest"   => { type: :string,   null: true }
  }.each do |name, expected|
    it "creates #{name} as #{expected[:type]}, null: #{expected[:null]}" do
      expect(column(name)).not_to be_nil, "#{name} is missing from the table"
      expect(column(name).type).to eq(expected[:type])
      expect(column(name).null).to be(expected[:null])
    end
  end

  # Read through the boolean type rather than matched as a string: each engine, and each
  # ActiveRecord release, spells the same default differently — "0", false, and since
  # 8.1.4 on PostgreSQL, "false". What matters is that it casts to false, not to nil.
  it "defaults the flag columns so an insert never has to spell them out" do
    boolean = ActiveModel::Type::Boolean.new

    expect(boolean.cast(column("truncated").default)).to be(false)
    expect(boolean.cast(column("derived").default)).to be(false)
    expect(column("record_count").default.to_i).to eq(0)
  end

  it "indexes invocation_id uniquely, which is what makes 'exactly one row' checkable" do
    index = Ledger.indexes.find { |i| i.columns == ["invocation_id"] }

    expect(index).not_to be_nil
    expect(index.unique).to be(true)
  end

  # specs/002 FR-004: two writers can never hold the same position. It also orders the
  # verifier's walk.
  it "indexes chain_sequence uniquely" do
    index = Ledger.indexes.find { |i| i.columns == ["chain_sequence"] }

    expect(index).not_to be_nil
    expect(index.unique).to be(true)
  end

  # Rows written before the upgrade, and unchained contract-3 rows, all have a NULL
  # sequence. NULLs are distinct under a unique index on all three engines; this pins it.
  it "lets any number of rows have no chain sequence" do
    row = lambda do |id|
      { invocation_id: id, occurred_at: Time.now, agent_id: "a", tool_name: "t", arguments: {},
        outcome: "allow", rule: "r", record_ids: [], guard: "policy", contract_version: 3 }
    end

    expect { 2.times { |i| Reeve::Audit::Entry.create!(row.call("inv-#{i}")) } }.not_to raise_error
  end

  describe "reeve_audit_chains (specs/002 data-model)" do
    def chain_column(name)
      ActiveRecord::Base.connection.columns(:reeve_audit_chains).find { |c| c.name == name }
    end

    # rubocop:disable-next Layout/HashAlignment
    {
      "name"                      => :string,
      "genesis_at"                => :datetime,
      "pre_chain_count"           => :integer,
      "pre_chain_unchained_count" => :integer,
      "genesis_key_id"            => :string,
      "genesis_digest"            => :string,
      "head_sequence"             => :integer,
      "head_digest"               => :string
    }.each do |name, type|
      it "creates #{name} as #{type}, not null" do
        expect(chain_column(name)).not_to be_nil, "#{name} is missing from reeve_audit_chains"
        expect(chain_column(name).type).to eq(type)
        expect(chain_column(name).null).to be(false)
      end
    end

    it "keeps microseconds on genesis_at, so the genesis digest survives a round trip" do
      expect(chain_column("genesis_at").precision).to eq(6)
    end

    it "indexes name uniquely, so two writers racing to start the chain cannot both win" do
      index = ActiveRecord::Base.connection.indexes(:reeve_audit_chains).find { |i| i.columns == ["name"] }

      expect(index).not_to be_nil
      expect(index.unique).to be(true)
    end
  end

  # One composite index per FR-013 query axis.
  [
    %w[principal_type principal_id occurred_at],
    %w[tool_name occurred_at],
    %w[agent_id occurred_at],
    %w[outcome occurred_at]
  ].each do |columns|
    it "indexes (#{columns.join(', ')}) for the #{columns.first} query axis" do
      expect(index_columns).to include(columns)
    end
  end

  # T043. The grant is the only thing that makes the ledger immutable against raw SQL,
  # and the migration is where a host will actually read it. Losing that paragraph in a
  # future edit would quietly downgrade the guarantee, so it is pinned here.
  it "tells the host how to make the table append-only in the database" do
    template = File.read(Ledger::TEMPLATE)

    expect(template).to match(/GRANT INSERT, SELECT\s+ON reeve_audit_entries/)
    expect(template).to match(/retention|archival/i)
    expect(template).to match(/tamper-evidence|chaining/i)
  end

  # specs/002 contracts/audit-entry-v3.md: the chain record's head moves on every write, so
  # it needs UPDATE — and a role holding UPDATE can rewind the head, which the template
  # must say rather than leave to be discovered.
  it "documents the chain table's grant and what it does not protect against" do
    template = File.read(Ledger::TEMPLATE)

    expect(template).to match(/GRANT INSERT, SELECT, UPDATE\s+ON reeve_audit_chains/)
    expect(template).to match(/rewind the head/)
    expect(template).not_to match(/no cryptographic chaining/i)
  end

  it "rolls back cleanly and can be re-applied" do
    Ledger.migrate_down!
    expect(Ledger.table_exists?).to be(false)
    expect(ActiveRecord::Base.connection.table_exists?(:reeve_audit_chains)).to be(false)

    Ledger.migrate_up!
    expect(Ledger.table_exists?).to be(true)
  end
end
