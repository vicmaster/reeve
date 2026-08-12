# frozen_string_literal: true

require "support/optional/authorization_records"
require "reeve/audit"
require "reeve/audit/support/ledger"

# The README's "Wrapping your own JSON-RPC server" recipe, executed.
#
# There is no adapter to test here — that is the point of the section. A host with its own
# `/mcp` controller integrates by calling `Reeve.invoke` once, and what needs proving is
# that the recipe as written actually holds: the principal comes from the resolver rather
# than the call site, the transport metadata reaches both the resolver and the ledger, and
# an unguarded tool is recorded as such while the host is still migrating.
#
# Written against a hand-rolled dispatcher rather than a mock, so the spec fails if the
# documented integration path stops working.
RSpec.describe "a host's own JSON-RPC dispatcher" do
  let(:alice) { Owner.new(1) }
  let(:bob)   { Owner.new(2) }

  # Stands in for the host's `Current` — set by the controller after it authenticates the
  # bearer token, exactly as the README describes.
  let(:current) { Struct.new(:user).new(nil) }

  before do
    Ledger.prepare!
    Invoice.delete_all
    2.times { |i| Invoice.create!(number: "A-#{i}", owner_id: alice.id) }
    Invoice.create!(number: "B-0", owner_id: bob.id)

    Reeve.configure do |c|
      c.audit_recorder = Reeve::Audit::Recorder
      c.principal_resolver = lambda { |context|
        current.user || token_user(context.metadata.dig(:headers, "Authorization"))
      }
    end

    stub_const("InvoiceListTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy

      def call = Invoice.all
    end)

    stub_const("LegacyStatsTool", Class.new do
      def call = Invoice.count
    end)

    stub_const("REGISTRY", { "invoice_list" => InvoiceListTool,
                             "legacy_stats" => LegacyStatsTool })
  end

  def token_user(header)
    id = header.to_s.delete_prefix("Bearer ")
    id.empty? ? nil : Owner.new(id.to_i)
  end

  # The controller action from the README, minus Rails.
  def dispatch(name, arguments: {}, headers: {})
    Reeve.invoke(
      tool: REGISTRY.fetch(name),
      arguments: arguments,
      agent: { id: headers["X-MCP-Client"] || "unknown" },
      metadata: { headers: headers }
    )
  rescue Reeve::DeniedError => e
    { error: { code: -32_003, message: e.message } }
  end

  def only_entry
    entries = Reeve::Audit::Entry.all.to_a
    raise "expected exactly one entry, got #{entries.size}" unless entries.size == 1

    entries.first
  end

  it "scopes to the principal the controller established, without passing it in" do
    current.user = alice

    records = dispatch("invoice_list", headers: { "X-MCP-Client" => "claude-desktop" })

    expect(records.map(&:number)).to contain_exactly("A-0", "A-1")
    expect(only_entry.principal_id).to eq("1")
    expect(only_entry.agent_id).to eq("claude-desktop")
  end

  it "falls back to the bearer token when the controller set nothing" do
    records = dispatch("invoice_list", headers: { "Authorization" => "Bearer 2" })

    expect(records.map(&:number)).to eq(["B-0"])
    expect(only_entry.principal_id).to eq("2")
  end

  it "denies and records when neither identifies anyone" do
    result = dispatch("invoice_list")

    expect(result.dig(:error, :code)).to eq(-32_003)
    expect(only_entry).to be_denied
    expect(only_entry.rule).to eq(Reeve::Decision::NO_PRINCIPAL)
  end

  it "records the request headers, with the credential redacted" do
    dispatch("invoice_list", headers: { "Authorization" => "Bearer 1", "X-Request-Id" => "r1" })

    expect(only_entry.metadata["headers"])
      .to eq("Authorization" => Reeve::Audit::Redactor::MARKER, "X-Request-Id" => "r1")
  end

  describe "adopting one tool at a time" do
    it "denies a tool with no guard by default" do
      current.user = alice

      expect(dispatch("legacy_stats").dig(:error, :message))
        .to include(Reeve::Decision::NO_GUARD_DECLARED)
    end

    it "runs it with guard: none while the host is migrating, which is the worklist" do
      Reeve.config.unguarded_tools = :allow_with_warning
      Reeve.config.logger = CapturingLogger.new
      current.user = alice

      expect(dispatch("legacy_stats")).to eq(3)

      expect(only_entry.guard).to eq("none")
      expect(only_entry.rule).to eq(Reeve::Decision::UNGUARDED_TOOL)
      expect(Reeve::Audit::Entry.where(guard: "none").distinct.pluck(:tool_name))
        .to eq([only_entry.tool_name])
    end
  end

  it "runs the compliance checks through the host's own dispatcher" do
    require "reeve/testing"

    results = Reeve::Checks.run_all(
      principals: [alice, bob],
      tools: [InvoiceListTool],
      invoke: lambda { |tool:, principal:, arguments:|
        current.user = principal
        Reeve.invoke(tool: tool, arguments: arguments, agent: { id: "compliance" })
      }
    )

    expect(results).to be_passed, -> { results.to_s }
  end
end
