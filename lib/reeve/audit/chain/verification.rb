# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # What a verification established, and — as importantly — what it did not
      # (specs/002 FR-012–FR-014, data-model "Verification result").
      #
      # The status says whether the chain held; the coverage says over what. They are
      # separate fields so that no reader can take one for the other: an intact chain that
      # covers the last 300 rows of a ledger of 5,300 is intact *for those 300*.
      class Verification
        STATUSES = %i[intact broken unverifiable no_chain].freeze

        # `sequence` is an Integer or a Range (a gap), or nil for a break that has no
        # position; an unchained row has none and is named by `invocation_id` instead.
        # `key_id` is set for unknown_key: the fingerprint of the key the verifier lacked.
        # `epoch` is set for a break about a key epoch's record (specs/003), whose sequence is nil.
        Break = Struct.new(:kind, :sequence, :detail, :invocation_id, :key_id, :epoch,
                           keyword_init: true)

        # One key epoch as verification found it (specs/003 FR-013). `entry_count` counts the
        # walked rows that named it; `status` is :verified, :key_not_configured or :altered.
        EpochSummary = Struct.new(:epoch, :key_id, :first_sequence, :entry_count, :status,
                                  keyword_init: true) do
          def as_json(*)
            { "epoch" => epoch, "key_id" => key_id, "first_sequence" => first_sequence,
              "entries" => entry_count, "status" => status.to_s }
          end
        end

        EPOCH_STATUSES = %i[verified key_not_configured altered].freeze

        DEFAULT_LIMIT = 100

        KINDS = %i[
          digest_mismatch missing duplicate unchained head_mismatch beyond_head
          genesis_altered chain_record_missing unknown_key
          epoch_missing epoch_mismatch epoch_altered
        ].freeze

        # The status rules (data-model), for a verification that had a key and found a
        # chain; the no-key and no-chain answers are given before a walk ever starts. Any
        # break but an unknown key is a broken chain. Rows only an absent key could check
        # leave it unverifiable — never intact, and never called tampered.
        def self.status_for(breaks)
          kinds = breaks.map(&:kind)
          return :broken if (kinds - [:unknown_key]).any?
          return :unverifiable if kinds.include?(:unknown_key)

          :intact
        end

        attr_reader :status, :covered, :breaks, :head_at_start, :head_at_end,
                    :uncovered_now, :uncovered_at_genesis, :unchained_now, :unchained_at_genesis,
                    :reason, :epochs, :before_first_epoch

        def initialize(status:, covered: nil, breaks: [], head_at_start: nil, head_at_end: nil,
                       uncovered_now: 0, uncovered_at_genesis: nil, unchained_now: 0,
                       unchained_at_genesis: nil, reason: nil, epochs: [], before_first_epoch: nil)
          raise ArgumentError, "unknown status #{status.inspect}" unless STATUSES.include?(status)

          @status = status
          @covered = covered
          @breaks = breaks.freeze
          @head_at_start = head_at_start
          @head_at_end = head_at_end
          @uncovered_now = uncovered_now
          @uncovered_at_genesis = uncovered_at_genesis
          @unchained_now = unchained_now
          @unchained_at_genesis = unchained_at_genesis
          @reason = reason
          @epochs = epochs.freeze
          @before_first_epoch = before_first_epoch
          freeze
        end

        def intact?
          status == :intact
        end

        # Never capped, whatever the display does with the list.
        def totals
          breaks.each_with_object(Hash.new(0)) { |b, counts| counts[b.kind] += 1 }
        end

        def unverifiable_count
          totals[:unknown_key]
        end

        # The report a person reads (contracts/ledger-chain.md "Output"). The first line
        # states the status and what it covers together; no line says "intact" or "pass"
        # without the covered range and the uncovered count beside it (SC-006). `limit`
        # caps the breaks listed, never the totals.
        def to_s(limit: DEFAULT_LIMIT)
          Report.new(self).to_s(limit: limit)
        end

        def as_json(*)
          {
            "status" => status.to_s, "covered" => range_json(covered),
            "head_at_start" => head_at_start, "head_at_end" => head_at_end,
            "uncovered_now" => uncovered_now, "uncovered_at_genesis" => uncovered_at_genesis,
            "unchained_now" => unchained_now, "unchained_at_genesis" => unchained_at_genesis,
            "unverifiable_count" => unverifiable_count,
            "totals" => totals.transform_keys(&:to_s), "reason" => reason&.to_s
          }.merge(listing_json)
        end

        private

        def listing_json
          { "breaks" => breaks.map { |b| break_json(b) }, "epochs" => epochs.map(&:as_json),
            "before_first_epoch" => before_first_epoch }
        end

        def break_json(found)
          {
            "kind" => found.kind.to_s, "sequence" => range_json(found.sequence),
            "detail" => found.detail, "invocation_id" => found.invocation_id,
            "key_id" => found.key_id, "epoch" => found.epoch
          }
        end

        def range_json(value)
          value.is_a?(Range) ? { "first" => value.first, "last" => value.last } : value
        end
      end
    end
  end
end
