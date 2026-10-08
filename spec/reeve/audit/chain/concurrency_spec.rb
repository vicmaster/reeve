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

  def hammer(recorder, writers:, each:)
    gate = Queue.new
    threads = Array.new(writers) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          each.times { recorder.record(attributes) }
        end
      end
    end
    writers.times { gate << :go }
    threads.each(&:join)
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

  context "on SQLite" do
    before { skip("SQLite only") unless SpecDatabase.sqlite? }

    it "serializes 4 writers × 100 invocations into one chain without a deadlock" do
      hammer(Reeve::Audit::Recorder, writers: 4, each: 100)

      expect_one_clean_chain(400)
    end
  end
end
