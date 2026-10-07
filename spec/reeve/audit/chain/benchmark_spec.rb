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
