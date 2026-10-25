# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "tmpdir"
require_relative "../support/ledger"

# specs/005 US4, FR-007, FR-012, contracts/archive-v1.md: the archive a purge writes, and
# verifying it without the ledger's rows.
RSpec.describe "ledger archives" do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }

  around do |example|
    Dir.mktmpdir("reeve-archive") do |dir|
      @dir = dir
      example.run
    end
  end

  before do
    Ledger.prepare!
    Reeve.config.ledger_anchor = Ledger::RecordingAnchor.new
    Reeve.config.ledger_retention_connection = Ledger.retention_connection
  end

  def row(**overrides)
    { invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
      arguments: { "n" => SecureRandom.hex(4) }, outcome: "allow", rule: "r", record_ids: %w[1 2],
      guard: "policy", contract_version: Reeve::Audit::CONTRACT_VERSION }.merge(overrides)
  end

  def write(count, every: 10, **overrides)
    count.times do |index|
      chain.append!(row(**overrides))
      Reeve::Audit::Chain.checkpoint! if ((index + 1) % every).zero?
    end
  end

  def path(name = "ledger.jsonl")
    File.join(@dir, name)
  end

  def purge(through, name = "ledger.jsonl")
    Reeve::Audit::Chain.purge!(through: through, archive: path(name), confirm: true)
  end

  def verify_archive(name = "ledger.jsonl", keys: nil)
    Reeve::Audit::Chain.verify_archive(path(name), keys: keys)
  end

  def lines(name = "ledger.jsonl")
    File.readlines(path(name), chomp: true)
  end

  def rewrite(name = "ledger.jsonl")
    File.write(path(name), "#{yield(lines(name)).join("\n")}\n")
  end

  describe "the file" do
    before do
      2.times { Reeve::Audit::Entry.create!(row(contract_version: 2)) }
      write(30)
      purge(20)
    end

    it "is a header, then the pre-chain rows, then the chained range in order" do
      header = JSON.parse(lines.first)
      rows = lines.drop(1).map { |line| JSON.parse(line) }

      expect(header).to include("format" => "reeve-ledger-archive-v1", "purge" => 0, "from_sequence" => 1,
                                "through_sequence" => 20, "chained" => 20, "pre_chain" => 2)
      expect(header["start"]).to have_key("genesis")
      expect(rows.first(2).map { |found| found["contract_version"] }).to eq([2, 2])
      expect(rows.drop(2).map { |found| found["chain_sequence"] }).to eq((1..20).to_a)
      expect(rows.first.keys).to eq(rows.first.keys.sort)
      expect(rows.first).not_to have_key("id")
      expect(rows.last["occurred_at"]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z\z/)
    end

    it "has the digest the retention record holds" do
      expect(Reeve::Audit::RetentionRecord.last.archive_sha256).to eq(Digest::SHA256.file(path).hexdigest)
      expect(File.exist?("#{path}.tmp")).to be(false)
    end
  end

  it "is written whole before anything is removed: a failed write removes nothing" do
    write(20)
    allow(Reeve::Audit::Chain::Retention::Archive).to receive(:line).and_raise(IOError, "disk full")

    expect { purge(10) }.to raise_error(IOError)
    expect(Reeve::Audit::Entry.count).to eq(20)
    expect(Reeve::Audit::RetentionRecord.count).to eq(0)
    expect(File.exist?(path)).to be(false)
  end

  describe "verified on its own" do
    before do
      write(30)
      purge(20)
    end

    it "is intact from the genesis to the boundary checkpoint" do
      result = verify_archive

      expect(result.status).to eq(:intact)
      expect(result.covered).to eq(1..20)
      expect(result.to_s).to start_with("reeve archive: INTACT — sequences 1–20 verified, ending at checkpoint #20")
    end

    it "is intact for a later purge, from the previous boundary" do
      write(10)
      purge(30, "second.jsonl")

      result = verify_archive("second.jsonl")

      expect(result.status).to eq(:intact)
      expect(result.covered).to eq(21..30)
    end

    it "does not need the purged rows: the ledger no longer has them" do
      expect(Reeve::Audit::Entry.where(chain_sequence: 1..20).count).to eq(0)
      expect(verify_archive.status).to eq(:intact)
    end

    it "is broken when a line is edited" do
      rewrite { |all| all.map.with_index { |line, i| i == 5 ? line.sub('"tool_name":"t"', '"tool_name":"x"') : line } }

      result = verify_archive

      expect(result.status).to eq(:broken)
      expect(result.breaks.map { |found| [found.kind, found.sequence] }).to include([:digest_mismatch, 5])
    end

    it "is broken when a line is removed" do
      rewrite { |all| all.reject.with_index { |_, i| i == 5 } }

      expect(verify_archive.breaks.map(&:kind)).to include(:missing)
    end

    it "is broken when lines are reordered" do
      rewrite { |all| all.values_at(0, 2, 1, *(3...all.size)) }

      expect(verify_archive.status).to eq(:broken)
    end

    it "is broken when the last line is dropped, so it no longer ends at the checkpoint" do
      rewrite { |all| all[0...-1] }

      expect(verify_archive.breaks.map(&:kind)).to include(:checkpoint_not_reached)
    end

    it "is unverifiable, never intact, without the key that signed it" do
      expect(verify_archive(keys: ["another-ledger-key-not-a-secret-0123456789"]).status).to eq(:unverifiable)
    end

    it "refuses a file in a format it does not know" do
      rewrite { |all| [all.first.sub("reeve-ledger-archive-v1", "reeve-ledger-archive-v2"), *all.drop(1)] }

      expect { verify_archive }.to raise_error(ArgumentError, /reeve-ledger-archive-v2/)
    end
  end

  # The roundtrip spec's awkward values, through a purge and back.
  it "verifies awkward values" do
    awkward = { "unicode" => "café ☕ — ünïcödé", "nested" => { "b" => [1, 2.5, nil, true], "a" => "x" },
                "big" => 9_007_199_254_740_991, "empty" => {} }
    write(10, arguments: awkward, metadata: { "k" => "v" })
    purge(10)

    expect(verify_archive.status).to eq(:intact)
  end
end
