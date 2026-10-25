# frozen_string_literal: true

require "json"
require "rake"
require "securerandom"
require "stringio"
require "tmpdir"
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

  # specs/004 FR-010, contracts/anchoring.md "Rake".
  describe "CHECKPOINTS" do
    around do |example|
      Dir.mktmpdir("reeve-checkpoints") do |dir|
        @dir = dir
        example.run
      end
    end

    def file_with(*lines)
      File.join(@dir, "given.checkpoints").tap { |path| File.write(path, lines.map { |l| "#{l}\n" }.join) }
    end

    before do
      3.times { chain.append!(row) }
      @line = Reeve::Audit::Chain.checkpoint!(anchor: nil).checkpoint.to_line
      Ledger.truncate_tail!(after: 1)
    end

    it "uses the configured anchor by default" do
      Reeve.config.ledger_anchor = Ledger::RecordingAnchor.new.tap { |anchor| anchor.publish(@line) }

      expect(verify).to eq(1)
      expect(out.string).to include("checkpoint #3")
    end

    it "reads a file of checkpoint lines instead of the anchor" do
      Reeve.config.ledger_anchor = Ledger::RecordingAnchor.new

      expect(verify("CHECKPOINTS" => file_with(@line))).to eq(1)
    end

    it "turns anchoring off when empty, even with an anchor configured" do
      Reeve.config.ledger_anchor = Ledger::RecordingAnchor.new.tap { |anchor| anchor.publish(@line) }

      expect(verify("CHECKPOINTS" => "")).to eq(0)
      expect(out.string.lines.first).to end_with("; not anchored\n")
    end

    # research R5: refusing to answer is the only honest output, and 2 means "could not verify".
    it "exits 2 for a line that is not a checkpoint, naming its position" do
      expect(verify("CHECKPOINTS" => file_with(@line, "garbage"))).to eq(2)
      expect(out.string).to eq("reeve ledger: checkpoint 2 cannot be read: not JSON; nothing was verified\n")
    end

    # specs/004 US5.
    it "walks from the highest checkpoint with FROM=latest" do
      Ledger.prepare!
      3.times { chain.append!(row) }
      line = Reeve::Audit::Chain.checkpoint!(anchor: nil).checkpoint.to_line
      chain.append!(row)

      expect(verify("CHECKPOINTS" => file_with(line), "FROM" => "latest")).to eq(0)
      expect(out.string).to start_with("reeve ledger: INTACT — sequences 4–4 verified from checkpoint #3")
    end

    it "accepts only latest for FROM" do
      expect { verify("FROM" => "3") }.to raise_error(ArgumentError, /FROM must be latest/)
    end

    it "exits 2 for a file that is not there, naming it" do
      expect(verify("CHECKPOINTS" => File.join(@dir, "missing"))).to eq(2)
      expect(out.string).to include("no checkpoint file at #{File.join(@dir, 'missing')}")
    end
  end

  # Review finding: defining the task must not leave Rake's DSL on Reeve::Tasks.
  it "defines the task without giving Reeve::Tasks Rake's methods" do
    Rake.application = Rake::Application.new
    Reeve::Tasks.define

    expect(Reeve::Tasks).not_to respond_to(:task)
    expect(Reeve::Tasks.singleton_class.include?(Rake::DSL)).to be(false)
  ensure
    Rake.application = Rake::Application.new
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

# specs/004 FR-007, contracts/anchoring.md "checkpoint_ledger output".
RSpec.describe "reeve:checkpoint_ledger" do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:out) { StringIO.new }

  before { Ledger.prepare! }

  def row
    { invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
      arguments: {}, outcome: "allow", rule: "r", record_ids: [], guard: "policy",
      contract_version: Reeve::Audit::CONTRACT_VERSION }
  end

  def checkpoint
    Reeve::Tasks.checkpoint_ledger(env: {}, out: out)
  end

  def lines
    out.string.lines(chomp: true)
  end

  let(:key_id) { Reeve::LedgerKey.fingerprint(Ledger::TEST_KEY) }

  it "publishes to the anchor, printing what it made and the line, and exits 0" do
    2.times { chain.append!(row) }
    anchor = Ledger::RecordingAnchor.new
    Reeve.config.ledger_anchor = anchor

    expect(checkpoint).to eq(0)
    expect(lines.first).to eq("reeve ledger checkpoint: MADE — head #2, epoch 0, key #{key_id}; " \
                              "published to the anchor")
    expect(lines.last).to eq(anchor.lines.first)
  end

  it "prints the line to store by hand when no anchor is configured, and exits 0" do
    chain.append!(row)

    expect(checkpoint).to eq(0)
    expect(lines.first).to end_with("no anchor configured, store the line below yourself")
    expect(JSON.parse(lines.last)["head_sequence"]).to eq(1)
  end

  # The checkpoint was made; only the store failed. The line is still printed so it is not lost.
  it "exits 1 when the anchor fails, still printing the line" do
    chain.append!(row)
    Reeve.config.ledger_anchor = Ledger::RecordingAnchor.new(error: IOError.new("bucket unreachable"))

    expect(checkpoint).to eq(1)
    expect(lines.first).to end_with("the anchor failed (bucket unreachable (IOError)), store the line " \
                                    "below yourself")
    expect(JSON.parse(lines.last)["head_sequence"]).to eq(1)
  end

  it "exits 1, making nothing, with no chain" do
    expect(checkpoint).to eq(1)
    expect(out.string).to eq("reeve ledger checkpoint: REFUSED — the ledger has no chain yet; nothing " \
                             "to checkpoint; nothing was made\n")
  end

  it "exits 1, making nothing, with no key" do
    Reeve.config.ledger_key = nil

    expect(checkpoint).to eq(1)
    expect(out.string).to eq("reeve ledger checkpoint: REFUSED — no ledger key configured " \
                             "(config.ledger_key); nothing was made\n")
  end

  it "never prints the key" do
    chain.append!(row)
    checkpoint

    expect(out.string).not_to include(Ledger::TEST_KEY)
  end

  it "is defined as a Rake task that exits with the checkpoint's status" do
    rake = Rake::Application.new
    Rake.application = rake
    rake.define_task(Rake::Task, :environment)
    Reeve::Tasks.define
    chain.append!(row)

    task = rake["reeve:checkpoint_ledger"]
    expect(task.prerequisites).to eq(["environment"])
    expect { task.invoke }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(0) }
      .and output(/MADE/).to_stdout
  ensure
    Rake.application = Rake::Application.new
  end
