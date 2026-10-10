# frozen_string_literal: true

require "json"
require "rake"
require "securerandom"
require "stringio"
require "reeve/tasks"
require_relative "audit/support/ledger"

# specs/002 T042 / FR-017, contracts/ledger-chain.md "Rake": `bin/rails reeve:verify_ledger`.
#
# The task is a wrapper; Reeve::Tasks.verify_ledger is what it runs, and what is pinned here
# directly — exit status, output, LIMIT, FORMAT — plus one run through Rake itself.
RSpec.describe "reeve:verify_ledger" do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:out) { StringIO.new }

  before { Ledger.prepare! }

  def row(**overrides)
    { invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
      arguments: {}, outcome: "allow", rule: "r", record_ids: [], guard: "policy",
      contract_version: Reeve::Audit::CONTRACT_VERSION }.merge(overrides)
  end

  def verify(env = {})
    Reeve::Tasks.verify_ledger(env: env, out: out)
  end

  describe "exit status" do
    it "is 0 for an intact chain, printing the summary with its coverage" do
      3.times { chain.append!(row) }

      expect(verify).to eq(0)
      expect(out.string).to start_with("reeve ledger: INTACT — sequences 1–3 verified")
    end

    it "is 1 for a broken chain" do
      3.times { chain.append!(row) }
      Reeve::Audit::Entry.where(chain_sequence: 2).delete_all

      expect(verify).to eq(1)
      expect(out.string).to start_with("reeve ledger: BROKEN")
    end

    it "is 2 when there is no chain to verify" do
      expect(verify).to eq(2)
      expect(out.string).to start_with("reeve ledger: NO CHAIN")
    end

    it "is 2 when there is no key to verify with" do
      chain.append!(row)
      Reeve.config.ledger_key = nil

      expect(verify).to eq(2)
      expect(out.string).to start_with("reeve ledger: UNVERIFIABLE")
    end

    it "is 2 for rows signed by a key it does not hold" do
      Reeve.config.ledger_key = "another-ledger-key-not-a-secret-0123456789"
      chain.append!(row)
      Reeve.config.ledger_key = Ledger::TEST_KEY

      expect(verify).to eq(2)
    end
  end

  describe "LIMIT" do
    before do
      6.times { chain.append!(row) }
      Reeve::Audit::Entry.where(chain_sequence: [2, 4]).delete_all
    end

    it "lists every break up to the default limit" do
      verify

      expect(out.string.lines.size).to eq(6) # summary, totals, and four breaks
    end

    it "with LIMIT=0 prints the summary and the totals only — the totals are never capped" do
      verify("LIMIT" => "0")

      expect(out.string.lines.map(&:strip)).to eq([out.string.lines.first.strip, "totals: missing 2, digest_mismatch 2"])
    end

    it "refuses a LIMIT that is not a whole number, rather than guessing one" do
      expect { verify("LIMIT" => "lots") }.to raise_error(ArgumentError, /LIMIT/)
    end
  end

  describe "FORMAT=json" do
    it "emits the whole result, with every break, whatever LIMIT says" do
      6.times { chain.append!(row) }
      Reeve::Audit::Entry.where(chain_sequence: [2, 4]).delete_all

      status = verify("FORMAT" => "json", "LIMIT" => "0")
      json = JSON.parse(out.string)

      expect(status).to eq(1)
      expect(json["status"]).to eq("broken")
      expect(json["breaks"].size).to eq(4)
    end

    it "refuses a format it does not know" do
      expect { verify("FORMAT" => "xml") }.to raise_error(ArgumentError, /FORMAT/)
    end
  end

  # Through Rake itself: the task exists under the name the contract gives it, depends on
  # :environment as a Rails task does, and exits with the status verify_ledger returned.
  it "is defined as a Rake task that exits with the verification's status" do
    rake = Rake::Application.new
    Rake.application = rake
    rake.define_task(Rake::Task, :environment)
    Reeve::Tasks.define
    chain.append!(row)

    task = rake["reeve:verify_ledger"]
    expect(task.prerequisites).to eq(["environment"])
    expect { task.invoke }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(0) }
      .and output(/INTACT/).to_stdout
  ensure
    Rake.application = Rake::Application.new
  end
end
