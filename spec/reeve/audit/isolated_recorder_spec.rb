# frozen_string_literal: true

require_relative "support/envelope"

# R5's honest limit, closed. `Recorder` writes in a savepoint, which survives a rollback
# by the tool and not one by the host; this recorder writes on a connection of its own, so
# nothing the host's transaction does can reach it.
#
# The interesting examples need a real transaction on one connection and a real commit on
# another, which SQLite cannot express — its write lock is database-wide, which is the
# same reason this recorder refuses to run there. They skip rather than pretend, and CI
# runs them on PostgreSQL and MySQL.
RSpec.describe Reeve::Audit::IsolatedRecorder do
  include Envelope

  before { Ledger.prepare! }

  describe "on a database that cannot support it" do
    before { skip("this database can support a second writer") unless SpecDatabase.sqlite? }

    it "refuses rather than blocking every call until the lock times out" do
      expect { described_class.verify_supported! }
        .to raise_error(Reeve::ConfigurationError, /cannot be used on sqlite/)
    end

    it "answers available? so a host can branch in an initializer" do
      expect(described_class.available?).to be(false)
    end
  end

  describe "on a database with concurrent writers" do
    before do
      skip("needs a server database — run with DB=postgresql or DB=mysql2") if SpecDatabase.sqlite?
    end

    it "is available" do
      expect(described_class.available?).to be(true)
    end

    # The whole point.
    it "keeps the row when the host rolls back a transaction wrapped around the call" do
      ActiveRecord::Base.transaction do
        invoke(recorder: described_class) { [] }
        raise ActiveRecord::Rollback
      end

      expect(entries.count).to eq(1)
      expect(only_entry.tool_name).to eq("InvoiceSearchTool")
    end

    # Same scenario, default recorder, so the difference is asserted rather than assumed.
    it "is the difference: the default recorder loses that row" do
      ActiveRecord::Base.transaction do
        invoke(recorder: Reeve::Audit::Recorder) { [] }
        raise ActiveRecord::Rollback
      end

      expect(entries.count).to eq(0)
    end

    it "records a denial through the host's rollback too" do
      ActiveRecord::Base.transaction do
        expect { invoke(recorder: described_class) { raise "kaboom" } }
          .to raise_error(RuntimeError, "kaboom")
        raise ActiveRecord::Rollback
      end

      expect(only_entry).to be_denied
      expect(only_entry.rule).to eq(Reeve::Decision::TOOL_ERROR)
    end

    it "still writes one row per invocation when the same one is replayed" do
      invoke(recorder: described_class, invocation_id: "replayed") { [] }
      invoke(recorder: described_class, invocation_id: "replayed") { [] }

      expect(entries.count).to eq(1)
    end

    it "keeps the trace of a tool that rolled its own work back" do
      scratch = Ledger.scratch

      expect do
        invoke(recorder: described_class) do
          ActiveRecord::Base.transaction do
            scratch.create!(name: "written then rolled back")
            raise "kaboom"
          end
        end
      end.to raise_error(RuntimeError, "kaboom")

      expect(scratch.count).to eq(0)
      expect(entries.count).to eq(1)
    end

    # The parent warns when it detects a host transaction; this recorder is not affected
    # by one, so warning would be noise that trains a host to ignore the message.
    it "does not warn about a transaction it is immune to" do
      logger = CapturingLogger.new
      Reeve.config.logger = logger

      ActiveRecord::Base.transaction do
        invoke(recorder: described_class) { [] }
      end

      expect(logger.warnings.join).not_to match(/rolled back with it/)
    end

    it "returns its connection to the pool rather than holding one per thread" do
      pool = Reeve::Audit::IsolatedEntry.connection_pool

      invoke(recorder: described_class) { [] }

      expect(pool.connections.count(&:in_use?)).to eq(0)
    end

    it "writes the same shape the default recorder does" do
      invoke(recorder: described_class, arguments: { query: "acme" }) { [] }

      expect(only_entry.contract_version).to eq(Reeve::Audit::CONTRACT_VERSION)
      expect(only_entry.arguments).to eq("query" => "acme")
      expect(only_entry.guard).to eq("policy")
    end
  end
end
