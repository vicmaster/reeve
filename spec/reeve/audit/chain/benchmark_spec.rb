# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "fileutils"
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
# SC-004: checkpointing one; and specs/005 SC-004: purging one.
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
    connection = ActiveRecord::Base.connection
    Reeve::Audit::Chain::Head.new(connection: connection, entry_class: Reeve::Audit::Entry).start!(keyring)
    # Contract-4 rows name their key epoch (specs/003), so the key opens epoch 0 at sequence 1,
    # as the first chained write would.
    Reeve::Audit::Chain::Epochs.new(connection: connection).open!(keyring, first_sequence: 1)
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
      contract_version: Reeve::Audit::CONTRACT_VERSION, chain_sequence: sequence, chain_key_id: keyring.signing_id,
      chain_epoch: 0
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

  WRITER = File.expand_path("../support/writer.rb", __dir__)

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # A writer in a process of its own (specs/005 writer-wait.md): a thread here would share the
  # GVL with the purge's HMAC work, and its slowest write would not be a database wait.
  def spawn_writer(output)
    env = { "REEVE_WRITER_DB" => ActiveRecord::Base.connection_db_config.configuration_hash.to_json,
            "REEVE_WRITER_KEY" => Reeve.config.ledger_key }
    Process.spawn(env, RbConfig.ruby, "-I", File.expand_path("../../../../lib", __dir__), WRITER, output)
  end

  # Each complete write as [started, seconds]; raises with the writer's error if it wrote one.
  def writes(output)
    return [] unless File.exist?(output)

    lines = File.read(output).lines.select { |line| line.end_with?("\n") }.map(&:chomp)
    error = lines.index { |line| line.start_with?("error ") }
    raise "writer failed: #{lines[error..].join("\n")}" if error

    lines.map { |line| line.split.map { |value| Float(value) } }
  end

  # Raises at once, with the writer's own error where it wrote one, if the writer has exited.
  def expect_writing(pid, output)
    status = Process.waitpid2(pid, Process::WNOHANG)&.last
    return unless status

    writes(output)
    raise "writer exited (#{status.inspect}); anything it printed is in the output above"
  end

  def await_first_write(pid, output, seconds: 60)
    deadline = now + seconds
    while writes(output).empty?
      expect_writing(pid, output)
      raise "writer made no write in #{seconds} s" if now > deadline

      sleep 0.05
    end
  end

  def stop_writer(pid, seconds: 30)
    Process.kill("TERM", pid)
    deadline = now + seconds
    until (status = Process.waitpid2(pid, Process::WNOHANG)&.last)
      raise "writer did not stop in #{seconds} s" if now > deadline

      sleep 0.05
    end
    status
  end

  # A writer left running by a failed example is killed, not left writing into the next one.
  # Waited for first: a pid already reaped raises ECHILD, so one the system has since reused
  # is never signalled.
  def reap(pid)
    return if Process.waitpid(pid, Process::WNOHANG)

    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end

  def latency(writes)
    sorted = writes.map { |_, seconds| seconds * 1000 }.sort
    format("%<n>d writes, median %<median>.1f ms, p99 %<p99>.1f ms, max %<max>.1f ms",
           n: sorted.size, median: percentile(sorted, 0.5), p99: percentile(sorted, 0.99),
           max: sorted.last.to_f)
  end

  def percentile(sorted, fraction)
    sorted.empty? ? 0.0 : sorted[((sorted.size - 1) * fraction).round]
  end

  # specs/005 SC-004: a purge of a million entries holds no lock writers queue on. A writer in
  # another process appends alone for a baseline, then throughout the purge; both latencies are
  # reported beside the purge's time, and verification afterwards walks only what it added.
  it "purges 1,000,000 entries while writes continue, and verifies only the rest" do
    size = Integer(ENV.fetch("REEVE_PURGE_SIZE", "1000000"))
    build_chain(size)
    Reeve.config.ledger_anchor = Ledger::RecordingAnchor.new
    Reeve.config.ledger_retention_connection = Ledger.retention_connection
    Reeve::Audit::Chain.checkpoint!

    directory = Dir.mktmpdir("reeve-writer")
    output = File.join(directory, "writes")
    pid = spawn_writer(output)
    await_first_write(pid, output)
    sleep 3
    expect_writing(pid, output)
    purge_started = now
    result = Reeve::Audit::Chain.purge!(through: size, no_archive: true, confirm: true)
    purge_ended = now
    expect_writing(pid, output)
    status = stop_writer(pid)
    pid = nil

    all = writes(output)
    expect(status).to be_success
    expect(result).to be_purged, result.to_s
    # The first write opens the connection and reads the schema, so it is no baseline.
    baseline = all.drop(1).select { |started, _| started < purge_started }
    during = all.select { |started, _| started >= purge_started && started < purge_ended }
    expect(during).not_to be_empty, "no write started during the purge; it measured nothing"
    after = Reeve::Audit::Chain.verify(checkpoints: [])
    expect(after.status).to eq(:intact)
    expect(after.covered).to eq((size + 1)..(size + all.size))
    RSpec.configuration.reporter.message(
      format("purge (%<db>s, %<size>d entries): %<s>.1f s; writer in its own process: " \
             "baseline %<baseline>s; during the purge %<during>s",
             db: SpecDatabase.adapter, size: size, s: purge_ended - purge_started,
             baseline: latency(baseline), during: latency(during))
    )
  ensure
    reap(pid) if pid
    FileUtils.rm_rf(directory) if directory
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
