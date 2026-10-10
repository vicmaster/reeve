# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # Checks the chain and reports every place it no longer holds (specs/002 FR-012–FR-015,
      # research R6).
      #
      # The chain record is read first; its head is where the walk (Walk) stops. After the
      # walk the record is checked against what was found — the genesis against its digest,
      # the head against the last row — and the head is read again. Rows between the two
      # reads are writes that committed during the walk: legitimate, and left for the next
      # run. A row above the second read cannot be legitimate, because reeve commits a row
      # and its head move together, so it is reported. Without that second read, a row
      # forged past the head would never be examined by any run.
      #
      # == What it cannot say
      #
      # A failing digest means the row's content, its position or its predecessor changed;
      # which one is not knowable from the digest, and the report does not guess. Rows
      # written before the chain began are counted, never verified.
      class Verifier
        BATCH_SIZE = 1_000

        RECORD_MISSING = "chained rows exist but the chain record does not"
        UNCHAINED = "a contract-3 row with no digest, written after the chain started (by clock)"

        def initialize(entry_class:, keyring:, batch_size: BATCH_SIZE)
          @entry_class = entry_class
          @keyring = keyring
          @batch_size = batch_size
        end

        def call
          return no_key if keyring.empty?

          record = read_head
          return no_chain if record.nil? && !chained_rows?

          @breaks = []
          walk = walk(record)
          check_record(record, walk)
          head_at_end = record && read_head
          check_beyond_head(head_at_end || record)
          check_unchained(record)

          result(record, head_at_end, walk.last_sequence)
        end

        private

        attr_reader :entry_class, :keyring, :batch_size, :breaks

        def walk(record)
          Walk.new(entry_class: entry_class, keyring: keyring, batch_size: batch_size,
                   link: record&.genesis_digest, report: method(:add))
              .call(record&.head_sequence)
        end

        # A seam as well as a read: the specs wrap it to land a write mid-walk.
        def read_head
          ChainRecord.uncached { ChainRecord.find_by(name: ChainRecord::LEDGER) }
        end

        def check_record(record, walk)
          return add(:chain_record_missing, nil, RECORD_MISSING) if record.nil?

          check_genesis(record)
          head = record.head_sequence
          return if walk.last_sequence == head && walk.last_digest == record.head_digest

          add(:head_mismatch, head,
              "the head is at #{head}, the last chained row found is #{walk.last_sequence}")
        end

        def check_genesis(record)
          key_id = record.genesis_key_id
          secret = keyring.for(key_id)
          if secret.nil?
            return add(:unknown_key, 0, "the genesis is signed by key #{key_id}", nil, key_id)
          end
          return if Canonical.genesis_digest(secret, record) == record.genesis_digest

          add(:genesis_altered, 0, "the genesis does not match its digest")
        end

        def check_beyond_head(record)
          return if record.nil?

          head = record.head_sequence
          detail = "numbered past the head (#{Report.number(head)} at the end of the walk); " \
                   "reeve did not write it"
          beyond = entry_class.where("chain_sequence > ?", head).order(:chain_sequence)
          beyond.pluck(:chain_sequence).each { |sequence| add(:beyond_head, sequence, detail) }
        end

        # Contract-3 rows with no digest, beyond the number that already existed when the
        # chain began (research R5). Which ones are new is known only by clock, and the
        # detail says so.
        def check_unchained(record)
          return if count_unchained <= (record ? record.pre_chain_unchained_count : 0)

          scope = unchained_scope
          scope = scope.where("occurred_at > ?", record.genesis_at) if record
          scope.order(:occurred_at).pluck(:invocation_id).each do |invocation_id|
            add(:unchained, nil, UNCHAINED, invocation_id)
          end
        end

        def add(kind, sequence, detail = nil, invocation_id = nil, key_id = nil)
          breaks << Verification::Break.new(kind: kind, sequence: sequence, detail: detail,
                                            invocation_id: invocation_id, key_id: key_id)
        end

        def result(record, head_at_end, last_sequence)
          Verification.new(
            status: Verification.status_for(breaks), breaks: breaks,
            covered: covered(record, last_sequence),
            head_at_start: record&.head_sequence, head_at_end: head_at_end&.head_sequence,
            uncovered_now: count_uncovered, uncovered_at_genesis: record&.pre_chain_count,
            unchained_now: count_unchained, unchained_at_genesis: record&.pre_chain_unchained_count
          )
        end

        def covered(record, last_sequence)
          last = record ? record.head_sequence : last_sequence
          last.positive? ? 1..last : nil
        end

        def no_key
          Verification.new(status: :unverifiable, reason: :no_key,
                           uncovered_now: count_uncovered, unchained_now: count_unchained)
        end

        def no_chain
          Verification.new(status: :no_chain,
                           uncovered_now: count_uncovered, unchained_now: count_unchained)
        end

        def chained_rows?
          entry_class.where.not(chain_sequence: nil).exists?
        end

        def count_uncovered
          @count_uncovered ||= entry_class.where("contract_version < 3").count
        end

        def count_unchained
          @count_unchained ||= unchained_scope.count
        end

        def unchained_scope
          entry_class.where("contract_version >= 3 AND chain_digest IS NULL")
        end
      end
    end
  end
end
