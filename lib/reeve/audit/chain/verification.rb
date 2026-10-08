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
        Break = Struct.new(:kind, :sequence, :detail, :invocation_id, keyword_init: true)

        KINDS = %i[
          digest_mismatch missing duplicate unchained head_mismatch beyond_head
          genesis_altered chain_record_missing unknown_key
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
                    :reason

        def initialize(status:, covered: nil, breaks: [], head_at_start: nil, head_at_end: nil,
                       uncovered_now: 0, uncovered_at_genesis: nil, unchained_now: 0,
                       unchained_at_genesis: nil, reason: nil)
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
      end
    end
  end
end
