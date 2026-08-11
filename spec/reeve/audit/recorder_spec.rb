# frozen_string_literal: true

require_relative "support/envelope"

# T031, T033, T039 / FR-008, FR-009, FR-011, FR-014.
#
# Constitution II in one file: every guarded call leaves exactly one row, allowed or
# denied, and that row explains itself. The specs drive the real envelope so that what is
# pinned is what a host actually gets, not what the recorder would do if called correctly.
RSpec.describe Reeve::Audit::Recorder do
  include Envelope

  before { Ledger.prepare! }

  describe "one row per invocation (FR-008)" do
    it "records an allowed call" do
      invoke(arguments: { query: "acme" }) { %w[a b] }

      expect(entries.count).to eq(1)
      expect(only_entry).to be_allowed
      expect(only_entry.rule).to eq("InvoicePolicy#index?")
      expect(only_entry.guard).to eq("policy")
    end

    it "records a denied call as a row, not a log line" do
      denial = Reeve::Decision.deny(rule: "InvoicePolicy#index?", detail: "not the owner")

      expect { invoke(decision: denial) }.to raise_error(Reeve::DeniedError)

      expect(entries.count).to eq(1)
      expect(only_entry).to be_denied
      expect(only_entry.rule).to eq("InvoicePolicy#index?")
    end

    it "records a call with no principal, where there is no principal to record" do
      expect { invoke(principal: nil) }.to raise_error(Reeve::DeniedError)

      expect(only_entry.rule).to eq(Reeve::Decision::NO_PRINCIPAL)
      expect(only_entry.principal_id).to be_nil
      expect(only_entry.principal_type).to be_nil
    end

    it "never writes a row without a rule (FR-009)" do
      invoke { [] }
      expect { invoke(principal: nil) }.to raise_error(Reeve::DeniedError)

      expect(entries.pluck(:rule)).to all(be_present)
    end

    it "treats a replayed invocation_id as a no-op rather than a second row" do
      attributes = {
        invocation_id: "fixed-id", occurred_at: Time.now, agent_id: "a",
        tool_name: "T", arguments: {}, outcome: "allow", rule: "r",
        record_ids: [], record_count: 0, guard: "policy"
      }

      first = described_class.record(attributes)
      second = described_class.record(attributes)

      expect(entries.count).to eq(1)
      expect(second.id).to eq(first.id)
    end
  end

  describe "what the row says" do
    it "carries the agent, principal, tool and timing the envelope saw" do
      invoked_at = Time.now - 120

      invoke(invoked_at: invoked_at, principal: Envelope::Principal.new(42)) { [] }

      entry = only_entry
      expect(entry.agent_id).to eq("claude-desktop")
      expect(entry.agent_name).to eq("Claude Desktop")
      expect(entry.principal_type).to eq("Envelope::Principal")
      expect(entry.principal_id).to eq("42")
      expect(entry.tool_name).to eq("InvoiceSearchTool")
      expect(entry.duration_ms).to be >= 0
    end

    it "stamps occurred_at with the invocation time, not the write time" do
      invoked_at = Time.now - 3600

      invoke(invoked_at: invoked_at) { [] }

      expect(only_entry.occurred_at).to be_within(2).of(invoked_at)
    end

    it "records the identifiers the scoper returned, and their type" do
      scope_result = Reeve::ScopeResult.allow(
        records: %i[stub], record_type: "Invoice", record_ids: [1, 2, 3]
      )

      invoke(scope_result: scope_result) { [] }

      expect(only_entry.record_type).to eq("Invoice")
      expect(only_entry.record_ids).to eq(%w[1 2 3])
      expect(only_entry.record_count).to eq(3)
      expect(only_entry.truncated).to be(false)
    end

    it "marks a derived result, which has no identifiers to record" do
      scope_result = Reeve::ScopeResult.allow(records: 42, derived: true, record_count: 9)

      invoke(scope_result: scope_result) { 42 }

      expect(only_entry.derived).to be(true)
      expect(only_entry.record_ids).to eq([])
      expect(only_entry.record_type).to be_nil
    end

    it "records the arguments post-redaction, keeping the names (FR-011)" do
      Reeve.config.redact_arguments = %i[ssn]

      invoke(arguments: { query: "acme", ssn: "111-22-3333" }) { [] }

      expect(only_entry.arguments)
        .to eq("query" => "acme", "ssn" => Reeve::Audit::Redactor::MARKER)
    end

    it "records guard: none when the host allowed an unguarded tool (R9)" do
      Reeve.config.unguarded_tools = :allow_with_warning

      invoke(guard: nil) { [] }

      expect(only_entry.guard).to eq("none")
      expect(only_entry.rule).to eq(Reeve::Decision::UNGUARDED_TOOL)
      expect(only_entry).to be_allowed
    end

    it "records a tool that raised as a deny, since no records reached the agent" do
      expect { invoke { raise "kaboom" } }.to raise_error(RuntimeError, "kaboom")

      expect(only_entry).to be_denied
      expect(only_entry.rule).to eq(Reeve::Decision::TOOL_ERROR)
    end

    it "leaves metadata alone — the core never populates it" do
      invoke { [] }

      expect(only_entry.metadata).to be_nil
    end
  end

  describe "truncation (FR-014)" do
    before { Reeve.config.max_recorded_ids = 3 }

    it "caps the identifiers and says so, keeping the true count" do
      scope_result = Reeve::ScopeResult.allow(
        records: [], record_type: "Invoice", record_ids: (1..10).to_a
      )

      invoke(scope_result: scope_result) { [] }

      entry = only_entry
      expect(entry.record_ids).to eq(%w[1 2 3])
      expect(entry.record_count).to eq(10)
      expect(entry.truncated).to be(true)
    end

    it "keeps a count the scoper already knew to be larger than the list it sent" do
      scope_result = Reeve::ScopeResult.allow(
        records: [], record_type: "Invoice", record_ids: %w[1 2],
        record_count: 5_000, truncated: true
      )

      invoke(scope_result: scope_result) { [] }

      expect(only_entry.record_count).to eq(5_000)
      expect(only_entry.truncated).to be(true)
    end

    it "does not mark an entry truncated when nothing was dropped" do
      scope_result = Reeve::ScopeResult.allow(records: [], record_ids: %w[1 2])

      invoke(scope_result: scope_result) { [] }

      expect(only_entry.truncated).to be(false)
    end
  end

  # T039 / R5. The write is synchronous, in the envelope's ensure block, and in its own
  # transaction — deliberately not the tool's. The invocations most worth having a trace
  # of are the ones that blew up and took their own work down with them.
  describe "surviving the tool's rollback" do
    it "keeps the entry when the tool body rolls its work back" do
      scratch = Ledger.scratch

      expect do
        invoke do
          ActiveRecord::Base.transaction do
            scratch.create!(name: "written then rolled back")
            raise "kaboom"
          end
        end
      end.to raise_error(RuntimeError, "kaboom")

      expect(scratch.count).to eq(0)
      expect(entries.count).to eq(1)
      expect(only_entry.rule).to eq(Reeve::Decision::TOOL_ERROR)
    end

    # The honest limit from R5, pinned rather than papered over: on one connection, a
    # transaction the *caller* wrapped around the whole invocation still takes the row
    # with it when it rolls back. Closing that needs a second connection.
    it "does not survive a rollback of a transaction wrapped around the whole invocation" do
      ActiveRecord::Base.transaction do
        invoke { [] }
        raise ActiveRecord::Rollback
      end

      expect(entries.count).to eq(0)
    end

    it "records the call before the caller sees the exception" do
      seen = nil

      begin
        invoke { raise "kaboom" }
      rescue RuntimeError
        seen = Reeve::Audit::Entry.count
      end

      expect(seen).to eq(1)
    end
  end

  describe "the recorder as a collaborator" do
    it "is what an unconfigured recorder resolves to once reeve/audit is loaded" do
      Reeve::Audit.install!

      expect(Reeve.config.audit_recorder).to eq(described_class)
    end

    it "does not displace a recorder the host chose itself" do
      custom = FakeRecorder.new
      Reeve.config.audit_recorder = custom

      Reeve::Audit.install!

      expect(Reeve.config.audit_recorder).to be(custom)
    end
  end
  # Review finding: `requires_new: true` is a savepoint, so a transaction the *host* wraps
  # around the invocation takes the ledger row with it when it rolls back — while the
  # write reports success. Isolation is not portable (SQLite's enclosing transaction holds
  # the write lock, so a second connection just times out), so the recorder says so
  # instead of pretending otherwise.
  describe "when the host has wrapped the invocation in its own transaction" do
    let(:logger) { CapturingLogger.new }
    let(:attributes) do
      {
        invocation_id: "wrapped-1", occurred_at: Time.now, agent_id: "claude",
        tool_name: "invoice_search", arguments: {}, outcome: "allow",
        rule: "InvoicePolicy#index?", record_ids: [], record_count: 0, guard: "policy"
      }
    end

    before { Reeve.configure { |c| c.logger = logger } }

    it "warns that the row will not survive the enclosing rollback" do
      Reeve::Audit::Entry.transaction do
        described_class.record(attributes)
        raise ActiveRecord::Rollback
      end

      expect(logger.warnings.join).to match(/rolled back with it/)
      expect(logger.warnings.join).to include("audit_recorder")
    end

    it "names the invocation whose trace is at risk" do
      Reeve::Audit::Entry.transaction do
        described_class.record(attributes)
        raise ActiveRecord::Rollback
      end

      expect(logger.warnings.join).to include(attributes[:invocation_id])
    end

    it "does not warn when nothing encloses the write" do
      described_class.record(attributes)

      expect(logger.warnings).to be_empty
    end

    # Documenting the consequence rather than asserting a guarantee reeve cannot make.
    it "loses the row when that transaction rolls back — the reason for the warning" do
      Reeve::Audit::Entry.transaction do
        described_class.record(attributes)
        expect(Reeve::Audit::Entry.count).to eq(1)
        raise ActiveRecord::Rollback
      end

      expect(Reeve::Audit::Entry.count).to eq(0)
    end
  end
end
