# frozen_string_literal: true

require_relative "support/ledger"

# T042 / FR-015. The entry shape is a versioned public contract, and a version that lives
# only in prose drifts from the code that implements it. This spec makes the document and
# the constant fail together.
RSpec.describe "the audit entry contract" do
  before { Ledger.prepare! }

  def read_doc(relative)
    File.read(File.expand_path("../../../specs/001-guardrails-core/#{relative}", __dir__))
  end

  it "records the version documented in contracts/audit-entry.md" do
    documented = read_doc("contracts/audit-entry.md")[/\*\*Contract version\*\*:\s*`(\d+)`/, 1]

    expect(documented).not_to be_nil, "contracts/audit-entry.md no longer states a version"
    expect(Reeve::Audit::CONTRACT_VERSION).to eq(Integer(documented))
  end

  it "exposes the version on the entry, so an exported row can name its own shape" do
    expect(Reeve::Audit::Entry.contract_version).to eq(Reeve::Audit::CONTRACT_VERSION)
  end

  it "has every column data-model.md lists for the entity" do
    table = read_doc("data-model.md")[/### AuditEntry.*?\*\*Immutability/m]
    documented_columns = table.scan(/^\| `(\w+)` \|/).flatten

    expect(documented_columns.size).to be > 15, "the data-model table did not parse"
    expect(Reeve::Audit::Entry.column_names).to include(*documented_columns)
  end
end
