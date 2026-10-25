# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # The verifier's row-by-row pass (research R6): every chained row up to a sequence, in
      # order, a batch at a time.
      #
      # Each row's digest is recomputed against its predecessor's *recorded* digest, not a
      # recomputed one, so one edited row is one break rather than a cascade to the end of
      # the ledger. Gaps and repeated sequences are reported where they occur.
      #
      # Keyset pagination on (chain_sequence, id), never OFFSET, and never inside a
      # transaction: memory stays flat whatever the ledger's size, and no writer waits.
      class Walk
        MISMATCH = "does not verify at its position — its content, its sequence number or " \
                   "its predecessor changed"

        attr_reader :last_sequence, :last_digest

        # `link` is the digest the first row must link to (the genesis), or nil when there
        # is no chain record to take it from. `report` receives (kind, sequence, detail).
        # `epochs` is the EpochRules the rows are checked against (specs/003 FR-011).
        #
        # `start` is the sequence of a checkpoint the walk begins after (specs/004 FR-015), with
        # `link` its digest: the walk is then exactly the one from the genesis, resumed there.
        def initialize(entry_class:, keyring:, batch_size:, link:, report:, epochs:, start: 0)
          @entry_class = entry_class
          @keyring = keyring
          @batch_size = batch_size
          @report = report
          @epochs = epochs
          @start = start
          @expected = start + 1
          @last_sequence = start
          @last_digest = start.positive? ? link : nil
          @link = link
          @verify_first_link = !link.nil?
        end

        # Walks up to `limit` (the head read at the start), or every chained row if nil.
        def call(limit)
          each_chained(limit) { |entry| visit(entry) }
          self
        end

        private

        attr_reader :entry_class, :keyring, :batch_size, :epochs

        def visit(entry)
          sequence = entry.chain_sequence
          return revisit(entry) if sequence == @last_sequence

          report_gap(@expected..(sequence - 1)) if sequence > @expected
          verify(entry, @link)
          advance(entry)
        end

        def report_gap(range)
          count = range.size
          @report.call(:missing, range, "#{count} #{count == 1 ? 'entry' : 'entries'} not found")
        end

        # A second row claiming the sequence just seen: reported, and checked against the
        # same predecessor the first one was.
        def revisit(entry)
          @report.call(:duplicate, entry.chain_sequence)
          verify(entry, @previous_link)
        end

        def advance(entry)
          @previous_link = @link
          @link = entry.chain_digest
          @last_sequence = entry.chain_sequence
          @last_digest = entry.chain_digest
          @expected = entry.chain_sequence + 1
        end

        def verify(entry, previous)
          # A row whose key or epoch contradicts the epoch records is a break on its own; its
          # digest would only repeat it.
          return if epoch_break?(entry)

          # With no chain record there is no genesis for the first row to link to. That is
          # reported once, as chain_record_missing, not again here as a mismatch.
          return if !@verify_first_link && entry.chain_sequence == 1

          key_id = entry.chain_key_id
          sequence = entry.chain_sequence
          secret = keyring.for(key_id)
          if secret.nil?
            return @report.call(:unknown_key, sequence, "signed by key #{key_id}", nil, key_id)
          end

          expected = Canonical.entry_digest(secret, entry, previous_digest: previous)
          @report.call(:digest_mismatch, sequence, MISMATCH) unless expected == entry.chain_digest
        rescue ArgumentError => e
          @report.call(:digest_mismatch, entry.chain_sequence, e.message)
        end

        def epoch_break?(entry)
          kind, detail = epochs.judge(entry)
          return false unless kind

          @report.call(kind, entry.chain_sequence, detail)
          true
        end

        def each_chained(limit, &block)
          after = nil
          loop do
            batch = batch_after(after, limit)
            batch.each(&block)
            break if batch.size < batch_size

            after = [batch.last.chain_sequence, batch.last.id]
          end
        end

        def batch_after(after, limit)
          entry_class.uncached { batch_scope(after, limit).to_a }
        end

        # Resumes after (sequence, id). The `>=` is what the index can use; the OR beneath it
        # only breaks ties between rows sharing that sequence. Written as the OR alone, the
        # condition is the same set of rows, but PostgreSQL applied it as a filter and scanned
        # every batch from the first row: the walk was quadratic, and a million rows took 331 s
        # against SC-004's 300. SQLite derived the bound on its own, which hid it there.
        def batch_scope(after, limit)
          scope = entry_class.where.not(chain_sequence: nil)
          scope = scope.where("chain_sequence > ?", @start) if @start.positive? && after.nil?
          scope = scope.where("chain_sequence <= ?", limit) if limit
          if after
            scope = scope.where("chain_sequence >= ?", after[0])
                         .where("chain_sequence > ? OR id > ?", after[0], after[1])
          end
          scope.order(:chain_sequence, :id).limit(batch_size)
        end
      end
    end
  end
end
