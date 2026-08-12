# frozen_string_literal: true

require "support/optional/authorization_records"
require "reeve/audit"
require "reeve/audit/support/ledger"

# plan.md's performance goals, as assertions rather than intentions: the envelope adds
# ≤ 5 ms per invocation excluding the policy's own queries and the ledger insert, and
# scoping introduces no N+1.
#
# Thresholds are deliberately loose. This spec exists to catch a regression of the shape
# "someone made the envelope do a query per record", not to defend a microsecond budget
# on shared CI hardware.
RSpec.describe "envelope overhead" do
  let(:alice) { Owner.new(1) }
  let(:recorder) { CountingRecorder.new }

  before do
    Invoice.delete_all
    100.times { |i| Invoice.create!(number: "A-#{i}", owner_id: alice.id) }
    Reeve.configure do |c|
      c.audit_recorder = recorder
      c.principal_resolver = ->(_context) { alice }
    end

    stub_const("MeasuredTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy
      def call = Invoice.all
    end)
  end

  def elapsed_ms
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
  end

  # Compares the *fastest* call on each side, from trials run alternately.
  #
  # This used to time fifty guarded calls in one window, fifty bare calls in another, and
  # subtract the means. A single stall — one GC pause, one scheduler preemption — landing
  # in the guarded window and not the bare one lands whole in that difference: 300ms over
  # fifty runs is 6ms per call against a 5ms budget, from a machine hiccup rather than a
  # regression. That is a spec that fails when the laptop is busy, which is a spec nobody
  # trusts.
  #
  # Minimum fixes it because noise is one-directional: it only ever adds time, so a stall
  # inflates some trials and leaves the fastest one honest. It costs no sensitivity, which
  # is the point — a real regression (the envelope doing per-record work) is paid on every
  # call, so it slows the fastest trial too and still fails here. Both properties were
  # measured rather than assumed: injecting a one-off 300ms stall moved this from 6.65ms
  # to 0.23ms, and adding 6ms of work to every call still failed, at 7.13ms.
  #
  # Interleaved rather than run in two blocks so a machine that gets busy partway through
  # slows both sides rather than whichever happened to be under measurement.
  it "adds no more than 5 ms over running the query directly" do
    warmup = 5
    trials = 30

    # Both sides materialize. The envelope hands back a lazy relation, so timing it
    # without .to_a would flatter it by measuring less work than the baseline does.
    warmup.times do
      Reeve.invoke(tool: MeasuredTool, principal: alice).to_a
      InvoicePolicy.scope(alice, Invoice.all).to_a
    end

    guarded = []
    bare = []
    trials.times do
      guarded << elapsed_ms { Reeve.invoke(tool: MeasuredTool, principal: alice).to_a }
      bare    << elapsed_ms { InvoicePolicy.scope(alice, Invoice.all).to_a }
    end

    overhead = guarded.min - bare.min

    expect(overhead).to be < 5.0,
                        "envelope added #{overhead.round(2)}ms per call (fastest of " \
                        "#{trials}: guarded #{guarded.min.round(2)}ms, bare " \
                        "#{bare.min.round(2)}ms)"
  end

  # The failure this guards against is the tempting one: authorizing each record
  # individually instead of merging the policy scope once.
  it "scopes a relation with a constant number of queries, whatever the row count" do
    queries_for_ten = count_queries { Reeve.invoke(tool: MeasuredTool, principal: alice) }

    400.times { |i| Invoice.create!(number: "B-#{i}", owner_id: alice.id) }
    queries_for_five_hundred = count_queries { Reeve.invoke(tool: MeasuredTool, principal: alice) }

    expect(queries_for_five_hundred).to eq(queries_for_ten)
  end

  it "does not load every record to count a derived result" do
    stub_const("CountTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy
      def call = scoped(Invoice).count
    end)

    queries = capture_queries { Reeve.invoke(tool: CountTool, principal: alice) }

    expect(queries.count { |sql| sql.match?(/SELECT COUNT/i) }).to be >= 1
    expect(queries).to all(satisfy { |sql| !sql.match?(/SELECT "invoices"\.\* FROM "invoices"$/) })
  end

  def capture_queries
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def count_queries(&block)
    capture_queries(&block).size
  end
end
