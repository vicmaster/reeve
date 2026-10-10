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

# specs/002 T036 / FR-010, US3 — a contract-3 ledger that cannot be chained.
#
# Two ways a write can be refused before it reaches the chain: no key to sign with, or a
# table one contract behind the gem. Both go through audit_failure_mode like any other
# failed write, and neither may surface as a database error the host has to decode.
RSpec.describe "a ledger that cannot be chained" do
  include Envelope

  let(:logger) { CapturingLogger.new }
  let(:chain_columns) { %w[chain_sequence chain_key_id chain_digest] }

  before do
    Ledger.prepare!
    Reeve.config.logger = logger
  end

  describe "with no ledger key" do
    before { Reeve.config.ledger_key = nil }

    it "fails the call under :fail, with the key's absence as the cause" do
      expect { invoke(invocation_id: "inv-no-key") { %w[a] } }.to raise_error(Reeve::AuditWriteError) { |error|
        expect(error.original_error).to be_a(Reeve::LedgerKeyError)
        expect(error.message).to include("inv-no-key").and include("config.ledger_key")
      }
      expect(entries.count).to eq(0)
    end

    # :warn keeps calls running; it does not drop traces. The row is written, at contract
    # 3, with no chain — which verification reports — and the log says so every time.
    it "lets the call through under :warn, writing the row unchained and saying so each time" do
      Reeve.config.audit_failure_mode = :warn

      2.times { |i| expect(invoke(invocation_id: "inv-warn-#{i}") { %w[a] }).to eq(%w[a]) }

      expect(entries.count).to eq(2)
      expect(entries.pluck(*chain_columns)).to all(eq([nil, nil, nil]))
      expect(entries.pluck(:contract_version).uniq).to eq([Reeve::Audit::CONTRACT_VERSION])
      expect(logger.warnings.grep(/unchained/).size).to eq(2)
      expect(logger.warnings.join).to include("inv-warn-0").and include("config.ledger_key")
    end

    it "takes no chain lock and starts no chain while writing unchained" do
      Reeve.config.audit_failure_mode = :warn

      invoke { [] }

      expect(Reeve::Audit::ChainRecord.count).to eq(0)
    end
  end

  # A host that upgraded the gem and has not run reeve:upgrade yet.
  describe "on a table still at contract 2" do
    before do
      chain_columns.each { |column| ActiveRecord::Base.connection.remove_column(:reeve_audit_entries, column) }
      Reeve::Audit::Entry.reset_column_information
    end

    # Dropped rather than migrated down: the down migration expects the index this example
    # removed along with its column. prepare! rebuilds a missing ledger from the template.
    after do
      ActiveRecord::Base.connection.drop_table(:reeve_audit_entries, if_exists: true)
      Ledger.prepare!
    end

    it "names the missing upgrade and the command that performs it, not a column error" do
      expect { invoke { [] } }.to raise_error(Reeve::AuditWriteError) { |error|
        expect(error.original_error).to be_a(Reeve::ConfigurationError)
        expect(error.message).to include("reeve:upgrade").and include("chain_sequence")
        expect(error.original_error).not_to be_a(ActiveModel::UnknownAttributeError)
      }
    end

    it "under :warn lets the call through and writes nothing, as for any failed write" do
      Reeve.config.audit_failure_mode = :warn

      expect(invoke { %w[a] }).to eq(%w[a])
      expect(entries.count).to eq(0)
      expect(logger.warnings.join).to include("reeve:upgrade")
    end
  end
end
