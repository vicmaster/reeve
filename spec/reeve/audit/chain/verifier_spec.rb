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
end
