# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # The chain record's head, advanced under its lock (research R3).
      #
      # One instance per append, bound to the connection that append runs on; every
      # statement here goes through that connection, so the lock, the row and the head move
      # share one transaction and commit or roll back together.
      #
      #   UPDATE head_sequence by one   -- the lock, taken first
      #   SELECT the new head_sequence and the old head_digest
      #   ... the caller inserts the row ...
      #   UPDATE head_digest to the row's digest
      #
      # Taking the lock with a write is what makes this behave the same on all three
      # engines: SQLite cannot upgrade a read lock while another writer waits, and ignores
      # SELECT ... FOR UPDATE.
      class Head
        def initialize(connection:, entry_class:)
          @connection = connection
          @entry_class = entry_class
        end

        # Creates the chain record with its genesis — link 0, head 0 — unless it exists.
        #
        # Deliberately not part of the write that follows. Run first inside it, an UPDATE that
        # matched no row took a gap lock on MySQL's unique index, and two writers starting the
        # chain at once each tried to INSERT into the gap the other held: a deadlock, found
        # by CI, invisible on PostgreSQL, which has no gap locks. On its own, two concurrent
        # INSERTs of one unique name serialize: one wins and the other gets a duplicate key,
        # which means the chain has started and is all it needs to know.
        #
        # So a started chain can exist with nothing in it yet (head 0) — if the first chained
        # write then fails, say. The verifier reports that as no chain, not as a pass.
        def start!(signer)
          return if connection.select_value("SELECT 1 FROM #{TABLE} WHERE #{named}")

          genesis = genesis_for(signer)
          digest = Canonical.genesis_digest(signer.signing_secret, genesis)
          values = genesis.merge(name: ChainRecord::LEDGER, genesis_digest: digest,
                                 head_sequence: 0, head_digest: digest)
          quoted = values.values.map { |value| connection.quote(value) }

          entry_class.transaction(requires_new: true) do
            connection.insert("INSERT INTO #{TABLE} (#{values.keys.join(', ')}) " \
                              "VALUES (#{quoted.join(', ')})")
          end
        rescue ActiveRecord::RecordNotUnique
          nil
        end

        # Locks the head and returns the next sequence and the digest it links to. The chain
        # must have been started.
        def advance!
          vanished = increment.zero?
          raise ActiveRecord::StatementInvalid, "the ledger chain record vanished" if vanished

          head = connection.select_one("SELECT head_sequence, head_digest FROM #{TABLE} " \
                                       "WHERE #{named}")
          [Integer(head["head_sequence"]), head["head_digest"]]
        end

        # Takes the head's lock without consuming a sequence (specs/003 FR-008) and returns the
        # head: a rotation queues at the same point as a write, so the epoch it opens begins
        # exactly one past the last row any writer committed. A write that changes nothing
        # still takes the row lock on PostgreSQL and MySQL and the write lock on SQLite.
        def lock!
          updated = connection.update("UPDATE #{TABLE} SET head_sequence = head_sequence " \
                                      "WHERE #{named}")
          raise ActiveRecord::StatementInvalid, "the ledger chain record vanished" if updated.zero?

          Integer(connection.select_value("SELECT head_sequence FROM #{TABLE} WHERE #{named}"))
        end

        def point_at!(digest)
          connection.update("UPDATE #{TABLE} SET head_digest = #{connection.quote(digest)} " \
                            "WHERE #{named}")
        end

        # The connection this append runs on; Epochs uses it so the epoch an append opens
        # commits or rolls back with the append.
        attr_reader :connection

        private

        attr_reader :entry_class

        def increment
          connection.update("UPDATE #{TABLE} SET head_sequence = head_sequence + 1 WHERE #{named}")
        end

        def genesis_for(signer)
          {
            genesis_at: Time.now.utc.floor(6),
            pre_chain_count: entry_class.where("contract_version < 3").count,
            pre_chain_unchained_count:
              entry_class.where(UNCHAINED).count,
            genesis_key_id: signer.signing_id
          }
        end

        def named
          "name = #{connection.quote(ChainRecord::LEDGER)}"
        end
      end
    end
  end
end
