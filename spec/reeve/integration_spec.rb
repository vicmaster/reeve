# frozen_string_literal: true

require "support/optional/authorization_records"
require "reeve/audit"
require "reeve/audit/support/ledger"

# The seam between authorization and audit: a real guarded invocation, a real policy, a
# real ledger row. Each module's own specs stub the other side, so this is the only place
# that proves the two halves actually meet.
RSpec.describe "a guarded invocation, end to end" do
  let(:alice) { Owner.new(1) }
  let(:bob)   { Owner.new(2) }

  before do
    Ledger.prepare!
    Invoice.delete_all
    Reeve.configure { |c| c.audit_recorder = Reeve::Audit::Recorder }

    2.times { |i| Invoice.create!(number: "A-#{i}", owner_id: alice.id) }
    Invoice.create!(number: "B-0", owner_id: bob.id)

    stub_const("InvoiceSearchTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy
      redact :customer_ssn

      def call(query:, customer_ssn: nil)
        Invoice.where("number LIKE ?", "#{query}%")
      end
    end)
  end

  def entry
    entries = Reeve::Audit::Entry.all.to_a
    raise "expected exactly one entry, got #{entries.size}" unless entries.size == 1

    entries.first
  end

  it "returns only the principal's records and writes one row that explains why" do
    records = Reeve.invoke(
      tool: InvoiceSearchTool,
      arguments: { query: "A", customer_ssn: "123-45-6789" },
      principal: alice,
      agent: { id: "claude-desktop", name: "Claude" }
    )

    expect(records.map(&:number)).to contain_exactly("A-0", "A-1")

    expect(entry.outcome).to eq("allow")
    expect(entry.rule).to eq("InvoicePolicy#index")
    expect(entry.tool_name).to eq("invoice_search_tool")
    expect(entry.principal_id).to eq(alice.id.to_s)
    expect(entry.agent_id).to eq("claude-desktop")
    expect(entry.record_type).to eq("Invoice")
    expect(entry.record_count).to eq(2)
    expect(entry.record_ids.size).to eq(2)
  end

  # The per-tool `redact` declaration lives in the authorization registry and is applied
  # by the audit redactor. Nothing but this spec crosses that boundary.
  it "redacts the argument the tool declared, keeping the name" do
    Reeve.invoke(
      tool: InvoiceSearchTool,
      arguments: { query: "A", customer_ssn: "123-45-6789" },
      principal: alice
    )

    expect(entry.arguments.keys).to include("customer_ssn")
    expect(entry.arguments["customer_ssn"]).not_to include("123-45")
    expect(entry.arguments["query"]).to eq("A")
  end

  it "records a denial with the rule that denied it, and returns nothing" do
    stub_const("UnguardedTool", Class.new do
      include Reeve::Guard

      def call = Invoice.all
    end)

    expect { Reeve.invoke(tool: UnguardedTool, principal: alice) }
      .to raise_error(Reeve::DeniedError)

    expect(entry.outcome).to eq("deny")
    expect(entry.rule).to eq("no_guard_declared")
    expect(entry.record_ids).to eq([])
  end

  # R5: the invocations most worth a trace are the ones that blew up.
  it "keeps the row when the tool body raises inside a transaction" do
    stub_const("BrokenTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy

      def call
        Invoice.transaction do
          Invoice.create!(number: "rolled-back", owner_id: 1)
          raise ArgumentError, "bad query"
        end
      end
    end)

    expect { Reeve.invoke(tool: BrokenTool, principal: alice) }
      .to raise_error(ArgumentError, "bad query")

    expect(Invoice.where(number: "rolled-back")).to be_empty
    expect(entry.rule).to eq("tool_error")
    expect(entry.outcome).to eq("deny")
  end

  # Without this column the row says "policy_error" and nothing else, which is the least
  # useful moment to have to go and reproduce the failure by hand.
  it "records why the rule fired, not only that it did" do
    stub_const("ExplodingPolicy", Class.new do
      def self.name = "ExplodingPolicy"
      def self.authorize(*) = raise(ArgumentError, "owner_id is missing")
      def self.scope(_principal, relation) = relation
    end)
    stub_const("ExplodingTool", Class.new do
      include Reeve::Guard

      guard_with ExplodingPolicy
      def call = Invoice.all
    end)

    expect { Reeve.invoke(tool: ExplodingTool, principal: alice) }
      .to raise_error(Reeve::DeniedError)

    expect(entry.rule).to eq("policy_error")
    expect(entry.detail).to include("ArgumentError")
    expect(entry.detail).to include("owner_id is missing")
  end

  it "keeps the detail of an out-of-scope denial free of the record it refused" do
    bobs = Invoice.find_by(number: "B-0")
    stub_const("ShowTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy
      def call(id:) = Invoice.find(id)
    end)

    expect { Reeve.invoke(tool: ShowTool, arguments: { id: bobs.id }, principal: alice) }
      .to raise_error(Reeve::DeniedError)

    expect(entry.rule).to eq("out_of_scope_record")
    expect(entry.detail.to_s).not_to include(bobs.number)
    expect(entry.detail.to_s).not_to include(bobs.id.to_s)
  end

  it "is queryable along the axes an incident is investigated by" do
    Reeve.invoke(tool: InvoiceSearchTool, arguments: { query: "A" },
                 principal: alice, agent: { id: "claude-desktop" })

    expect(Reeve::Audit::Query.for_principal(alice).count).to eq(1)
    expect(Reeve::Audit::Query.for_agent("claude-desktop").count).to eq(1)
    expect(Reeve::Audit::Query.for_tool("invoice_search_tool").count).to eq(1)
    expect(Reeve::Audit::Query.for_principal(bob).count).to eq(0)
  end
end