end

# specs/005 FR-001–FR-003, contracts/retention.md "Rake".
RSpec.describe "reeve:purge_ledger" do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:out) { StringIO.new }

  around do |example|
    Dir.mktmpdir("reeve-purge") do |dir|
      @archive = File.join(dir, "ledger.jsonl")
      example.run
    end
  end

  before do
    Ledger.prepare!
    Reeve.config.ledger_anchor = Ledger::RecordingAnchor.new
    Reeve.config.ledger_retention_connection = Ledger.retention_connection
    20.times do |index|
      chain.append!(invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
                    arguments: {}, outcome: "allow", rule: "r", record_ids: [], guard: "policy",
                    contract_version: Reeve::Audit::CONTRACT_VERSION)
      Reeve::Audit::Chain.checkpoint! if ((index + 1) % 10).zero?
    end
  end

  def purge(env)
    Reeve::Tasks.purge_ledger(env: env, out: out)
  end

  it "dry-runs without CONFIRM, exiting 0 and removing nothing" do
    expect(purge("THROUGH" => "10", "ARCHIVE" => @archive)).to eq(0)
    expect(out.string).to start_with("reeve ledger purge: WOULD PURGE")
    expect(Reeve::Audit::Entry.count).to eq(20)
  end

  it "purges with CONFIRM=1, exiting 0" do
    expect(purge("THROUGH" => "10", "ARCHIVE" => @archive, "CONFIRM" => "1")).to eq(0)
    expect(out.string).to start_with("reeve ledger purge: PURGED — sequences 1–10")
    expect(Reeve::Audit::Entry.count).to eq(10)
  end

  it "exits 1 when it refuses" do
    expect(purge("THROUGH" => "15", "ARCHIVE" => @archive, "CONFIRM" => "1")).to eq(1)
    expect(out.string).to start_with("reeve ledger purge: REFUSED")
  end

  it "accepts OLDER_THAN in days" do
    expect(purge("OLDER_THAN" => "365d", "ARCHIVE" => @archive)).to eq(0)
    expect(out.string).to start_with("reeve ledger purge: NOTHING TO PURGE")
  end

  # specs/005 FR-012.
  it "verifies the archive it wrote with reeve:verify_archive, exiting as verify_ledger does" do
    purge("THROUGH" => "10", "ARCHIVE" => @archive, "CONFIRM" => "1")
    archive_out = StringIO.new

    expect(Reeve::Tasks.verify_archive(env: { "ARCHIVE" => @archive }, out: archive_out)).to eq(0)
    expect(archive_out.string).to start_with("reeve archive: INTACT — sequences 1–10 verified")

    File.write(@archive, File.read(@archive).sub('"tool_name":"t"', '"tool_name":"x"'))
    expect(Reeve::Tasks.verify_archive(env: { "ARCHIVE" => @archive }, out: StringIO.new)).to eq(1)
    expect { Reeve::Tasks.verify_archive(env: {}, out: StringIO.new) }.to raise_error(ArgumentError, /ARCHIVE/)
  end

  it "names the accepted values for anything else" do
    expect { purge("THROUGH" => "ten", "ARCHIVE" => @archive) }.to raise_error(ArgumentError, /THROUGH/)
    expect { purge("OLDER_THAN" => "1y", "ARCHIVE" => @archive) }.to raise_error(ArgumentError, /365d/)
    expect { purge("THROUGH" => "10", "ARCHIVE" => @archive, "CONFIRM" => "yes") }.to raise_error(ArgumentError, /CONFIRM/)
    expect { purge("THROUGH" => "10", "ARCHIVE" => @archive, "NO_ARCHIVE" => "1") }.to raise_error(ArgumentError, /not both/)
    expect { purge("ARCHIVE" => @archive) }.to raise_error(ArgumentError, /exactly one/)
  end
end
