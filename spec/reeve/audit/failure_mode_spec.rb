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
    it "does not mask the tool's own exception with an audit error" do
      expect { invoke { raise "kaboom" } }.to raise_error(RuntimeError, "kaboom")
    end

    it "does not turn a denial into an audit error" do
      denial = Reeve::Decision.deny(rule: "InvoicePolicy#index?")

      expect { invoke(decision: denial) }.to raise_error(Reeve::DeniedError)
    end
  end
end
