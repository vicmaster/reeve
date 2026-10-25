# frozen_string_literal: true

require "securerandom"
require_relative "../support/ledger"

# T002 / SC-005: what one ledger write costs, measured before chaining exists, so the
# chained write has a baseline to be compared against instead of a budget picked in the
# abstract. Tagged :benchmark and excluded from the default run:
#
#   bundle exec rspec --tag benchmark spec/reeve/audit/chain/benchmark_spec.rb
#   DB=postgresql bundle exec rspec --tag benchmark spec/reeve/audit/chain/benchmark_spec.rb
#
# Prints the median and p95 of single uncontended writes. It asserts only that every write
# landed — a benchmark that silently measured failures would be worse than none.
RSpec.describe "ledger write cost", :benchmark do
  let(:warmup) { 100 }
  let(:samples) { 1_000 }

  before { Ledger.prepare! }

  def attributes
    {
      invocation_id: SecureRandom.uuid,
      occurred_at: Time.now,
      agent_id: "benchmark",
      agent_name: "Benchmark Agent",
      principal_type: "User",
      principal_id: 42,
      tool_name: "invoice_search",
      arguments: { query: "acme", filters: { status: "open", limit: 25, tags: %w[q3 eu] } },
      outcome: :allow,
      rule: "InvoicePolicy#index?",
      record_type: "Invoice",
      record_ids: (1..20).to_a,
      record_count: 20,
      guard: "policy",
      duration_ms: 3,
      metadata: { request_id: SecureRandom.hex(8), transport: "http" }
    }
  end

  def measure(recorder, count)
    Array.new(count) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      recorder.record(attributes)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    end
  end

  def percentile(sorted, fraction)
    sorted[((sorted.size - 1) * fraction).round]
  end

  it "reports the median and p95 of an uncontended Recorder write" do
    recorder = Reeve::Audit::Recorder.new
    measure(recorder, warmup)
    timings = measure(recorder, samples).sort

    report = format(
      "ledger write (%<adapter>s, %<n>d samples): median %<median>.3f ms, p95 %<p95>.3f ms",
      adapter: SpecDatabase.adapter, n: samples,
      median: percentile(timings, 0.5), p95: percentile(timings, 0.95)
    )
    RSpec.configuration.reporter.message(report)

    expect(Reeve::Audit::Entry.count).to eq(warmup + samples)
  end
end

# specs/002 T054 / SC-004: verifying a large ledger, in time and in memory; and specs/004
# SC-004: checkpointing one.
#
#   bundle exec rspec --tag benchmark_large spec/reeve/audit/chain/benchmark_spec.rb
#
# The ledger is built by signing rows with the same canonical digest and linking Chain uses,
# then bulk-inserting them in batches: a million appends at a millisecond or two each would
# spend half an hour building the fixture for a measurement of verification. That the
# shortcut builds a genuine chain is not assumed — the verifier must find it intact before
# its timing counts.
RSpec.describe "verifying a large ledger", :benchmark_large do
  before { Ledger.prepare! }

  BATCH = 5_000

  # Signs and links each row exactly as Chain#append! does, then bulk-inserts a batch at a
  # time; returns the last digest so the head can be pointed at it.
  def build_chain(size)
    keyring = Reeve::Audit::Chain::Keyring.from(Reeve.config)
    Reeve::Audit::Chain::Head.new(connection: ActiveRecord::Base.connection, entry_class: Reeve::Audit::Entry)
                             .start!(keyring)
    previous = Reeve::Audit::ChainRecord.ledger.genesis_digest

    (1..size).each_slice(BATCH) do |sequences|
      rows = sequences.map do |sequence|
        entry = signed_entry(sequence, keyring, previous)
        previous = entry.chain_digest
        entry.attributes.except("id")
      end
      Reeve::Audit::Entry.insert_all!(rows)
    end
    Reeve::Audit::ChainRecord.update_all(head_sequence: size, head_digest: previous)
  end

  def signed_entry(sequence, keyring, previous)
    @normalizer ||= Reeve::Audit::Chain::Normalizer.new(Reeve::Audit::Entry)
    attributes = {
      invocation_id: "bench-#{sequence}", occurred_at: Time.utc(2026, 10, 1) + sequence,
      agent_id: "a", tool_name: "invoice_search", arguments: { "q" => sequence, "f" => { "s" => "open" } },
      outcome: "allow", rule: "r", record_ids: [sequence.to_s], record_count: 1, guard: "policy",
      contract_version: Reeve::Audit::CONTRACT_VERSION, chain_sequence: sequence, chain_key_id: keyring.signing_id
    }
    entry = Reeve::Audit::Entry.new(@normalizer.call(attributes))
    entry.chain_digest = Reeve::Audit::Chain::Canonical.entry_digest(keyring.signing_secret, entry,
                                                                     previous_digest: previous)
    entry
  end

  def rss_kb
    `ps -o rss= -p #{Process.pid}`.to_i
  end

  # Peak resident memory above the starting point while the block runs, sampled every 20 ms.
  def peak_growth_kb
    GC.start
    baseline = rss_kb
    peak = baseline
    sampler = Thread.new do
      loop do
        peak = [peak, rss_kb].max
        sleep 0.02
      end
    end
    result = yield
    [result, peak - baseline]
  ensure
    sampler&.kill
  end

  # specs/004 SC-004: a checkpoint reads the head and the latest epoch, whatever the ledger's
  # size. Measured on the largest ledger this file builds, and checked to verify against it.
  it "checkpoints 1,000,000 entries in under a second" do
    build_chain(1_000_000)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    made = Reeve::Audit::Chain.checkpoint!(anchor: nil)
    seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(made.checkpoint.head_sequence).to eq(1_000_000)
    RSpec.configuration.reporter.message(
      format("checkpoint (%<db>s, 1000000 entries): %<ms>.1f ms", db: SpecDatabase.adapter, ms: seconds * 1000)
    )
    expect(seconds).to be < 1
  end

  it "verifies 100,000 and 1,000,000 entries, reporting time and peak memory" do
    measurements = [100_000, 1_000_000].map do |size|
      Ledger.prepare!
      build_chain(size)
      # Rails maps SQLite's database file into memory (mmap_size, 128 MB by default), so the
      # pages a walk touches count as resident memory — the operating system's file cache,
      # not memory reeve holds, and it grows with the file up to the cap. Measured with the
      # map off so the number is the walk's own; PostgreSQL needs no such adjustment.
      ActiveRecord::Base.connection.execute("PRAGMA mmap_size = 0") if SpecDatabase.sqlite?
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result, growth = peak_growth_kb { Reeve::Audit::Chain.verify }
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(result.status).to eq(:intact)
      expect(result.covered).to eq(1..size)
      RSpec.configuration.reporter.message(
        format("verify (%<db>s, %<n>d entries): %<s>.1f s, peak RSS growth %<mb>.1f MB",
               db: SpecDatabase.adapter, n: size, s: seconds, mb: growth / 1024.0)
      )
      [size, seconds, growth]
    end

    small, large = measurements
    expect(large[1]).to be < 300 # SC-004: under 5 minutes for a million entries
    # SC-004: memory that does not grow with the ledger — within 10% from 100k to 1M,
    # with a floor of 8 MB so that sampling noise on a small number is not mistaken for growth.
    expect(large[2]).to be <= [small[2] * 1.1, small[2] + (8 * 1024)].max
  end
end
