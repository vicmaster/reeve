# frozen_string_literal: true

module Reeve
  module Audit
    # The ledger row, written on a connection of its own.
    #
    # `Recorder` writes in a savepoint, which protects the trace from a transaction the
    # *tool* opens and rolls back. It cannot protect the trace from a transaction the
    # *host* opened around the whole invocation — a controller that wraps each request in
    # one, a job runner, a test suite with transactional fixtures. A savepoint released
    # into that transaction goes down with it, and the envelope has no way to learn
    # otherwise: the write reported success, the invocation returned records, and no row
    # survives to say so. Constitution II says every call leaves a trace; on one
    # connection that is not achievable, only detectable, which is why `Recorder` warns.
    #
    # A second connection is the only thing that actually closes it. A transaction on
    # connection A cannot roll back an INSERT committed on connection B, so the row lands
    # whatever the host's transaction does next.
    #
    #   config.audit_recorder = Reeve::Audit::IsolatedRecorder
    #
    # == Why this is not the default
    #
    # It cannot be. On SQLite the host's open transaction holds the database write lock,
    # so the second connection blocks until it times out and every guarded call fails —
    # the isolation is not merely unavailable there, it is actively worse than the
    # savepoint. Rather than degrade quietly on the database most hosts develop against,
    # this refuses to run on SQLite and says why. `Recorder` remains the default, and a
    # host that needs durability under a wrapping transaction opts in on a database where
    # opting in means something.
    #
    # It also costs a connection per pool, and moves the ledger write outside the host's
    # transaction in both directions: the row survives a rollback, which is the point,
    # and it also survives a rollback of an invocation the host *meant* to undo entirely.
    # A ledger of what was attempted is the intended reading of Constitution II, but it is
    # a choice, and it should be made rather than inherited.
    class IsolatedRecorder < Recorder
      UNSUPPORTED_ADAPTERS = %w[sqlite sqlite3].freeze

      class << self
        def record(attributes)
          new.record(attributes)
        end

        # True when a second connection can actually be used here. Lets a host branch in
        # an initializer — SQLite in development, PostgreSQL in production — rather than
        # discovering the answer on the first guarded call.
        def available?
          verify_supported!
          true
        rescue Reeve::Error
          false
        end

        def verify_supported!
          adapter = IsolatedEntry.adapter_name
          return unless UNSUPPORTED_ADAPTERS.include?(adapter.to_s.downcase)

          raise ConfigurationError,
                "Reeve::Audit::IsolatedRecorder cannot be used on #{adapter}: an open " \
                "transaction holds the database write lock, so a second connection " \
                "blocks until it times out and every guarded call fails. Use " \
                "Reeve::Audit::Recorder here — it warns when a host transaction is " \
                "wrapped around an invocation — and configure this recorder only where " \
                "the database supports concurrent writers."
        end
      end

      def initialize(config: nil)
        super(entry_class: IsolatedEntry, config: config)
      end

      # Checked out and returned around each write rather than held: the pool exists to
      # keep the ledger off the host's connection, not to keep a connection per thread
      # alive for the life of the process.
      def record(attributes)
        self.class.verify_supported!
        IsolatedEntry.connection_pool.with_connection { super }
      end

      private

      # The savepoint `Recorder` uses is what makes the trace survive the *tool's* own
      # rollback, and that is still worth having here: this connection is not in a
      # transaction the host controls, but the tool body may have opened one on the main
      # connection, and a single INSERT wants the same all-or-nothing treatment either
      # way. Nothing about it is inherited from the host's transaction.
      #
      # The warning the parent emits is correctly silent here: it asks whether *this*
      # connection has a transaction open, and this one never does.
      def enclosing_transaction?
        false
      end
    end

    # The same table and the same rules, on a pool of its own.
    #
    # A subclass rather than a second model so that validations, readonly-once-persisted
    # and the destroy guard are defined in exactly one place. The table has no
    # inheritance column, so ActiveRecord adds no type condition and this reads and writes
    # the same rows `Entry` does.
    class IsolatedEntry < Entry
      class << self
        def adapter_name
          establish_own_connection!
          connection_pool.db_config.adapter
        rescue StandardError => e
          raise Error, "could not reach the audit ledger on its own connection: " \
                       "#{e.class}: #{e.message}"
        end

        def connection_pool
          establish_own_connection!
          super
        end

        private

        # Idempotent, and deliberately lazy: a Rails initializer naming this recorder runs
        # before the database is necessarily reachable, so the pool is built on first use
        # rather than at configure time.
        def establish_own_connection!
          return if @own_connection

          establish_connection(::ActiveRecord::Base.connection_db_config)
          @own_connection = true
        end
      end
    end
  end
end
