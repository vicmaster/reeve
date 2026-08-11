# frozen_string_literal: true

require_relative "support/envelope"

# T034 / FR-012. A ledger write that fails silently is worse than no ledger at all: the
# host believes it has a trace it does not have. The default is therefore to fail the
# call, and running without that safety net takes an explicit opt-in.
#
# The ledger is broken the way it actually breaks — the table is not there — rather than
# by stubbing the recorder, so what is pinned is the real write path's behavior.
RSpec.describe "a ledger that cannot be written" do
  include Envelope

  before do
    Ledger.prepare!
    Ledger.migrate_down!
  end

  after { Ledger.prepare! }

  it "defaults to failing the call, with no opt-in required for the safe mode" do
    expect(Reeve.config.audit_failure_mode).to eq(:fail)
  end

  it "fails the invocation and names the invocation that went unrecorded" do
    expect { invoke(invocation_id: "abc-123") { %w[a b] } }
      .to raise_error(Reeve::AuditWriteError, /abc-123/)
  end

  it "carries the underlying database error, so the cause is diagnosable" do
    error = nil
    begin
      invoke { [] }
    rescue Reeve::AuditWriteError => e
      error = e
    end

    expect(error.original_error).to be_a(ActiveRecord::StatementInvalid)
  end

  describe "with the degraded mode explicitly opted into" do
    let(:logger) { CapturingLogger.new }

    before do
      Reeve.config.audit_failure_mode = :warn
      Reeve.config.logger = logger
    end

    it "logs and lets the call through" do
      result = invoke(invocation_id: "abc-123") { %w[a b] }

      expect(result).to eq(%w[a b])
      expect(logger.warnings.join).to include("abc-123")
    end
  end

  describe "when something is already on its way out" do
    # These two originally asserted the opposite — that an exception already in flight
    # kept its place and the audit failure was swallowed. A code review showed what that
    # cost: denials and tool errors are most of what a ledger is consulted about, so a
    # broken ledger stayed invisible for exactly those calls, in the default mode, with
    # nothing raised. Constitution II is unconditional, so the audit error now wins and
    # carries the original.
    it "fails with an audit error that carries the tool's own exception" do
      expect { invoke { raise "kaboom" } }.to raise_error(Reeve::AuditWriteError) { |error|
        expect(error.during).to be_a(RuntimeError)
        expect(error.during.message).to eq("kaboom")
        expect(error.message).to include("kaboom")
      }
    end

    it "fails with an audit error that carries the denial" do
      denial = Reeve::Decision.deny(rule: "InvoicePolicy#index?")

      expect { invoke(decision: denial) }.to raise_error(Reeve::AuditWriteError) { |error|
        expect(error.during).to be_a(Reeve::DeniedError)
        expect(error.during.rule).to eq("InvoicePolicy#index?")
      }
    end

    it "still lets both through untouched in the opt-in :warn mode" do
      Reeve.configure { |c| c.audit_failure_mode = :warn }
      denial = Reeve::Decision.deny(rule: "InvoicePolicy#index?")

      expect { invoke(decision: denial) }.to raise_error(Reeve::DeniedError)
      expect { invoke { raise "kaboom" } }.to raise_error(RuntimeError, "kaboom")
    end
  end
end
