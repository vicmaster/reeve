# frozen_string_literal: true

module Reeve
  module Audit
    # The ledger's chain (specs/002): every row reeve writes is linked to the one before it
    # by a keyed digest, so a row changed, removed or reordered outside reeve is reported by
    # verification.
    #
    #   Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry).append!(row)   # write
    #   Reeve::Audit::Chain.verify                                               # check
    #
    # `append!` is the only door a chained row comes through. Recorder and IsolatedRecorder
    # use it; a host with its own recorder uses it too (FR-007), or its rows are reported as
    # unchained.
    #
    # == How a write is serialized (research R3)
    #
    #   UPDATE the chain record's head_sequence by one   -- the lock, taken first
    #   SELECT the new head_sequence and the old head_digest
    #   INSERT the row with its sequence, key id and digest
    #   UPDATE the head_digest to the row's digest
    #
    # all inside one savepoint on the entry class's own connection. The first statement is
    # a write, so on PostgreSQL and MySQL it takes the row lock and on SQLite the database
    # write lock: every writer queues at the same point with the same SQL. Reading first
    # would be refused outright by SQLite (a shared lock cannot be upgraded while another
    # writer waits), and SELECT ... FOR UPDATE is ignored there.
    #
    # Because the row and the head move commit together, a rolled-back write consumes no
    # sequence — and a committed row can never sit beyond a committed head, which is what
    # lets the verifier call such a row forged.
    #
    # == The cost, stated
    #
    # Under the default Recorder inside a transaction the host opened, the chain record
    # stays locked until that transaction ends, so every other guarded call waits behind it.
    # IsolatedRecorder holds it for one insert.
    class Chain
      TABLE = "reeve_audit_chains"

      COLUMNS = %w[chain_sequence chain_key_id chain_digest].freeze

      # Verifies the whole ledger. With `keys:`, verifies with those keys alone — how an
      # auditor checks a ledger with their own copy of the key.
      def self.verify(keys: nil, entry_class: Entry, batch_size: Verifier::BATCH_SIZE)
        keyring = keys ? Keyring.new(signing: nil, retired: keys) : Keyring.from(Reeve.config)
        Verifier.new(entry_class: entry_class, keyring: keyring, batch_size: batch_size).call
      end

      def initialize(entry_class: Entry, keyring: nil)
        @entry_class = entry_class
        @keyring = keyring
      end

      # Writes `row` as the next link and returns the entry. The row carries every column
      # but the three chain ones; it is normalized here (research R2).
      #
      # Raises LedgerKeyError with no signing key, and whatever the database raises if the
      # write fails. A replayed invocation_id returns the existing entry and consumes
      # nothing. What a failure means for the caller — fail the call or warn — is the
      # caller's decision, not this method's.
      def append!(row)
        require_columns!
        signer = keyring
        raise LedgerKeyError unless signer.signing?

        normalized = normalizer.call(row)
        with_connection do |connection|
          insert_once(normalized) do
            entry_class.transaction(requires_new: true) { link!(connection, normalized, signer) }
          end
        end
      end

      # Writes `row` at its contract version with no chain columns, around the chain: no lock,
      # no sequence. For a caller that has decided to keep running without a key (Recorder
      # under audit_failure_mode :warn). Verification reports such a row as unchained.
      def append_unchained!(row)
        require_columns!
        normalized = normalizer.call(row)
        with_connection do
          insert_once(normalized) do
            entry_class.transaction(requires_new: true) { entry_class.create!(normalized) }
          end
        end
      end

      private

      attr_reader :entry_class

      def keyring
        @keyring || Keyring.from(Reeve.config)
      end

      def normalizer
        @normalizer ||= Chain::Normalizer.new(entry_class)
      end

      # The digest is computed over the model instance, not the hash: ActiveRecord fills in
      # column defaults (`truncated: false`) and casts on assignment (an Integer principal_id
      # becomes a String), and the instance is exactly what the database will be given.
      # Digesting the hash a caller passed would sign values that are never stored.
      def link!(connection, normalized, signer)
        head = Head.new(connection: connection, entry_class: entry_class)
        sequence, previous = head.advance!(signer)
        entry = entry_class.new(normalized.merge(chain_sequence: sequence,
                                                 chain_key_id: signer.signing_id))
        entry.chain_digest = Canonical.entry_digest(signer.signing_secret, entry,
                                                    previous_digest: previous)
        entry.save!
        head.point_at!(entry.chain_digest)
        entry
      end

      # A replayed invocation_id returns the row already written, whether the pre-check sees
      # it or the insert collides with it.
      def insert_once(normalized)
        existing = replayed(normalized)
        return existing if existing

        yield
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        replayed(normalized) || raise(e)
      end

      # A table one contract behind the gem fails here, naming the fix, rather than as an
      # "unknown attribute" or "no such column" from deep inside the write.
      def require_columns!
        missing = COLUMNS - entry_class.column_names
        return if missing.empty?

        raise ConfigurationError,
              "#{entry_class.table_name} is missing #{missing.join(', ')}: the ledger is at an " \
              "older audit-entry contract than this reeve writes (#{CONTRACT_VERSION}). Run " \
              "`bin/rails generate reeve:upgrade` and `bin/rails db:migrate`."
      end

      def replayed(normalized)
        id = normalized[:invocation_id]
        id && entry_class.find_by(invocation_id: id)
      end

      # Checked out for one append and returned, never leased to the thread: from Rails 7.2
      # `entry_class.connection` pins a connection to the thread for good, which would undo
      # IsolatedRecorder's promise to hold none between writes. ConnectionPool#with_connection
      # exists on every Rails this gem supports, and reuses a connection the thread already
      # holds — so the transaction and the INSERT run on the same one.
      #
      # The connection is passed down as an argument, never kept on the instance. A Chain
      # holds no per-call state, so one instance can be shared by every thread that writes:
      # an earlier version stored it in an instance variable, and two threads appending
      # through one Chain drove a single PostgreSQL connection at once.
      def with_connection(&block)
        entry_class.connection_pool.with_connection(&block)
      end
    end
  end
end
