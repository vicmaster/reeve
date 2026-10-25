# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # Checks each checkpoint against the ledger (specs/004 FR-011, FR-012): that it is
      # genuine, that the chain it names is this one, that the epoch it names is still there,
      # and that the ledger still reaches its entry with the digest it names.
      #
      # Each checkpoint is checked on its own; none is compared with another. A rule about
      # their order would need a trusted clock or a trusted order, and nothing supplies either;
      # every case such a rule would catch already fails here (spec amendment 2).
      #
      # A checkpoint signed by a key this verifier lacks is reported as unknown_key and used for
      # nothing else: an unchecked checkpoint must not anchor anything.
      class CheckpointCheck
        LOOKUP_BATCH = 1_000

        Result = Struct.new(:head_sequence, :made_at, :key_id, :status, keyword_init: true) do
          def as_json(*)
            { "head_sequence" => head_sequence, "made_at" => made_at, "key_id" => key_id,
              "status" => status.to_s }
          end
        end

        # The break each failing status is reported as.
        KINDS = { key_not_configured: :unknown_key, altered: :checkpoint_altered,
                  mismatch: :checkpoint_mismatch, not_reached: :checkpoint_not_reached }.freeze

        ALTERED = "does not match its signature; it was edited, or is not reeve's"
        NO_CHAIN = "the ledger has no chain, but this checkpoint saw it reach %s"
        NO_RECORD = "its genesis cannot be checked: the chain record is missing"
        OTHER_CHAIN = "names another chain: its genesis is not this ledger's"
        EPOCH_GONE = "names epoch %d, which the ledger no longer has"
        EPOCH_CHANGED = "names epoch %d, whose record is not the one it saw"
        REMOVED = "the head is at %s; entries the checkpoint saw were removed"

        # `report` receives (kind, sequence, detail, invocation_id, key_id, checkpoint:).
        def initialize(entry_class:, keyring:, report:)
          @entry_class = entry_class
          @keyring = keyring
          @report = report
        end

        # `record` is the chain record read at the start, `head` the one read after the walk
        # (the later read, so an entry written during the walk is not "not reached"); `epochs`
        # the epoch records the verifier loaded. `chained` says whether the ledger has a chain
        # at all. Returns one Result per checkpoint, in the order given.
        def call(checkpoints, record:, head:, epochs:, chained: true)
          genuine = checkpoints.select { |checkpoint| checkpoint.signed_by(keyring) == :valid }
          digests = chained ? digests_at(genuine.map(&:head_sequence)) : {}
          context = { record: record, head: head, epochs: epochs.to_h { |e| [e.epoch, e] },
                      digests: digests, chained: chained }
          checkpoints.map { |checkpoint| result(checkpoint, judge(checkpoint, **context)) }
        end

        private

        attr_reader :entry_class, :keyring

        def result(checkpoint, status)
          Result.new(head_sequence: checkpoint.head_sequence, made_at: checkpoint.made_at,
                     key_id: checkpoint.key_id, status: status)
        end

        def judge(checkpoint, record:, head:, epochs:, digests:, chained:)
          signature(checkpoint) ||
            chain(checkpoint, record, chained) ||
            epoch(checkpoint, epochs) ||
            position(checkpoint, head, digests) ||
            :checked
        end

        def signature(checkpoint)
          case checkpoint.signed_by(keyring)
          when :key_not_configured
            flag(:key_not_configured, checkpoint, "signed by key #{checkpoint.key_id}",
                 key_id: checkpoint.key_id)
          when :altered then flag(:altered, checkpoint, ALTERED)
          end
        end

        def chain(checkpoint, record, chained)
          return flag(:not_reached, checkpoint, format(NO_CHAIN, reach(checkpoint))) unless chained
          return flag(:mismatch, checkpoint, NO_RECORD) if record.nil?
          return if same_genesis?(checkpoint, record)

          flag(:mismatch, checkpoint, OTHER_CHAIN)
        end

        def same_genesis?(checkpoint, record)
          checkpoint.genesis_digest == record.genesis_digest &&
            checkpoint.pre_chain_count == record.pre_chain_count &&
            checkpoint.pre_chain_unchained_count == record.pre_chain_unchained_count
        end

        def epoch(checkpoint, epochs)
          number = checkpoint.epoch
          return if number.nil? || epochs[number]&.epoch_digest == checkpoint.epoch_digest

          flag(:mismatch, checkpoint, format(epochs[number] ? EPOCH_CHANGED : EPOCH_GONE, number))
        end

        def position(checkpoint, head, digests)
          sequence = checkpoint.head_sequence
          head_sequence = head&.head_sequence.to_i
          if sequence > head_sequence
            return flag(:not_reached, checkpoint, format(REMOVED, Report.number(head_sequence)))
          end

          found = digests.fetch(sequence, [])
          return flag(:not_reached, checkpoint, "entry #{reach(checkpoint)} is gone") if found.none?
          return if found.include?(checkpoint.head_digest)

          flag(:mismatch, checkpoint, "entry #{reach(checkpoint)} is not the one it saw")
        end

        def reach(checkpoint)
          "##{Report.number(checkpoint.head_sequence)}"
        end

        # Reports the break that goes with `status` and returns the status.
        def flag(status, checkpoint, detail, key_id: nil)
          @report.call(KINDS.fetch(status), nil, detail, nil, key_id,
                       checkpoint: checkpoint.head_sequence)
          status
        end

        # Every digest at each sequence, a batch of sequences per query (FR-016). A list, because
        # a duplicated sequence is a break of its own and must not hide the entry the
        # checkpoint saw.
        def digests_at(sequences)
          found = Hash.new { |hash, sequence| hash[sequence] = [] }
          sequences.uniq.each_slice(LOOKUP_BATCH) do |slice|
            rows = entry_class.uncached do
              entry_class.where(chain_sequence: slice).pluck(:chain_sequence, :chain_digest)
            end
            rows.each { |sequence, digest| found[sequence] << digest }
          end
          found
        end
      end
    end
  end
end
