# frozen_string_literal: true

require "support/optional/authorization_records"

RSpec.describe Reeve::Authorization::Scoper do
  subject(:scoper) { described_class.new }

  let(:alice) { Owner.new(1) }
  let(:bob)   { Owner.new(2) }

  let(:tool_class) do
    Class.new do
      include Reeve::Guard

      def self.name = "InvoiceSearchTool"
    end
  end

  let(:guard) do
    tool_class.guard_with(InvoicePolicy)
    tool_class.reeve_guard
  end

  let(:context) { Reeve::Context.new(tool_name: "invoice_search_tool", principal: alice) }

  before do
    Invoice.delete_all
    Memo.delete_all
    @alice_invoice = Invoice.create!(number: "A-1", owner_id: alice.id, overdue: true)
    @bob_invoice   = Invoice.create!(number: "B-1", owner_id: bob.id)
  end

  def scope(result, ctx = context)
    scoper.scope(context: ctx, guard: guard, result: result)
  end

  describe "an ActiveRecord relation" do
    it "returns only the principal's records" do
      result = scope(Invoice.all)

      expect(result).to be_allowed
      expect(result.records.to_a).to eq([@alice_invoice])
    end

    it "does not leak another principal's records, even when the tool asked for all" do
      result = scope(Invoice.where(number: "B-1"))

      expect(result.records.to_a).to be_empty
      expect(result.record_ids).to be_empty
    end

    it "records the type, the identifiers and the count" do
      result = scope(Invoice.all)

      expect(result.record_type).to eq("Invoice")
      expect(result.record_ids).to eq([@alice_invoice.id.to_s])
      expect(result.record_count).to eq(1)
      expect(result).not_to be_truncated
      expect(result).not_to be_derived
    end

    it "truncates the recorded identifiers but keeps the count true (FR-014)" do
      Reeve.configure { |c| c.max_recorded_ids = 2 }
      5.times { |i| Invoice.create!(number: "A-#{i + 2}", owner_id: alice.id) }

      result = scope(Invoice.all)

      expect(result.record_ids.size).to eq(2)
      expect(result.record_count).to eq(6)
      expect(result).to be_truncated
    end
  end

  describe "an array of records" do
    it "removes the records outside the principal's scope" do
      result = scope([@alice_invoice, @bob_invoice])

      expect(result).to be_allowed
      expect(result.records).to eq([@alice_invoice])
      expect(result.record_ids).to eq([@alice_invoice.id.to_s])
    end

    it "allows an empty array with a count of zero — not a denial" do
      result = scope([])

      expect(result).to be_allowed
      expect(result.record_count).to eq(0)
      expect(result.records).to eq([])
    end
  end

  describe "a single record" do
    it "returns it when the principal may see it" do
      result = scope(@alice_invoice)

      expect(result).to be_allowed
      expect(result.records).to eq(@alice_invoice)
      expect(result.record_ids).to eq([@alice_invoice.id.to_s])
    end

    # FR-006: never returned, and never distinguishable from "no such record".
    it "denies with out_of_scope_record when the principal may not" do
      result = scope(@bob_invoice)

      expect(result).to be_denied
      expect(result.decision.rule).to eq("out_of_scope_record")
      expect(result.records).to be_nil
    end

    it "says nothing about the record in the denial" do
      result = scope(@bob_invoice)
      rendered = [result.decision.rule, result.decision.detail, result.record_ids].join(" ")

      expect(rendered).not_to include(@bob_invoice.id.to_s)
      expect(rendered).not_to include("B-1")
    end
  end

  # A declaration is an instruction, not a hint. Reeve once inferred a policy from the
  # record's class name whenever the declared policy was not named for that class, which
  # meant `guard_with LeakyPolicy` on a tool returning invoices was silently enforced by
  # InvoicePolicy — the guard the developer declared was not the guard that ran, and the
  # testing kit reported green.
  describe "which policy actually governs" do
    let(:permissive) do
      stub_const("PermissivePolicy", Class.new do
        def self.name = "PermissivePolicy"
        def self.authorize(*) = true
        def self.scope(_principal, relation) = relation
      end)
    end

    let(:guard) do
      tool_class.guard_with(permissive)
      tool_class.reeve_guard
    end

    it "uses the declared policy even when its name matches no model" do
      expect(described_class.policy_for(Reeve::Authorization::Adapters::Plain.new, guard, Invoice))
        .to eq(permissive)
    end

    it "returns what that policy permits, rather than what a same-named policy would" do
      result = scope(Invoice.all)

      expect(result).to be_allowed
      expect(result.records.to_a).to contain_exactly(@alice_invoice, @bob_invoice)
    end
  end

  describe "mixed record types" do
    it "scopes each type by its own policy" do
      alice_memo = Memo.create!(body: "mine", owner_id: alice.id)
      bob_memo = Memo.create!(body: "not mine", owner_id: bob.id)

      result = scope([@alice_invoice, @bob_invoice, alice_memo, bob_memo])

      expect(result).to be_allowed
      expect(result.records).to contain_exactly(@alice_invoice, alice_memo)
    end

    it "denies the whole call when one type has no policy" do
      result = scope([@alice_invoice, Unpoliced.new(9)])

      expect(result).to be_denied
      expect(result.decision.rule).to eq("unknown_record_type")
      expect(result.records).to be_nil
    end
  end

  describe "records that are not ActiveRecord" do
    # The core must work without a database at all; a plain object with an identity is
    # a record, whatever class it came from.
    it "treats a Struct with an id as a record, not as a derived value" do
      stub_const("PlainRecord", Struct.new(:id, :owner_id))
      stub_const("PlainRecordPolicy", Class.new do
        def self.name = "PlainRecordPolicy"
        def self.authorize(principal, _action, record) = record.nil? || record.owner_id == principal.id
        def self.scope(principal, relation) = relation.select { |r| r.owner_id == principal.id }
      end)
      tool_class.guard_with(PlainRecordPolicy)

      result = scoper.scope(
        context: context, guard: tool_class.reeve_guard,
        result: [PlainRecord.new(1, alice.id), PlainRecord.new(2, bob.id)]
      )

      expect(result).to be_allowed
      expect(result).not_to be_derived
      expect(result.records.map(&:id)).to eq([1])
    end
  end

  describe "a derived value" do
    # R4: safe only when the tool asked for the scoped relation rather than the model.
    it "denies a count the tool computed without scoped(...)" do
      result = scope(Invoice.count)

      expect(result).to be_denied
      expect(result.decision.rule).to eq("unscoped_derived_result")
    end

    it "denies a string, a hash and a symbol just the same" do
      %w[summary].push({ total: 3 }, :ok).each do |value|
        expect(scope(value).decision.rule).to eq("unscoped_derived_result")
      end
    end

    it "allows a value derived from scoped(...), recorded as derived" do
      state = Reeve::Authorization::Current.start(
        context: context, declaration: guard, adapter: Reeve::Authorization::Adapters::Plain.new
      )
      begin
        tool = tool_class.new
        count = tool.scoped(Invoice).count
        result = scope(count)

        expect(count).to eq(1)
        expect(result).to be_allowed
        expect(result).to be_derived
        expect(result.records).to eq(1)
        expect(result.record_ids).to be_empty
        expect(result.record_count).to eq(1)
      ensure
        Reeve::Authorization::Current.finish(state)
      end
    end
  end

  describe "nil and empty results" do
    it "allows nil with a count of zero" do
      result = scope(nil)

      expect(result).to be_allowed
      expect(result.record_count).to eq(0)
    end

    it "allows an empty relation" do
      result = scope(Invoice.where(number: "nothing"))

      expect(result).to be_allowed
      expect(result.record_count).to eq(0)
      expect(result.record_ids).to be_empty
    end
  end

  describe "#scoped" do
    around do |example|
      state = Reeve::Authorization::Current.start(
        context: context, declaration: guard, adapter: Reeve::Authorization::Adapters::Plain.new
      )
      example.run
      Reeve::Authorization::Current.finish(state)
    end

    it "narrows a model to the principal's records" do
      expect(tool_class.new.scoped(Invoice).to_a).to eq([@alice_invoice])
    end

    it "narrows a relation the tool already filtered" do
      expect(tool_class.new.scoped(Invoice.where(overdue: true)).to_a).to eq([@alice_invoice])
    end

    it "marks the invocation as having scoped, and remembers how much" do
      tool_class.new.scoped(Invoice).to_a
      state = Reeve::Authorization::Current.state

      expect(state).to be_scoped_used
      expect(state.scoped_source_count).to eq(1)
    end

    it "raises when the type has no policy, rather than returning everything" do
      expect { tool_class.new.scoped(Unpoliced) }.to raise_error(Reeve::Error, /policy/)
    end
  end

  it "refuses to scope outside an invocation" do
    expect { tool_class.new.scoped(Invoice) }
      .to raise_error(Reeve::Error, /only be called inside a guarded invocation/)
  end
end
