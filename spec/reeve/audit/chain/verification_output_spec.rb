# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "../support/ledger"

# specs/002 T031 / FR-012, FR-013, FR-017, FR-008, SC-006 — what a verification says.
#
# The wording is the guarantee as much as the status is: a reader who sees "intact" must also
# see, on the same line, how much of the ledger that word covers.
RSpec.describe "a verification's report" do
  let(:verification) { Reeve::Audit::Chain::Verification }
  let(:break_of) { Reeve::Audit::Chain::Verification::Break }
  let(:mismatch) { Reeve::Audit::Chain::Walk::MISMATCH }

  describe "the examples in contracts/ledger-chain.md, exactly" do
    it "states an intact chain with its coverage" do
      result = verification.new(status: :intact, covered: 1..48_211, head_at_start: 48_211,
                                head_at_end: 48_211, uncovered_now: 5_000, uncovered_at_genesis: 5_000)

      expect(result.to_s).to eq(
        "reeve ledger: INTACT — sequences 1–48,211 verified (head at start: 48,211); " \
        "5,000 earlier entries not covered (5,000 when the chain started); not anchored"
      )
    end

    it "states a broken chain, its totals and each break, aligned" do
      breaks = [
        break_of.new(kind: :digest_mismatch, sequence: 1_204, detail: mismatch),
        break_of.new(kind: :missing, sequence: 3_310..3_311, detail: "2 entries not found"),
        break_of.new(kind: :digest_mismatch, sequence: 3_312, detail: mismatch)
      ]
      result = verification.new(status: :broken, covered: 1..48_211, breaks: breaks, head_at_start: 48_211,
                                uncovered_now: 5_000, uncovered_at_genesis: 4_998)

      expect(result.to_s).to eq(<<~REPORT.chomp)
        reeve ledger: BROKEN — 3 breaks in sequences 1–48,211; 5,000 earlier entries not covered (4,998 when the chain started); not anchored
          totals: digest_mismatch 2, missing 1
          #1,204        digest_mismatch  #{mismatch}
          #3,310–3,311  missing          2 entries not found
          #3,312        digest_mismatch  #{mismatch}
      REPORT
    end

    it "states a row past the head" do
      breaks = [break_of.new(kind: :beyond_head, sequence: 48_212,
                             detail: "numbered past the head (48,211 at the end of the walk); reeve did not write it")]
      result = verification.new(status: :broken, covered: 1..48_211, breaks: breaks, head_at_start: 48_211,
                                head_at_end: 48_211, uncovered_now: 5_000, uncovered_at_genesis: 5_000)

      expect(result.to_s).to eq(<<~REPORT.chomp)
        reeve ledger: BROKEN — 1 break in sequences 1–48,211; 5,000 earlier entries not covered (5,000 when the chain started); not anchored
          totals: beyond_head 1
          #48,212       beyond_head      numbered past the head (48,211 at the end of the walk); reeve did not write it
      REPORT
    end

    it "states rows it could not check, and that the rest is not a pass" do
      breaks = Array.new(1_200) do |i|
        break_of.new(kind: :unknown_key, sequence: i + 1, key_id: "9f2c41d07ab3e815")
      end
      result = verification.new(status: :unverifiable, covered: 1..48_211, breaks: breaks,
                                head_at_start: 48_211, uncovered_now: 5_000, uncovered_at_genesis: 5_000)

      expect(result.to_s).to eq(
        "reeve ledger: UNVERIFIABLE — 1,200 entries signed by key 9f2c41d07ab3e815, which is not " \
        "configured; the other 47,011 in 1–48,211 show no breaks, which is not a pass; " \
        "5,000 earlier entries not covered; not anchored"
      )
    end

    # specs/004 FR-014, contracts/anchoring.md "Verification".
    context "with checkpoints" do
      let(:result_of) { Reeve::Audit::Chain::CheckpointCheck::Result }

      def checked(sequence, made_at = "2026-10-25T14:00:00.123456Z", status: :checked)
        result_of.new(head_sequence: sequence, made_at: made_at, key_id: "3fa4b5c6d7e8f901", status: status)
      end

      it "states where an intact chain is anchored, and how many entries come after it" do
        result = verification.new(status: :intact, covered: 1..48_211, head_at_start: 48_211,
                                  head_at_end: 48_211, uncovered_now: 5_000, uncovered_at_genesis: 5_000,
                                  checkpoints: [checked(48_000)], anchored_at: checked(48_000), beyond_anchor: 211)

        expect(result.to_s).to eq(
          "reeve ledger: INTACT — sequences 1–48,211 verified (head at start: 48,211); " \
          "5,000 earlier entries not covered (5,000 when the chain started); " \
          "anchored at #48,000 (checkpoint 2026-10-25 14:00 UTC), 211 entries after it"
        )
      end

      it "says one entry, not one entries" do
        result = verification.new(status: :intact, covered: 1..3, head_at_start: 3, head_at_end: 3,
                                  checkpoints: [checked(2)], anchored_at: checked(2), beyond_anchor: 1)

        expect(result.to_s).to end_with("anchored at #2 (checkpoint 2026-10-25 14:00 UTC), 1 entry after it")
      end

      it "states a checkpoint the ledger no longer reaches, labelled by its sequence" do
        breaks = [break_of.new(kind: :checkpoint_not_reached, sequence: nil, checkpoint: 500,
                               detail: "the head is at 400; entries the checkpoint saw were removed")]
        result = verification.new(status: :broken, covered: 1..400, breaks: breaks, head_at_start: 400,
                                  head_at_end: 400, checkpoints: [checked(300), checked(500, status: :not_reached)],
                                  anchored_at: checked(300, "2026-10-24T14:00:00.000000Z"), beyond_anchor: 100)

        expect(result.to_s).to eq(<<~REPORT.chomp)
          reeve ledger: BROKEN — 1 break in sequences 1–400; 0 earlier entries not covered; anchored at #300 (checkpoint 2026-10-24 14:00 UTC), 100 entries after it
            totals: checkpoint_not_reached 1
            checkpoint #500 checkpoint_not_reached the head is at 400; entries the checkpoint saw were removed
        REPORT
      end

      it "states an emptied ledger that checkpoints saw" do
        breaks = Array.new(3) do |i|
          break_of.new(kind: :checkpoint_not_reached, sequence: nil, checkpoint: i + 1, detail: "the ledger has no chain")
        end
        result = verification.new(status: :broken, breaks: breaks,
                                  checkpoints: [1, 2, 3].map { |n| checked(n, status: :not_reached) })

        expect(result.to_s.lines.first.chomp)
          .to eq("reeve ledger: BROKEN — 3 breaks in the ledger; the ledger has no chain, but 3 checkpoints name one")
      end

      # A checkpoint whose key is missing is not an entry, and is not counted as one.
      it "states a checkpoint it could not check, apart from the entries" do
        breaks = [break_of.new(kind: :unknown_key, sequence: nil, checkpoint: 9, key_id: "9f2c41d07ab3e815")]
        result = verification.new(status: :unverifiable, covered: 1..10, breaks: breaks, head_at_start: 10,
                                  checkpoints: [checked(9, status: :key_not_configured)])

        expect(result.to_s).to eq(
          "reeve ledger: UNVERIFIABLE — 1 checkpoint signed by key 9f2c41d07ab3e815, which is not " \
          "configured; the other 10 in 1–10 show no breaks, which is not a pass; " \
          "0 earlier entries not covered; not anchored"
        )
      end
    end

    # specs/005 FR-011, contracts/retention.md "Verification".
    context "after a purge" do
      let(:summary) { Reeve::Audit::Chain::Retention::Check::Summary }
      let(:boundary) do
        Struct.new(:purge, :through_sequence, :purged_at).new(0, 6_000, Time.utc(2025, 11, 1, 3, 0, 0))
      end

      def retention(removed_pre_chain: 5_000)
        found = summary.new(purge: 0, through_sequence: 6_000, purged_at: boundary.purged_at,
                            removed_chained: 6_000, removed_pre_chain: removed_pre_chain, archived: true,
                            status: :verified)
        Reeve::Audit::Chain::Retention::Check::Result.new(boundary: boundary, summaries: [found])
      end

      it "names the purged range and the record before the coverage, and the pre-chain rows purged" do
        result = verification.new(status: :intact, covered: 6_001..10_000, head_at_start: 10_000,
                                  head_at_end: 10_000, uncovered_now: 0, uncovered_at_genesis: 5_000,
                                  retention: retention)

        expect(result.to_s).to eq(
          "reeve ledger: INTACT — sequences 6,001–10,000 verified (head at start: 10,000); " \
          "1–6,000 purged (retention record 0, 2025-11-01); 0 earlier entries not covered " \
          "(5,000 when the chain started, 5,000 purged); not anchored"
        )
      end

      it "counts rows still awaiting purge" do
        result = verification.new(status: :intact, covered: 6_001..10_000, head_at_start: 10_000,
                                  retention: retention(removed_pre_chain: 0), awaiting_purge: 120)

        expect(result.to_s).to include("1–6,000 purged (retention record 0, 2025-11-01); 120 entries awaiting purge;")
      end

      it "says there was nothing after the purge to verify" do
        result = verification.new(status: :intact, head_at_start: 6_000, retention: retention(removed_pre_chain: 0))

        expect(result.to_s).to start_with("reeve ledger: INTACT — no entries after the purge to verify (head at start: 6,000); 1–6,000 purged")
      end
    end

    it "states that nothing was verified without a key" do
      result = verification.new(status: :unverifiable, reason: :no_key, uncovered_now: 3)

      expect(result.to_s).to eq("reeve ledger: UNVERIFIABLE — no ledger key configured; nothing was verified")
    end

    it "states that nothing was verified without a chain" do
      result = verification.new(status: :no_chain, uncovered_now: 12_000, unchained_now: 4)

      expect(result.to_s).to eq("reeve ledger: NO CHAIN — 12,004 entries, none chained; nothing was verified")
    end
  end

  describe "the break list" do
    let(:breaks) do
      Array.new(150) { |i| break_of.new(kind: :digest_mismatch, sequence: (i * 2) + 1, detail: mismatch) }
    end
    let(:result) { verification.new(status: :broken, covered: 1..300, breaks: breaks, head_at_start: 300) }

    it "lists 100 breaks by default and says how many more there are" do
      lines = result.to_s.lines

      expect(lines.count { |line| line.include?("digest_mismatch  ") }).to eq(100)
      expect(lines.last).to include("and 50 more")
    end

    it "never caps the totals" do
      expect(result.to_s(limit: 0)).to include("totals: digest_mismatch 150")
      expect(result.to_s(limit: 0).lines.size).to eq(2)
    end

    it "names an unchained row by its invocation_id, since it has no sequence" do
      unchained = verification.new(
        status: :broken, covered: 1..2, head_at_start: 2,
        breaks: [break_of.new(kind: :unchained, invocation_id: "inv-late", detail: "written after (by clock)")]
      )

      expect(unchained.to_s.lines.last).to include("inv-late").and include("unchained")
    end
  end

  describe "as JSON" do
    it "carries every field of the result, every break, and ranges as first/last" do
      breaks = [break_of.new(kind: :missing, sequence: 3..4, detail: "2 entries not found")]
      json = JSON.parse(JSON.generate(
                          verification.new(status: :broken, covered: 1..9, breaks: breaks, head_at_start: 9,
                                           head_at_end: 9, uncovered_now: 2, uncovered_at_genesis: 2,
                                           unchained_now: 0, unchained_at_genesis: 0).as_json
                        ))

      expect(json.keys).to contain_exactly(
        "status", "covered", "head_at_start", "head_at_end", "uncovered_now", "uncovered_at_genesis",
        "unchained_now", "unchained_at_genesis", "unverifiable_count", "totals", "breaks", "reason",
        "epochs", "before_first_epoch", "checkpoints", "anchored_at", "beyond_anchor", "walked_from",
        "retention", "awaiting_purge"
      )
      expect(json["status"]).to eq("broken")
      expect(json["covered"]).to eq("first" => 1, "last" => 9)
      expect(json["breaks"]).to eq([{ "kind" => "missing", "sequence" => { "first" => 3, "last" => 4 },
                                      "detail" => "2 entries not found", "invocation_id" => nil,
                                      "key_id" => nil, "epoch" => nil, "checkpoint" => nil,
                                      "retention" => nil }])
      expect(json.values_at("checkpoints", "anchored_at", "beyond_anchor", "walked_from", "retention",
                            "awaiting_purge")).to eq([[], nil, nil, nil, nil, 0])
    end

    it "carries each checkpoint's result and where the run was anchored" do
      found = Reeve::Audit::Chain::CheckpointCheck::Result.new(
        head_sequence: 7, made_at: "2026-10-25T14:00:00.000000Z", key_id: "3fa4b5c6d7e8f901", status: :checked
      )
      json = JSON.parse(JSON.generate(
                          verification.new(status: :intact, covered: 1..9, head_at_start: 9, checkpoints: [found],
                                           anchored_at: found, beyond_anchor: 2).as_json
                        ))

      expect(json["checkpoints"]).to eq([{ "head_sequence" => 7, "made_at" => "2026-10-25T14:00:00.000000Z",
                                           "key_id" => "3fa4b5c6d7e8f901", "status" => "checked" }])
      expect(json["anchored_at"]).to eq("head_sequence" => 7, "made_at" => "2026-10-25T14:00:00.000000Z")
      expect(json["beyond_anchor"]).to eq(2)
    end
  end

  # SC-006 and FR-008 over real ledgers rather than constructed results: every state this
  # spec can build, verified for real, and every line of every report read.
  describe "over every ledger state" do
    let(:chain) { Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry) }

    before { Ledger.prepare! }

    def row(**overrides)
      { invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
        arguments: {}, outcome: "allow", rule: "r", record_ids: [], guard: "policy",
        contract_version: Reeve::Audit::CONTRACT_VERSION }.merge(overrides)
    end

    def legacy!
      Reeve::Audit::Entry.create!(row(contract_version: 2))
    end

    states = {
      "intact, after legacy rows" => lambda {
        2.times { legacy! }
        3.times { chain.append!(row) }
      },
      "broken by a deleted row" => lambda {
        4.times { chain.append!(row) }
        Reeve::Audit::Entry.where(chain_sequence: 2).delete_all
      },
      "broken by a row past the head" => lambda {
        2.times { chain.append!(row) }
        Reeve::Audit::Entry.insert_all!([row(chain_sequence: 3, chain_key_id: "0" * 16, chain_digest: "a" * 64)])
      },
      "unverifiable for want of a retired key" => lambda {
        Reeve.config.ledger_key = "another-ledger-key-not-a-secret-0123456789"
        2.times { chain.append!(row) }
        Reeve.config.ledger_key = Ledger::TEST_KEY
      },
      "unverifiable for want of any key" => lambda {
        chain.append!(row)
        Reeve.config.ledger_key = nil
      },
      "without a chain" => -> { 2.times { legacy! } },
      "intact, anchored" => lambda {
        Reeve.config.ledger_anchor = Ledger::RecordingAnchor.new
        2.times { chain.append!(row) }
        Reeve::Audit::Chain.checkpoint!
        chain.append!(row)
      },
      "broken by a truncated tail, anchored" => lambda {
        Reeve.config.ledger_anchor = Ledger::RecordingAnchor.new
        3.times { chain.append!(row) }
        Reeve::Audit::Chain.checkpoint!
        Ledger.truncate_tail!(after: 1)
      },
      "broken by an emptied ledger, anchored" => lambda {
        Reeve.config.ledger_anchor = Ledger::RecordingAnchor.new
        2.times { chain.append!(row) }
        Reeve::Audit::Chain.checkpoint!
        Ledger.empty!
      },
      "intact, purged" => lambda {
        Reeve.config.ledger_anchor = Ledger::RecordingAnchor.new
        Reeve.config.ledger_retention_connection = Ledger.retention_connection
        4.times { chain.append!(row) }
        Reeve::Audit::Chain.checkpoint!
        chain.append!(row)
        Reeve::Audit::Chain.purge!(through: 4, no_archive: true, confirm: true)
      },
      "unverifiable for want of a checkpoint's key" => lambda {
        Reeve.config.ledger_anchor = Ledger::RecordingAnchor.new
        Reeve.config.ledger_key = "another-ledger-key-not-a-secret-0123456789"
        2.times { chain.append!(row) }
        Reeve::Audit::Chain.checkpoint!
        Reeve.config.ledger_key = Ledger::TEST_KEY
        Reeve.config.retired_ledger_keys = []
      }
    }

    states.each do |label, build|
      context label do
        before { instance_exec(&build) }

        let(:result) { Reeve::Audit::Chain.verify }
        let(:reports) { [result.to_s, result.to_s(limit: 0), JSON.generate(result.as_json)] }

        it "never says intact or pass without the covered range and the uncovered count beside it" do
          result.to_s.lines.grep(/intact|pass/i).each do |line|
            expect(line).to match(/\d[\d,]*–\d[\d,]*/), "no covered range on: #{line}"
            expect(line).to match(/not covered/), "no uncovered count on: #{line}"
          end
        end

        # specs/004 SC-003: anchoring is part of what a walked result means.
        it "states the anchoring on the summary line of every result that walked the chain" do
          next if result.head_at_start.nil?

          expect(result.to_s.lines.first).to match(/; (not anchored|anchored at #[\d,]+ \(checkpoint .+\), [\d,]+ entr(y|ies) after it)$/)
        end

        it "is a success only when intact" do
          expect(result.intact?).to be(label.start_with?("intact"))
        end

        it "never prints a key, only fingerprints" do
          secrets = [Ledger::TEST_KEY, "another-ledger-key-not-a-secret-0123456789"]
          reports.each { |report| secrets.each { |secret| expect(report).not_to include(secret) } }
        end
      end
    end
  end
end
