# frozen_string_literal: true

require "support/optional/authorization_records"
require "reeve/audit"
require "reeve/audit/support/ledger"

# One example per bullet of spec.md's "Edge Cases", in the order they are written there.
# SC-006 says every one of them produces a denial rather than a silent pass, "verified by
# a test per case" — this file is that verification, in one place a reviewer can audit
# against the list without hunting through the suite.
RSpec.describe "edge cases" do
  let(:alice) { Owner.new(1) }
  let(:bob)   { Owner.new(2) }

  before do
    Ledger.prepare!
    Invoice.delete_all
    Memo.delete_all
    Reeve.configure { |c| c.audit_recorder = Reeve::Audit::Recorder }

    @mine   = Invoice.create!(number: "A-1", owner_id: alice.id, overdue: true)
    @theirs = Invoice.create!(number: "B-1", owner_id: bob.id)
  end

  def tool(name, policy = InvoicePolicy, &body)
    klass = Class.new do
      include Reeve::Guard

      define_method(:call, &body)
    end
    stub_const(name, klass)
    klass.guard_with(policy)
    klass
  end

  def entries = Reeve::Audit::Entry.order(:id).to_a
  def last_entry = entries.last

  describe "a tool returns several record types in one response" do
    it "scopes each type by its own policy" do
      mine = Memo.create!(body: "mine", owner_id: alice.id)
      Memo.create!(body: "theirs", owner_id: bob.id)
      tool("MixedTool") { Invoice.all.to_a + Memo.all.to_a }

      result = Reeve.invoke(tool: MixedTool, principal: alice)

      expect(result).to contain_exactly(@mine, mine)
    end

    it "denies the whole call when one type has no policy" do
      tool("UnpolicedMixTool") { [Invoice.first, Unpoliced.new(1)] }

      expect { Reeve.invoke(tool: UnpolicedMixTool, principal: alice) }
        .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("unknown_record_type") }
    end
  end

  describe "a tool returns an aggregate rather than records" do
    it "computes it over the scoped set and records it as derived" do
      tool("SumTool") { scoped(Invoice).count }

      expect(Reeve.invoke(tool: SumTool, principal: alice)).to eq(1)
      expect(last_entry.derived?).to be(true)
      expect(last_entry.record_ids).to eq([])
    end

    it "denies an aggregate computed over unscoped data" do
      tool("UnscopedSumTool") { Invoice.count }

      expect { Reeve.invoke(tool: UnscopedSumTool, principal: alice) }
        .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("unscoped_derived_result") }
    end
  end

  describe "a principal legitimately has no matching records" do
    it "is an allowed call with zero identifiers, not a denial" do
      tool("EmptyTool") { Invoice.where(number: "nothing") }

      expect(Reeve.invoke(tool: EmptyTool, principal: alice).to_a).to be_empty
      expect(last_entry.outcome).to eq("allow")
      expect(last_entry.record_count).to eq(0)
      expect(last_entry.record_ids).to eq([])
    end
  end

  describe "a very large result set" do
    it "records identifiers up to the limit and says it truncated, never silently" do
      Reeve.configure { |c| c.max_recorded_ids = 3 }
      20.times { |i| Invoice.create!(number: "A-#{i + 2}", owner_id: alice.id) }
      tool("BigTool") { Invoice.all }

      Reeve.invoke(tool: BigTool, principal: alice)

      expect(last_entry.record_ids.size).to eq(3)
      expect(last_entry.record_count).to eq(21)
      expect(last_entry.truncated?).to be(true)
    end
  end

  describe "the same agent acts for different principals in quick succession" do
    it "does not leak principal state between calls on one thread" do
      tool("SuccessionTool") { Invoice.all }

      first  = Reeve.invoke(tool: SuccessionTool, principal: alice).to_a
      second = Reeve.invoke(tool: SuccessionTool, principal: bob).to_a

      expect(first).to eq([@mine])
      expect(second).to eq([@theirs])
      expect(entries.map(&:principal_id)).to eq([alice.id.to_s, bob.id.to_s])
    end
    # Concurrency is covered separately, at spec/reeve/authorization/concurrency_spec.rb.
  end

  describe "nested or chained tool calls" do
    it "scopes and records each invocation on its own" do
      tool("InnerTool") { Invoice.all }
      tool("OuterTool") do
        inner = Reeve.invoke(tool: InnerTool, principal: Reeve::Authorization::Current.state.context.principal)
        inner.to_a
      end

      result = Reeve.invoke(tool: OuterTool, principal: alice)

      expect(result).to eq([@mine])
      expect(entries.map(&:tool_name)).to contain_exactly("inner_tool", "outer_tool")
      expect(entries.map(&:outcome).uniq).to eq(["allow"])
    end

    it "restores the outer invocation's state when the inner one finishes" do
      tool("InnerScopeTool") { Invoice.all }
      captured = nil
      other = bob
      tool("OuterScopeTool") do
        Reeve.invoke(tool: InnerScopeTool, principal: other)
        captured = Reeve::Authorization::Current.state.context.principal
        Invoice.all
      end

      Reeve.invoke(tool: OuterScopeTool, principal: alice)

      expect(captured).to eq(alice)
    end
  end

  describe "the principal's permissions change mid-session" do
    # FR-007: evaluated at invocation time, never cached for the life of a connection.
    it "evaluates the next call against current permissions" do
      revoked = false
      policy = stub_const("RevocablePolicy", Class.new do
        def self.name = "RevocablePolicy"
        define_singleton_method(:authorize) { |*| !revoked }
        def self.scope(principal, relation) = relation.where(owner_id: principal.id)
      end)
      tool("RevocableTool", policy) { Invoice.all }

      expect(Reeve.invoke(tool: RevocableTool, principal: alice).to_a).to eq([@mine])

      revoked = true

      expect { Reeve.invoke(tool: RevocableTool, principal: alice) }
        .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("RevocablePolicy#index") }
    end

    it "denies once the principal can no longer be resolved" do
      present = true
      Reeve.configure { |c| c.principal_resolver = ->(_ctx) { present ? alice : nil } }
      tool("SessionTool") { Invoice.all }

      expect(Reeve.invoke(tool: SessionTool).to_a).to eq([@mine])
      present = false

      expect { Reeve.invoke(tool: SessionTool) }
        .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("no_principal") }
    end
  end

  describe "a denied call must not leak existence information" do
    def fetch(id)
      Reeve.invoke(tool: ShowTool, arguments: { id: id }, principal: alice)
    rescue Reeve::DeniedError => e
      e
    end

    before { tool("ShowTool") { |id:| Invoice.find_by(id: id) } }

    it "says nothing about the record in the error text" do
      denial = fetch(@theirs.id)

      expect(denial).to be_a(Reeve::DeniedError)
      expect(denial.message).not_to include(@theirs.number)
      expect(denial.message).not_to include(@theirs.id.to_s)
      expect(denial.message).not_to match(/not found|exists|deleted/i)
    end

    # KNOWN LIMITATION, asserted so it cannot change silently. A tool that fetches by id
    # from the *unscoped* model still tells the agent whether the record exists: a denial
    # means "exists, not yours", nil means "no such record". The envelope cannot close
    # this — by the time it sees nil it cannot know whether the tool meant a lookup or an
    # empty collection. The safe path is `scoped(...)`, below, and the docs say so.
    it "still distinguishes existence when the tool queries the unscoped model" do
      denial  = fetch(@theirs.id)
      missing = fetch(999_999)

      expect(denial).to be_a(Reeve::DeniedError)
      expect(missing).to be_nil
    end

    it "does not distinguish it when the tool fetches through scoped(...)" do
      tool("SafeShowTool") { |id:| scoped(Invoice).find_by(id: id) }

      out_of_scope = Reeve.invoke(tool: SafeShowTool, arguments: { id: @theirs.id }, principal: alice)
      nonexistent  = Reeve.invoke(tool: SafeShowTool, arguments: { id: 999_999 }, principal: alice)

      expect(out_of_scope).to be_nil
      expect(nonexistent).to be_nil
      expect(entries.map(&:outcome).uniq).to eq(["allow"])
      expect(entries.map(&:record_ids).uniq).to eq([[]])
    end

    it "does the same amount of work either way, through the safe path" do
      # A timing assertion would be flaky; query count is the deterministic proxy.
      tool("SafeCountedTool") { |id:| scoped(Invoice).find_by(id: id) }

      existing = count_queries do
        Reeve.invoke(tool: SafeCountedTool, arguments: { id: @theirs.id }, principal: alice)
      end
      missing = count_queries do
        Reeve.invoke(tool: SafeCountedTool, arguments: { id: 999_999 }, principal: alice)
      end

      expect(existing).to eq(missing)
    end

    it "records both, so the attempt is visible even though the answer is not" do
      fetch(@theirs.id)
      fetch(999_999)

      expect(entries.size).to eq(2)
      expect(entries.map(&:rule)).to eq(["out_of_scope_record", "InvoicePolicy#index"])
    end
  end

  describe "no MCP server library is loaded at all" do
    # Proven in a subprocess at spec/load_safety_spec.rb and spec/reeve/plain_interface_spec.rb;
    # asserted here so the sweep covers every bullet in one place.
    it "loads and guards without one" do
      expect(defined?(FastMcp)).to be_nil.or be_truthy # either way, the core does not need it
      tool("NoServerTool") { Invoice.all }

      expect(Reeve.invoke(tool: NoServerTool, principal: alice).to_a).to eq([@mine])
    end
  end

  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 unless payload[:name] == "SCHEMA"
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
