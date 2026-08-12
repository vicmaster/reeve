# frozen_string_literal: true

require_relative "support/ledger"

# T042 / FR-015. The entry shape is a versioned public contract, and a version that lives
# only in prose drifts from the code that implements it. This spec makes the document and
# the constant fail together.
RSpec.describe "the audit entry contract" do
  before { Ledger.prepare! }

  # Explicitly UTF-8: `File.read` uses the default external encoding, which is US-ASCII
  # under a POSIX locale, and these documents are full of em dashes. Without this the
  # examples below die on `invalid byte sequence` instead of comparing anything — which
  # is exactly what spec/readme_spec.rb was doing unnoticed until 0.1.1.
  def read_doc(relative)
    File.read(File.expand_path("../../../specs/001-guardrails-core/#{relative}", __dir__),
              encoding: "UTF-8")
  end

  it "records the version documented in contracts/audit-entry.md" do
    documented = read_doc("contracts/audit-entry.md")[/\*\*Contract version\*\*:\s*`(\d+)`/, 1]

    expect(documented).not_to be_nil, "contracts/audit-entry.md no longer states a version"
    expect(Reeve::Audit::CONTRACT_VERSION).to eq(Integer(documented))
  end

  it "exposes on the class the version this build of the gem writes" do
    expect(Reeve::Audit::Entry.contract_version).to eq(Reeve::Audit::CONTRACT_VERSION)
  end

  # The class method answers "what does this gem write?"; the column answers "what was
  # this row written under?". They agree today and diverge for every row that outlives an
  # upgrade, which is the only reason the column is worth its width.
  it "stamps each row with the contract it was written under" do
    entry = Reeve::Audit::Recorder.record(
      invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a",
      tool_name: "T", arguments: {}, outcome: "allow", rule: "R", guard: "policy"
    )

    expect(entry.contract_version).to eq(Reeve::Audit::CONTRACT_VERSION)
  end

  it "refuses a row that does not name its shape, so an unstamped row cannot exist" do
    entry = Reeve::Audit::Entry.new(
      invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a",
      tool_name: "T", arguments: {}, outcome: "allow", rule: "R", guard: "policy",
      record_ids: [], record_count: 0
    )

    expect(entry).not_to be_valid
    expect(entry.errors[:contract_version]).to be_present
  end

  it "has every column data-model.md lists for the entity" do
    table = read_doc("data-model.md")[/### AuditEntry.*?\*\*Immutability/m]
    documented_columns = table.scan(/^\| `(\w+)` \|/).flatten

    expect(documented_columns.size).to be > 15, "the data-model table did not parse"
    expect(Reeve::Audit::Entry.column_names).to include(*documented_columns)
  end
end
