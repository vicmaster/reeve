# frozen_string_literal: true

require "securerandom"
require_relative "../support/ledger"

# specs/002 T020 / FR-001, FR-004, FR-005, FR-007, FR-022; research R3, R4.
#
# Chain#append! is the one place a chained row is born. Everything a verifier later relies
# on — consecutive sequences, each digest linking to the one before, a genesis written
# exactly once — is established here or not at all.
RSpec.describe "Reeve::Audit::Chain#append!" do
  let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }
  let(:key) { Ledger::TEST_KEY }
  let(:canonical) { Reeve::Audit::Chain::Canonical }

  before { Ledger.prepare! }

  def row(**overrides)
    {
      invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "claude-desktop",
      tool_name: "invoice_search", arguments: { query: "acme" }, outcome: "allow",
      rule: "InvoicePolicy#index?", record_ids: %w[1 2], record_count: 2, guard: "policy",
      contract_version: Reeve::Audit::CONTRACT_VERSION
    }.merge(overrides)
  end

  def entries
    Reeve::Audit::Entry.where.not(chain_sequence: nil).order(:chain_sequence).to_a
  end

  # A row as 0.5.0 wrote it, or as `:warn` writes one with no key: straight into the
  # table, around the chain.
  def unchained!(contract_version:)
    Reeve::Audit::Entry.create!(row(contract_version: contract_version).merge(arguments: {}))
  end

  def record
    Reeve::Audit::ChainRecord.ledger
  end

  describe "sequencing (FR-001, FR-004)" do
    it "numbers entries 1..n with no gaps, signed by the configured key" do
      5.times { chain.append!(row) }

      expect(entries.map(&:chain_sequence)).to eq([1, 2, 3, 4, 5])
      expect(entries.map(&:chain_key_id).uniq).to eq([Reeve.config.ledger_key_id])
    end

    it "links each digest to the one before it, and the first to the genesis" do
      3.times { chain.append!(row) }

      previous = record.genesis_digest
      entries.each do |entry|
        expect(entry.chain_digest).to eq(canonical.entry_digest(key, entry, previous_digest: previous))
        previous = entry.chain_digest
      end
    end

    # The digest must be computed over what is stored, not over what was passed: column
    # defaults fill in what the caller omitted, and assignment casts what it got wrong.
    it "signs the values the database stores, defaults and casts included" do
      chain.append!(row(principal_id: 42, record_count: "2").except(:record_ids).merge(record_ids: []))

      expect(Reeve::Audit::Chain.verify.status).to eq(:intact)
      expect(entries.first.principal_id).to eq("42")
      expect(entries.first.truncated).to be(false)
    end

    it "returns the entry it wrote" do
      entry = chain.append!(row(invocation_id: "inv-returned"))

      expect(entry).to be_a(Reeve::Audit::Entry)
      expect(entry).to be_persisted
      expect(entry.invocation_id).to eq("inv-returned")
      expect(entry.chain_sequence).to eq(1)
    end
  end

  describe "the genesis (FR-022)" do
    it "is created with the first chained entry, as link 0" do
      expect(record).to be_nil

      chain.append!(row)

      expect(record).not_to be_nil
      expect(record.genesis_key_id).to eq(Reeve.config.ledger_key_id)
      expect(record.genesis_digest).to eq(canonical.genesis_digest(key, record))
    end

    it "counts the rows already in the ledger, and separately the unchained contract-3 ones" do
      2.times { unchained!(contract_version: 2) }
      unchained!(contract_version: 3)

      chain.append!(row)

      expect(record.pre_chain_count).to eq(2)
      expect(record.pre_chain_unchained_count).to eq(1)
    end

    it "moves the head with every write" do
      3.times { chain.append!(row) }

      expect(record.head_sequence).to eq(3)
      expect(record.head_digest).to eq(entries.last.chain_digest)
    end

    it "is never written twice" do
      3.times { chain.append!(row) }

      expect(Reeve::Audit::ChainRecord.count).to eq(1)
    end
  end

  describe "a replayed invocation" do
    it "returns the existing entry and consumes no sequence" do
      first = chain.append!(row(invocation_id: "inv-replayed"))
      head_before = record.attributes

      again = chain.append!(row(invocation_id: "inv-replayed"))

      expect(again.id).to eq(first.id)
      expect(Reeve::Audit::Entry.count).to eq(1)
      expect(record.reload.attributes).to eq(head_before)
    end

    # The race the pre-check cannot see: the same invocation_id lands between the check and
    # the insert. The insert then fails on the unique invocation_id, and the head move made
    # before it must be undone with it — or the next write leaves a gap that reads exactly
    # like a deleted row.
    it "returns the existing entry and leaves the head alone when the replay races past the pre-check" do
      first = chain.append!(row(invocation_id: "inv-raced"))
      head_before = record.attributes
      checks = 0
      allow(chain).to receive(:replayed).and_wrap_original do |original, *args|
        (checks += 1) == 1 ? nil : original.call(*args)
      end

      again = chain.append!(row(invocation_id: "inv-raced"))

      expect(again.id).to eq(first.id)
      expect(Reeve::Audit::Entry.count).to eq(1)
      expect(record.reload.attributes).to eq(head_before)
      expect(chain.append!(row).chain_sequence).to eq(2)
    end
  end

  # FR-005: the row and the head commit together. A rollback that takes one must take the
  # other, or the next write leaves a gap that reads exactly like a deleted row.
  describe "a rollback of the host's transaction" do
    it "takes the row and the head move with it, so the next write reuses the sequence" do
      chain.append!(row)

      ActiveRecord::Base.transaction do
        chain.append!(row(invocation_id: "inv-rolled-back"))
        raise ActiveRecord::Rollback
      end

      expect(Reeve::Audit::Entry.find_by(invocation_id: "inv-rolled-back")).to be_nil
      expect(record.reload.head_sequence).to eq(1)
      expect(chain.append!(row).chain_sequence).to eq(2)
    end

    it "takes the chain record too, when the rolled-back write was the one that created it" do
      ActiveRecord::Base.transaction do
        chain.append!(row)
        raise ActiveRecord::Rollback
      end

      expect(record).to be_nil
      expect(chain.append!(row).chain_sequence).to eq(1)
    end
  end

  # Two processes both see "no chain yet" and both try to start one. The unique name lets
  # exactly one through; the other must chain after it rather than fail the invocation.
  describe "two writers racing to start the chain" do
    before do
      skip("needs concurrent writers — run with DB=postgresql or DB=mysql2") if SpecDatabase.sqlite?
    end

    it "ends with one chain record and sequences 1 and 2" do
      gate = Queue.new
      threads = Array.new(2) do |i|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            gate.pop
            chain.append!(row(invocation_id: "racer-#{i}"))
          end
        end
      end
      2.times { gate << :go }
      threads.each(&:join)

      expect(Reeve::Audit::ChainRecord.count).to eq(1)
      expect(entries.map(&:chain_sequence)).to eq([1, 2])
      expect(record.reload.head_sequence).to eq(2)
    end
  end

  describe "with no key configured" do
    before { Reeve.config.ledger_key = nil }

    it "raises LedgerKeyError and writes nothing — failing closed is the caller's to soften" do
      expect { chain.append!(row) }.to raise_error(Reeve::LedgerKeyError)

      expect(Reeve::Audit::Entry.count).to eq(0)
      expect(record).to be_nil
    end
  end

  # FR-007: a host with its own recorder can still produce a chain, through the same door.
  describe "a host-supplied recorder" do
    let(:host_recorder) do
      Class.new do
        def self.record(attributes)
          row = attributes.slice(:invocation_id, :occurred_at, :agent_id, :tool_name, :outcome, :rule)
                          .merge(arguments: attributes[:arguments] || {}, record_ids: [], guard: "policy",
                                 contract_version: Reeve::Audit::CONTRACT_VERSION)
          Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry).append!(row)
        end
      end
    end

    it "produces rows that verify intact" do
      3.times do
        host_recorder.record(invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a",
                             tool_name: "t", outcome: "allow", rule: "r", arguments: { a: 1 })
      end

      result = Reeve::Audit::Chain.verify

      expect(result.status).to eq(:intact)
      expect(result.covered).to eq(1..3)
    end
  end
end
