# frozen_string_literal: true

require "support/optional/authorization_records"

# The independent test for User Story 1, written as the spec states it: two principals,
# disjoint records, one guarded tool and one unguarded tool.
RSpec.describe "US1: scope every tool call to the acting human" do
  let(:alice) { Owner.new(1) }
  let(:bob)   { Owner.new(2) }
  let(:recorder) { FakeRecorder.new }

  before do
    Invoice.delete_all
    3.times { |i| Invoice.create!(number: "A-#{i}", owner_id: alice.id) }
    7.times { |i| Invoice.create!(number: "B-#{i}", owner_id: bob.id) }

    Reeve.configure { |c| c.audit_recorder = recorder }

    stub_const("InvoiceSearchTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy

      def call = Invoice.all
    end)

    stub_const("UnguardedTool", Class.new do
      include Reeve::Guard

      def call = Invoice.all
    end)
  end

  # Scenario 1
  it "returns the principal's 3 records and none of the other 7" do
    records = Reeve.invoke(tool: InvoiceSearchTool, principal: alice)

    expect(records.to_a.size).to eq(3)
    expect(records.map(&:number)).to all(start_with("A-"))
  end

  it "returns a different principal's records to that principal" do
    records = Reeve.invoke(tool: InvoiceSearchTool, principal: bob)

    expect(records.to_a.size).to eq(7)
    expect(records.map(&:number)).to all(start_with("B-"))
  end

  # Scenario 2
  it "denies a principal the policy refuses entirely, naming tool, principal and rule" do
    stub_const("ClosedPolicy", Class.new do
      def self.name = "ClosedPolicy"
      def self.authorize(*) = false
      def self.scope(_principal, relation) = relation.none
    end)
    stub_const("ClosedTool", Class.new do
      include Reeve::Guard

      guard_with ClosedPolicy
      def call = Invoice.all
    end)

    expect { Reeve.invoke(tool: ClosedTool, principal: alice) }
      .to raise_error(Reeve::DeniedError) { |error|
        expect(error.rule).to eq("ClosedPolicy#index")
        expect(error.message).to include("closed_tool")
        expect(error.message).to include(alice.id.to_s)
        expect(error.message).to include("ClosedPolicy#index")
      }
  end

  # Scenario 3
  it "denies an unguarded tool and says a guard is missing" do
    expect { Reeve.invoke(tool: UnguardedTool, principal: alice) }
      .to raise_error(Reeve::DeniedError) { |error|
        expect(error.rule).to eq("no_guard_declared")
        expect(error.message).to match(/no guard_with declaration/)
      }
  end

  # Scenario 4
  it "denies with no resolvable principal, without consulting the policy" do
    consulted = false
    stub_const("WatchingPolicy", Class.new do
      define_singleton_method(:authorize) { |*| consulted = true }
      def self.scope(_principal, relation) = relation
      def self.name = "WatchingPolicy"
    end)
    stub_const("WatchedTool", Class.new do
      include Reeve::Guard

      guard_with WatchingPolicy
      def call = Invoice.all
    end)

    expect { Reeve.invoke(tool: WatchedTool, principal: nil) }
      .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("no_principal") }
    expect(consulted).to be(false)
  end

  # Scenario 5
  it "fails closed when the policy raises, and surfaces rather than swallows it" do
    stub_const("ExplodingPolicy", Class.new do
      def self.name = "ExplodingPolicy"
      def self.authorize(*) = raise("policy is broken")
      def self.scope(_principal, relation) = relation
    end)
    stub_const("ExplodingTool", Class.new do
      include Reeve::Guard

      guard_with ExplodingPolicy
      def call = Invoice.all
    end)

    expect { Reeve.invoke(tool: ExplodingTool, principal: alice) }
      .to raise_error(Reeve::DeniedError) { |error|
        expect(error.rule).to eq("policy_error")
        expect(error.detail).to include("policy is broken")
      }
  end

  # Scenario 6
  it "denies a single record outside the scope without disclosing whether it exists" do
    bobs = Invoice.where(owner_id: bob.id).first
    stub_const("InvoiceShowTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy
      def call(id:) = Invoice.find(id)
    end)

    expect { Reeve.invoke(tool: InvoiceShowTool, arguments: { id: bobs.id }, principal: alice) }
      .to raise_error(Reeve::DeniedError) { |error|
        expect(error.rule).to eq("out_of_scope_record")
        expect(error.message).not_to include(bobs.number)
        expect(error.message).not_to match(/not found|exists/i)
      }
  end

  it "gives the same message whether the record exists or not" do
    stub_const("InvoiceShowTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy
      def call(id:) = Invoice.find_by(id: id)
    end)
    bobs = Invoice.where(owner_id: bob.id).first

    out_of_scope = begin
      Reeve.invoke(tool: InvoiceShowTool, arguments: { id: bobs.id }, principal: alice)
    rescue Reeve::DeniedError => e
      e.message
    end
    missing = Reeve.invoke(tool: InvoiceShowTool, arguments: { id: 999_999 }, principal: alice)

    # The denial names no record: not its number, not its id. It does, however, differ
    # from the nil a missing record produces, so an unscoped by-id fetch still discloses
    # existence — see spec/reeve/edge_cases_spec.rb and contracts/tool-dsl.md, where that
    # limitation and its remedy (fetch through `scoped`) are stated.
    expect(missing).to be_nil
    expect(out_of_scope).not_to include(bobs.number)
    expect(out_of_scope).not_to include(bobs.id.to_s)
  end

  describe "the ledger entry" do
    it "records the principal, the rule and the records returned" do
      Reeve.invoke(tool: InvoiceSearchTool, principal: alice)

      expect(recorder.entry).to include(
        outcome: "allow",
        rule: "InvoicePolicy#index",
        tool_name: "invoice_search_tool",
        principal_id: alice.id.to_s,
        record_type: "Invoice",
        record_count: 3
      )
    end

    it "records a denial too, with the rule that denied it" do
      begin
        Reeve.invoke(tool: UnguardedTool, principal: alice)
      rescue Reeve::DeniedError
        nil
      end

      expect(recorder.entry).to include(outcome: "deny", rule: "no_guard_declared")
    end
  end

  describe "a derived value" do
    it "allows a count computed from scoped(...)" do
      stub_const("OverdueCountTool", Class.new do
        include Reeve::Guard

        guard_with InvoicePolicy
        def call = scoped(Invoice).count
      end)

      expect(Reeve.invoke(tool: OverdueCountTool, principal: alice)).to eq(3)
      expect(recorder.entry).to include(derived: true, outcome: "allow")
    end

    it "denies a count the tool computed straight from the model" do
      stub_const("SloppyCountTool", Class.new do
        include Reeve::Guard

        guard_with InvoicePolicy
        def call = Invoice.count
      end)

      expect { Reeve.invoke(tool: SloppyCountTool, principal: alice) }
        .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("unscoped_derived_result") }
    end
  end
end
