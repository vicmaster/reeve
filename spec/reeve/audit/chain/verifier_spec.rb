# frozen_string_literal: true

require "securerandom"
require_relative "../support/ledger"

# specs/002 T021 / FR-015, research R6 — the walk: what it reads, in what order, how much at
# a time, and where it stops. Statuses and wording are T030/T031.
RSpec.describe Reeve::Audit::Chain::Verifier do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:keyring) { Reeve::Audit::Chain::Keyring.from(Reeve.config) }

  before { Ledger.prepare! }

  def row(**overrides)
    { invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
      arguments: {}, outcome: "allow", rule: "r", record_ids: [], guard: "policy",
      contract_version: Reeve::Audit::CONTRACT_VERSION }.merge(overrides)
  end

  def verifier(**options)
    described_class.new(entry_class: Reeve::Audit::Entry, keyring: keyring, **options)
  end

  def sql_during
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "reports an untouched chain intact over every sequence" do
    5.times { chain.append!(row) }

    result = verifier.call

    expect(result.status).to eq(:intact)
    expect(result.covered).to eq(1..5)
    expect(result.breaks).to be_empty
    expect(result.head_at_start).to eq(5)
  end

  it "reads in batches, so memory does not grow with the ledger" do
    5.times { chain.append!(row) }

    # The batch reads are the ordered, limited ones; the end-of-walk beyond-head check is
    # ordered too but reads only sequence numbers, and has no limit.
    walk = sql_during { verifier(batch_size: 2).call }
           .grep(/FROM\s+["`]?reeve_audit_entries["`]?.*ORDER BY.*chain_sequence.*LIMIT/im)

    expect(walk.size).to eq(3) # 2 + 2 + 1
    expect(walk).to all(match(/LIMIT\s+(2|\?|\$\d+)/i))
  end

  # Review finding: the chain record is written through the ledger's connection but read
  # through its own model's. On different databases the verifier would read the wrong one
  # and report tampering; it refuses instead, naming the fix.
  it "refuses to verify when the chain record is on a different database than the ledger" do
    other = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "audit", { adapter: "sqlite3", database: "elsewhere" })
    allow(Reeve::Audit::ChainRecord).to receive(:connection_db_config).and_return(other)

    expect { verifier.call }.to raise_error(Reeve::ConfigurationError, /ChainRecord/)
  end

  # SC-004 on PostgreSQL: the resume condition `chain_sequence > s OR (chain_sequence = s AND
  # id > i)` was applied as a filter, so every batch scanned from the first row and the walk
  # was quadratic — 1M rows took 331 s against a 300 s budget. A batch must start its index
  # scan where the last one stopped. Pinned through the database's own plan rather than a
  # timing, which would flake.
  # How PostgreSQL would use the index, whatever it would rather do. On a five-row table
  # with fresh statistics it prefers a sequential scan — which says nothing about the walk,
  # and made this example pass or fail by the planner's mood (CI, run 38063799086). The
  # ANALYZE puts the statistics in that state on purpose; enable_seqscan, set for this
  # transaction only, takes the planner's preference out of the question.
  def postgresql_index_plan(sql)
    connection = ActiveRecord::Base.connection
    connection.execute("ANALYZE reeve_audit_entries")
    connection.transaction do
      connection.execute("SET LOCAL enable_seqscan = off")
      connection.select_values("EXPLAIN #{sql}").join("\n")
    end
  end

  it "starts each batch's index scan where the previous batch stopped" do
    5.times { chain.append!(row) }
    walk = Reeve::Audit::Chain::Walk.new(entry_class: Reeve::Audit::Entry, keyring: keyring,
                                         batch_size: 2, link: nil, report: ->(*) {},
                                         epochs: Reeve::Audit::Chain::EpochRules.new([], keyring: keyring))
    batch = walk.send(:batch_scope, [3, Reeve::Audit::Entry.where(chain_sequence: 3).pick(:id)], 5)
    plan = case SpecDatabase.adapter
           when "postgresql" then postgresql_index_plan(batch.to_sql)
           when "sqlite3" then ActiveRecord::Base.connection.select_rows("EXPLAIN QUERY PLAN #{batch.to_sql}").flatten.join(" ")
           else skip("the plan is read on PostgreSQL and SQLite; MySQL is covered by the benchmark")
           end

    lower_bound = SpecDatabase.sqlite? ? /chain_sequence>\?/ : /Index Cond:.*chain_sequence >=/
    expect(plan).to match(lower_bound), "the batch scans from the start of the index:\n#{plan}"
  end

  it "uses a default batch of 1,000 rows" do
    expect(described_class::BATCH_SIZE).to eq(1_000)
  end

  # FR-015: verification takes no lock and holds no transaction open for its duration.
  it "opens no transaction" do
    3.times { chain.append!(row) }

    statements = sql_during { verifier.call }

    expect(statements.grep(/\A\s*(BEGIN|SAVEPOINT|START TRANSACTION)/i)).to be_empty
  end

  describe "where the walk stops" do
    # A write that commits while the walk is under way is legitimate. It is beyond the head
    # read at the start, so it is not verified this time — and not reported either.
    it "verifies up to the head read at the start and ignores writes committed during the walk" do
      3.times { chain.append!(row) }
      walker = verifier
      reads = 0
      allow(walker).to receive(:read_head).and_wrap_original do |original|
        head = original.call
        chain.append!(row) if (reads += 1) == 1
        head
      end

      result = walker.call

      expect(result.head_at_start).to eq(3)
      expect(result.head_at_end).to eq(4)
      expect(result.covered).to eq(1..3)
      expect(result.status).to eq(:intact)
    end

    # Review finding: a write that commits between the head's second read and the search for
    # rows past it is legitimate, and must not be reported as forged.
    it "does not report a row written between the second head read and the beyond-head search" do
      3.times { chain.append!(row) }
      walker = verifier
      reads = 0
      allow(walker).to receive(:read_head).and_wrap_original do |original|
        head = original.call
        chain.append!(row) if (reads += 1) == 2
        head
      end

      result = walker.call

      expect(result.breaks).to be_empty
      expect(result.status).to eq(:intact)
    end

    # research R6: reeve never leaves a committed row past a committed head, because the row
    # and the head move commit together. A row above the head re-read at the end was not
    # written by reeve, and without this second read no run would ever look at it.
    it "reports a chained row above the head read at the end as beyond_head" do
      3.times { chain.append!(row) }
      forged = row.merge(chain_sequence: 4, chain_key_id: Reeve.config.ledger_key_id, chain_digest: "f" * 64)
      Reeve::Audit::Entry.insert_all!([Reeve::Audit::Chain::Normalizer.new(Reeve::Audit::Entry).call(forged)])

      result = verifier.call

      expect(result.status).to eq(:broken)
      expect(result.breaks.map { |b| [b.kind, b.sequence] }).to include([:beyond_head, 4])
    end
  end

  # specs/002 T030 / FR-012, FR-014, data-model "Status rules": each ledger reported for
  # what it is, and none of them as a pass unless it is one.
  describe "status" do
    let(:other_key) { "another-ledger-key-not-a-secret-0123456789" }

    # A row as 0.5.0 wrote it, or as :warn writes one with no key: around the chain.
    def unchained!(contract_version:, occurred_at: Time.now)
      Reeve::Audit::Entry.create!(row(contract_version: contract_version, occurred_at: occurred_at))
    end

    def call
      Reeve::Audit::Chain.verify
    end

    it "is unverifiable with no key, and claims nothing else" do
      3.times { chain.append!(row) }
      Reeve.config.ledger_key = nil

      result = call

      expect(result.status).to eq(:unverifiable)
      expect(result.reason).to eq(:no_key)
      expect(result.covered).to be_nil
      expect(result.breaks).to be_empty
      expect(result).not_to be_intact
    end

    # The genesis is written just before the first chained write, in a step of its own; if
    # that write then fails, a started chain with nothing in it remains. Nothing was
    # verified, so it is no chain — not an intact chain of zero rows.
    it "is no_chain for a chain that was started but holds nothing yet" do
      Reeve::Audit::Chain::Head.new(connection: ActiveRecord::Base.connection, entry_class: Reeve::Audit::Entry)
                               .start!(keyring)

      result = call

      expect(Reeve::Audit::ChainRecord.ledger.head_sequence).to eq(0)
      expect(result.status).to eq(:no_chain)
    end

    it "reports a row forged into a started, empty chain as past the head" do
      Reeve::Audit::Chain::Head.new(connection: ActiveRecord::Base.connection, entry_class: Reeve::Audit::Entry)
                               .start!(keyring)
      Reeve::Audit::Entry.insert_all!([
                                        Reeve::Audit::Chain::Normalizer.new(Reeve::Audit::Entry).call(
                                          row(chain_sequence: 1, chain_key_id: Reeve.config.ledger_key_id, chain_digest: "f" * 64)
                                        )
                                      ])

      # Exactly that: a head at 0 links to the genesis, so it is not also a head mismatch.
      expect(call.breaks.map { |b| [b.kind, b.sequence] }).to eq([[:beyond_head, 1]])
    end

    it "is no_chain when nothing was ever chained, and counts what is there" do
      2.times { unchained!(contract_version: 2) }

      result = call

      expect(result.status).to eq(:no_chain)
      expect(result.uncovered_now).to eq(2)
      expect(result).not_to be_intact
    end

    # A host on :warn ran without a key, then configured one. Those rows predate the chain.
    it "counts unchained contract-3 rows from before the chain as uncovered, not as breaks" do
      unchained!(contract_version: 3, occurred_at: Time.now - 60)
      2.times { chain.append!(row) }

      result = call

      expect(result.status).to eq(:intact)
      expect(result.unchained_now).to eq(1)
      expect(result.unchained_at_genesis).to eq(1)
    end

    it "reports an unchained contract-3 row written after the chain started, by invocation_id" do
      2.times { chain.append!(row) }
      late = unchained!(contract_version: 3, occurred_at: Time.now + 1)

      result = call

      expect(result.status).to eq(:broken)
      unchained = result.breaks.select { |b| b.kind == :unchained }
      expect(unchained.map(&:invocation_id)).to eq([late.invocation_id])
      expect(unchained.first.sequence).to be_nil
      expect(unchained.first.detail).to include("by clock")
    end

    # The count is the safeguard, not the clock: a row written before the chain began by a
    # server whose clock runs ahead still predates the chain, and must not read as a break.
    it "trusts the count over a skewed clock for rows from before the chain" do
      unchained!(contract_version: 3, occurred_at: Time.now + 3600)
      chain.append!(row)

      expect(call.status).to eq(:intact)
    end

    # And once the count is exceeded, the clock narrows which rows to name: the ones from
    # before the chain are not listed alongside the new one.
    it "names only the unchained rows written after the chain started" do
      unchained!(contract_version: 3, occurred_at: Time.now - 60)
      chain.append!(row)
      late = unchained!(contract_version: 3, occurred_at: Time.now + 1)

      expect(call.breaks.select { |b| b.kind == :unchained }.map(&:invocation_id)).to eq([late.invocation_id])
    end

    it "is unverifiable — not intact, not tampered — for rows signed by a key it does not hold" do
      Reeve.config.ledger_key = other_key
      2.times { chain.append!(row) }
      Reeve.config.ledger_key = Ledger::TEST_KEY
      chain.append!(row)

      result = call

      expect(result.status).to eq(:unverifiable)
      # Two rows, the genesis they hang from, and the record of the epoch the missing key
      # opened (specs/003): a record nobody could check is counted, never passed over.
      expect(result.unverifiable_count).to eq(4)
      expect(result.breaks.map(&:kind).uniq).to eq([:unknown_key])
    end

    it "verifies rows signed by a retired key" do
      Reeve.config.ledger_key = other_key
      2.times { chain.append!(row) }
      Reeve.config.ledger_key = Ledger::TEST_KEY
      Reeve.config.retired_ledger_keys = [other_key]
      chain.append!(row)

      result = call

      expect(result.status).to eq(:intact)
      expect(result.covered).to eq(1..3)
    end

    # Servers still on 0.5.0 keep writing contract-2 rows during a rolling deploy. They are
    # uncovered by definition; calling them tampering would make every deploy an attack.
    it "stays intact through a rolling deploy, reporting the uncovered count then and now" do
      unchained!(contract_version: 2)
      chain.append!(row)
      2.times { unchained!(contract_version: 2) }

      result = call

      expect(result.status).to eq(:intact)
      expect(result.uncovered_at_genesis).to eq(1)
      expect(result.uncovered_now).to eq(3)
    end
  end
end
