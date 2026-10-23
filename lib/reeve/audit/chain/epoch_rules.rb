# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # The key epochs as verification sees them (specs/003 FR-011): read once, then asked
      # about every row the walk visits. Counts, as it goes, the rows that named each epoch and
      # the rows chained before the first, for the report.
      #
      # A row at contract 4 names its epoch, and must carry that epoch's key and not precede
      # its start. A contract-3 row names none: before the first epoch it is checked exactly
      # as 0.6.0 checked it; after, a key the verifier holds lets the row's digest speak for
      # it, and a key it lacks must at least be one some epoch had opened by then — anything
      # else is a key id nobody issued.
      class EpochRules
        attr_reader :records, :counts, :before_first_epoch, :summaries

        # Every epoch record, in one query whatever the ledger's size (FR-014).
        def self.read(keyring:)
          new(ChainEpoch.uncached { ChainEpoch.all.to_a }, keyring: keyring)
        end

        # `records` are ChainEpoch rows, in any order.
        def initialize(records, keyring:)
          @records = records.sort_by(&:epoch).freeze
          @keyring = keyring
          @by_number = @records.to_h { |record| [record.epoch, record] }
          @first_start = @records.map(&:first_sequence).min
          @counts = Hash.new(0)
          @before_first_epoch = 0
          @summaries = []
        end

        # Checks the records themselves once the walk has counted their rows (EpochCheck);
        # `head` is the chain record as read after the walk. Leaves the result in `summaries`.
        def check!(record, head, report:)
          @summaries = EpochCheck.new(keyring: keyring, report: report)
                                 .call(self, genesis_digest: record&.genesis_digest, head: head)
        end

        # [kind, detail] for a row that contradicts the epoch records, or nil.
        def judge(entry)
          if Integer(entry.contract_version) >= EPOCH_CONTRACT
            epoch_bearing(entry)
          elsif before_first?(entry.chain_sequence)
            @before_first_epoch += 1
            nil
          else
            unepoched(entry)
          end
        end

        private

        attr_reader :keyring

        def epoch_bearing(entry)
          number = entry.chain_epoch
          epoch = number && @by_number[number]
          return [:epoch_missing, missing(number)] unless epoch

          @counts[number] += 1
          if epoch.key_id != entry.chain_key_id
            [:epoch_mismatch,
             "signed by key #{entry.chain_key_id}, but epoch #{number}'s key is #{epoch.key_id}"]
          elsif entry.chain_sequence < epoch.first_sequence
            [:epoch_mismatch,
             "names epoch #{number}, which begins at sequence #{epoch.first_sequence}"]
          end
        end

        def unepoched(entry)
          key_id = entry.chain_key_id
          return nil if keyring.for(key_id) || opened_by?(key_id, entry.chain_sequence)

          [:epoch_mismatch,
           "signed by key #{key_id}, which no key epoch had opened by this position"]
        end

        # True for a row chained before any epoch began — and for every row when none has.
        def before_first?(sequence)
          @first_start.nil? || sequence < @first_start
        end

        def opened_by?(key_id, sequence)
          @records.any? { |record| record.key_id == key_id && record.first_sequence <= sequence }
        end

        def missing(number)
          number.nil? ? "names no key epoch" : "names epoch #{number}, which has no record"
        end
      end

      # The epoch records themselves (specs/003 FR-010): numbered 0..n, each beginning after
      # the one before and no later than one past the head, one key each, and each matching
      # its digest — which links it to the epoch before, or, for epoch 0, to the genesis. A
      # record whose key is not configured cannot be checked, and that is said, never passed
      # over. Returns one Verification::EpochSummary per record; breaks go to `report`, as
      # (kind, nil, detail, nil, key_id, epoch:) — the verifier's own `add`.
      class EpochCheck
        def initialize(keyring:, report:)
          @keyring = keyring
          @report = report
        end

        # `head` is the chain record as read after the walk — later than the epochs were
        # read, so an epoch a rotation opened mid-run is never taken for one past the head.
        def call(rules, genesis_digest:, head:)
          previous = { digest: genesis_digest, first_sequence: 0, keys: [] }
          expected = 0
          rules.records.map do |epoch|
            (expected...epoch.epoch).each do |gap|
              report(:epoch_missing, gap, "epoch #{gap} has no record")
            end
            expected = epoch.epoch + 1
            summary(epoch, rules.counts[epoch.epoch], check(epoch, previous, head)).tap do
              previous = { digest: epoch.epoch_digest, first_sequence: epoch.first_sequence,
                           keys: previous[:keys] + [epoch.key_id] }
            end
          end
        end

        private

        attr_reader :keyring

        # :altered, :key_not_configured or :verified, reporting what makes it so.
        def check(epoch, previous, head)
          problem = out_of_place(epoch, previous, head) || digest_problem(epoch, previous)
          return :altered.tap { report(:epoch_altered, epoch.epoch, problem) } if problem
          return :verified if keyring.for(epoch.key_id)

          report(:unknown_key, epoch.epoch, "epoch #{epoch.epoch} is signed by key #{epoch.key_id}",
                 epoch.key_id)
          :key_not_configured
        end

        def report(kind, number, detail, key_id = nil)
          @report.call(kind, nil, detail, nil, key_id, epoch: number)
        end

        def out_of_place(epoch, previous, head)
          name = "epoch #{epoch.epoch}"
          if epoch.epoch.positive? && epoch.first_sequence <= previous[:first_sequence]
            "#{name} begins at sequence #{epoch.first_sequence}, not after the epoch before it"
          elsif head && epoch.first_sequence > head.head_sequence + 1
            "#{name} begins at sequence #{epoch.first_sequence}, past the head"
          elsif previous[:keys].include?(epoch.key_id)
            "#{name} reuses the key of an earlier epoch"
          end
        end

        def digest_problem(epoch, previous)
          secret = keyring.for(epoch.key_id)
          return nil if secret.nil? || previous[:digest].nil?

          expected = Canonical.epoch_digest(secret, epoch, previous_digest: previous[:digest])
          "epoch #{epoch.epoch} does not match its digest" unless expected == epoch.epoch_digest
        end

        def summary(epoch, count, status)
          Verification::EpochSummary.new(epoch: epoch.epoch, key_id: epoch.key_id,
                                         first_sequence: epoch.first_sequence, entry_count: count,
                                         status: status)
        end
      end
    end
  end
end
