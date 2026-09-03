# frozen_string_literal: true

require "support/optional/authorization_records"
require "reeve/audit"
require "reeve/audit/support/ledger"

# What a denial means for a tool that writes.
#
# The envelope authorizes before the tool runs, with the class as the subject because no
# record exists yet, and scopes what comes back afterwards. A write tool lives between
# those two points: it fetched a record, changed it, and only then was refused. Until
# 0.4.0 the change stayed and the ledger said `deny` — a false statement in the artifact
# the ledger exists to be.
RSpec.describe "a guarded tool that writes" do
  let(:alice) { Owner.new(1) }
  let(:bob)   { Owner.new(2) }

  before do
    Ledger.prepare!
    Invoice.delete_all
    Reeve.configure { |c| c.audit_recorder = Reeve::Audit::Recorder }

    stub_const("RenameInvoiceTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy, action: :update

      # The shape a developer writes first, and the one an agent produces by copying a
      # read tool: fetch unscoped, mutate, return.
      def call(id:, number:)
        invoice = Invoice.find(id)
        invoice.update!(number: number)
        invoice
      end
    end)
  end

  def entry
    Reeve::Audit::Entry.last
  end

  describe "when the record belongs to someone else" do
    let!(:theirs) { Invoice.create!(number: "BOB-ORIGINAL", owner_id: bob.id) }

    def attempt
      Reeve.invoke(tool: RenameInvoiceTool, principal: alice,
                   arguments: { id: theirs.id, number: "ALICE-WAS-HERE" })
    end

    it "denies the call" do
      expect { attempt }.to raise_error(Reeve::DeniedError, /out_of_scope_record/)
    end

    # The point of the release.
    it "leaves the record as it was, so the denial is true" do
      expect { attempt }.to raise_error(Reeve::DeniedError)

      expect(theirs.reload.number).to eq("BOB-ORIGINAL")
    end

    it "records the denial with the rule that refused" do
      expect { attempt }.to raise_error(Reeve::DeniedError)

      expect(entry).to be_denied
      expect(entry.rule).to eq(Reeve::Decision::OUT_OF_SCOPE_RECORD)
    end
  end

  describe "when the record is the principal's own" do
    let!(:mine) { Invoice.create!(number: "ALICE-ORIGINAL", owner_id: alice.id) }

    it "commits the write and records an allow" do
      Reeve.invoke(tool: RenameInvoiceTool, principal: alice,
                   arguments: { id: mine.id, number: "ALICE-RENAMED" })

      expect(mine.reload.number).to eq("ALICE-RENAMED")
      expect(entry).to be_allowed
    end
  end

  # A tool that raised had already been recorded as a denial; its half-finished writes
  # staying behind made the row wrong in the same way.
  it "undoes a partial write when the tool raises" do
    stub_const("HalfwayTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy, action: :update

      def call
        Invoice.create!(number: "PARTIAL", owner_id: 1)
        raise "kaboom"
      end
    end)

    expect { Reeve.invoke(tool: HalfwayTool, principal: alice) }
      .to raise_error(RuntimeError, "kaboom")

    expect(Invoice.where(number: "PARTIAL")).to be_empty
    expect(entry.rule).to eq(Reeve::Decision::TOOL_ERROR)
  end

  # `requires_new` is what makes this a savepoint: the rollback has to reach the tool's
  # work and stop there, or a guarded call would silently undo the request around it.
  it "does not take work the host did in its own transaction" do
    theirs = Invoice.create!(number: "BOB-ORIGINAL", owner_id: bob.id)

    ActiveRecord::Base.transaction do
      Invoice.create!(number: "HOST-WORK", owner_id: alice.id)

      expect do
        Reeve.invoke(tool: RenameInvoiceTool, principal: alice,
                     arguments: { id: theirs.id, number: "NOPE" })
      end.to raise_error(Reeve::DeniedError)

      expect(Invoice.where(number: "HOST-WORK")).to exist
      expect(theirs.reload.number).to eq("BOB-ORIGINAL")
    end
  end
end

# `authorize!` is for the part of a tool a rollback cannot reach.
RSpec.describe "authorize! inside a tool body" do
  let(:alice) { Owner.new(1) }
  let(:bob)   { Owner.new(2) }

  before do
    Ledger.prepare!
    Invoice.delete_all
    Reeve.configure { |c| c.audit_recorder = Reeve::Audit::Recorder }

    # Stands in for the thing the database cannot take back: a sent email, a webhook.
    stub_const("Outbox", [])

    stub_const("NotifyTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy, action: :update

      def call(id:)
        invoice = authorize!(Invoice.find(id))
        Outbox << invoice.number
        invoice
      end
    end)
  end

  it "lets the tool act when the policy allows it" do
    mine = Invoice.create!(number: "MINE", owner_id: alice.id)

    Reeve.invoke(tool: NotifyTool, principal: alice, arguments: { id: mine.id })

    expect(Outbox).to eq(["MINE"])
  end

  it "stops the tool before the side effect the envelope could not undo" do
    theirs = Invoice.create!(number: "THEIRS", owner_id: bob.id)

    expect { Reeve.invoke(tool: NotifyTool, principal: alice, arguments: { id: theirs.id }) }
      .to raise_error(Reeve::DeniedError)

    expect(Outbox).to be_empty
  end

  # The reason this is not just `raise` in the tool: a policy saying no is an
  # authorization outcome, and filing it as `tool_error` puts it in the same bucket as a
  # NoMethodError for anyone reading the ledger afterwards.
  it "records the policy's own rule rather than a tool error" do
    theirs = Invoice.create!(number: "THEIRS", owner_id: bob.id)

    expect { Reeve.invoke(tool: NotifyTool, principal: alice, arguments: { id: theirs.id }) }
      .to raise_error(Reeve::DeniedError)

    entry = Reeve::Audit::Entry.last
    expect(entry).to be_denied
    expect(entry.rule).to eq("InvoicePolicy#update")
    expect(entry.rule).not_to eq(Reeve::Decision::TOOL_ERROR)
  end

  it "names no record, so a refusal and a missing record read the same" do
    theirs = Invoice.create!(number: "THEIRS", owner_id: bob.id)

    raised = nil
    begin
      Reeve.invoke(tool: NotifyTool, principal: alice, arguments: { id: theirs.id })
    rescue Reeve::DeniedError => e
      raised = e
    end

    expect(raised).not_to be_nil, "expected the call to be denied"
    expect(raised.message).not_to include("THEIRS")
    expect(raised.message).not_to include(theirs.id.to_s)
  end

  it "refuses to run outside a guarded invocation" do
    klass = Class.new { include Reeve::Guard }

    expect { klass.new.authorize!(Object.new) }
      .to raise_error(Reeve::Error, /only be called inside a guarded invocation/)
  end
end
