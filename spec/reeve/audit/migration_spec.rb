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

  # rubocop:disable Layout/HashAlignment
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
    "metadata"       => { type: :json,     null: true }
  }.each do |name, expected|
    it "creates #{name} as #{expected[:type]}, null: #{expected[:null]}" do
      expect(column(name)).not_to be_nil, "#{name} is missing from the table"
      expect(column(name).type).to eq(expected[:type])
      expect(column(name).null).to be(expected[:null])
    end
  end
  # rubocop:enable Layout/HashAlignment

  it "defaults the flag columns so an insert never has to spell them out" do
    expect(column("truncated").default).to eq("0").or eq(false)
    expect(column("derived").default).to eq("0").or eq(false)
    expect(column("record_count").default.to_i).to eq(0)
  end

  it "indexes invocation_id uniquely, which is what makes 'exactly one row' checkable" do
    index = Ledger.indexes.find { |i| i.columns == ["invocation_id"] }

    expect(index).not_to be_nil
    expect(index.unique).to be(true)
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

  it "rolls back cleanly and can be re-applied" do
    Ledger.migrate_down!
    expect(Ledger.table_exists?).to be(false)

    Ledger.migrate_up!
    expect(Ledger.table_exists?).to be(true)
  end
end
