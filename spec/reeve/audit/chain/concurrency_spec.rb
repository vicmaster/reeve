# frozen_string_literal: true

require "securerandom"
require_relative "../support/ledger"

# specs/002 T022 / FR-004, FR-005, FR-006, SC-003.
#
# Many writers, one chain. The sequence must come out gap-free and duplicate-free, with no
# deadlock, and verify intact — through both recorders, on the databases that actually
# have concurrent writers. SQLite serializes writers itself, so it gets a small run that
# proves only that the chain does not deadlock against its write lock.
RSpec.describe "concurrent writers on one chain" do
  before { Ledger.prepare! }

  def attributes
    { invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
      arguments: { "n" => rand(1000) }, outcome: "allow", rule: "r", guard: "policy" }
  end

  # Returns the errors writers raised, when `collect_errors:` — otherwise any error fails
  # the example from the thread that raised it.
  def hammer(recorder, writers:, each:, collect_errors: false)
    gate = Queue.new
    errors = Queue.new
    threads = Array.new(writers) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          each.times do
            recorder.record(attributes)
          rescue StandardError => e
            raise unless collect_errors

            errors << e
          end
        end
      end
    end
    writers.times { gate << :go }
    threads.each(&:join)
    Array.new(errors.size) { errors.pop }
  end

  def sequences
    Reeve::Audit::Entry.where.not(chain_sequence: nil).order(:chain_sequence).pluck(:chain_sequence)
  end

  def expect_one_clean_chain(total)
    expect(sequences).to eq((1..total).to_a)
    result = Reeve::Audit::Chain.verify
    expect(result.status).to eq(:intact)
    expect(result.covered).to eq(1..total)
  end

  context "on a database with concurrent writers" do
    before do
      skip("needs a server database — run with DB=postgresql or DB=mysql2") if SpecDatabase.sqlite?
    end

    it "gives 8 writers × 1,000 invocations through Recorder sequences 1–8,000" do
      hammer(Reeve::Audit::Recorder, writers: 8, each: 1_000)

      expect_one_clean_chain(8_000)
    end

    it "gives 8 writers × 1,000 invocations through IsolatedRecorder sequences 1–8,000" do
      hammer(Reeve::Audit::IsolatedRecorder, writers: 8, each: 1_000)

      expect_one_clean_chain(8_000)
    end
  end

  # Before Rails 7.1, sqlite3 1.x waits for the write lock inside C while holding Ruby's
  # GVL, so the thread that holds the lock cannot run to release it and the waiter fails
  # after the full busy timeout — two threads and plain SQL, no reeve involved (research
  # R3, "Rails 7.0 and SQLite"). 7.1 replaced it with a busy handler that releases the GVL.
  OLD_SQLITE_BUSY_WAIT = ActiveRecord.version < Gem::Version.new("7.1")

  context "on SQLite" do
    before { skip("SQLite only") unless SpecDatabase.sqlite? }

    it "serializes 4 writers × 100 invocations into one chain without a deadlock" do
      skip("Rails < 7.1: covered by the fail-closed example below") if OLD_SQLITE_BUSY_WAIT

      hammer(Reeve::Audit::Recorder, writers: 4, each: 100)

      expect_one_clean_chain(400)
    end

    # What reeve can promise on that stack: a write that loses the wait fails loudly, and
    # the writes that land still form one gap-free chain. Nothing half-written, nothing
    # silently dropped.
    it "on Rails < 7.1, fails contended writes closed and keeps the chain intact" do
      skip("Rails 7.1+ releases the GVL while waiting") unless OLD_SQLITE_BUSY_WAIT

      errors = hammer(Reeve::Audit::Recorder, writers: 3, each: 10, collect_errors: true)
      written = sequences.size

      expect(errors.map { |e| e.class.name }.uniq - ["ActiveRecord::StatementInvalid"]).to eq([])
      expect(written + errors.size).to eq(30)
      expect_one_clean_chain(written) if written.positive?
    end
  end
end
