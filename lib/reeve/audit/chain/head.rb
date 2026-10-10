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

        # Locks the head and returns the next sequence and the digest it links to,
        # starting the chain if there is none.
        def advance!(signer)
          if increment.zero?
            started = start(signer)
            return started if started

            # Another writer created the record between our UPDATE and our INSERT. Its row
            # is committed or about to be; this UPDATE waits for it and then succeeds.
            vanished = increment.zero?
            raise ActiveRecord::StatementInvalid, "the ledger chain record vanished" if vanished
          end

          head = connection.select_one("SELECT head_sequence, head_digest FROM #{TABLE} " \
                                       "WHERE #{named}")
          [Integer(head["head_sequence"]), head["head_digest"]]
        end

        def point_at!(digest)
          connection.update("UPDATE #{TABLE} SET head_digest = #{connection.quote(digest)} " \
                            "WHERE #{named}")
        end

        private

        attr_reader :connection, :entry_class

        def increment
          connection.update("UPDATE #{TABLE} SET head_sequence = head_sequence + 1 WHERE #{named}")
        end

        # Creates the chain record with its genesis — link 0 — for the row about to be
        # written as sequence 1. Returns nil if another writer won the race to create it.
        def start(signer)
          genesis = genesis_for(signer)
          digest = Canonical.genesis_digest(signer.signing_secret, genesis)
          values = genesis.merge(name: ChainRecord::LEDGER, genesis_digest: digest,
                                 head_sequence: 1, head_digest: digest)

          entry_class.transaction(requires_new: true) do
            quoted = values.values.map { |value| connection.quote(value) }
            connection.insert("INSERT INTO #{TABLE} (#{values.keys.join(', ')}) " \
                              "VALUES (#{quoted.join(', ')})")
          end
          [1, digest]
        rescue ActiveRecord::RecordNotUnique
          nil
        end

        def genesis_for(signer)
          {
            genesis_at: Time.now.utc.floor(6),
            pre_chain_count: entry_class.where("contract_version < 3").count,
            pre_chain_unchained_count:
              entry_class.where("contract_version >= 3 AND chain_digest IS NULL").count,
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
