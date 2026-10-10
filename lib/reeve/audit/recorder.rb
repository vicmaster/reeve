# frozen_string_literal: true

module Reeve
  module Audit
    # The one write path into the ledger (FR-008).
    #
    # The envelope calls this from an `ensure` block and expects it to raise on failure —
    # Constitution II makes a failed write a failed call unless the host has opted into a
    # degraded mode. Everything here is therefore synchronous: no queue, no thread, no
    # ActiveJob. An asynchronous ledger cannot be relied on and would make FR-012
    # unenforceable.
    #
    # Every row goes through Chain#append! (specs/002), which links it to the row before it
    # and runs the insert in `requires_new: true` — what makes the trace survive a tool body
    # that opens a transaction and rolls it back (R5), the case this was built for and the
    # one it does solve.
    #
    # What it does **not** do, corrected after review: `requires_new` is a SAVEPOINT, not
    # an independent transaction. If the host has already opened a transaction *around*
    # the invocation — a controller or middleware that wraps each request, or a test suite
    # using transactional fixtures — the savepoint is released into that transaction, and
    # a later rollback takes the ledger row with it. The write reports success and the
    # envelope has no way to learn otherwise, so the invocation returns records with no
    # surviving trace. The comment here previously claimed independence outright; it did
    # not have it.
    #
    # A genuinely independent write needs a second connection, and that is not portable:
    # on SQLite the enclosing transaction holds the write lock, so a second connection
    # blocks until it times out. Rather than fail every call on the databases where
    # isolation is impossible, this recorder detects the enclosing transaction and warns
    # that the guarantee is suspended for that call.
    #
    # `Reeve::Audit::IsolatedRecorder` is the answer where the database has concurrent
    # writers: same rows, same redaction, on a pool of its own, so a rollback on the
    # host's connection cannot reach it. It is opt-in rather than the default precisely
    # because it cannot work everywhere this one does. A host with a different answer
    # again — a queue, an append-only log — still supplies its own `audit_recorder`.
    #
    # The other known limit, unchanged: on a single connection there is a narrow window
    # where the tool's data commits and the ledger write then fails. The caller learns by
    # exception, but the data change has already landed.
    class Recorder
      # Free-form text from a policy or an exception message. Capped rather than trusted:
      # it is the one column whose length the host does not control.
      DETAIL_LIMIT = 1000

      def self.record(attributes)
        new.record(attributes)
      end

      def initialize(entry_class: Entry, config: nil)
        @entry_class = entry_class
        @config = config
      end

      # Returns the entry. Raises if the row could not be written, so the envelope can
      # fail the invocation.
      #
      # A replayed invocation is the same invocation: one row per invocation_id means a
      # retry returns the existing row and never writes a second (contracts/audit-entry.md).
      # Chain#append! owns that, because it must also consume no sequence number.
      #
      # With no ledger key (specs/002 FR-010): under :fail, Chain raises LedgerKeyError and
      # the envelope fails the call like any other ledger failure. Under :warn the row is
      # still written, at contract 3 and unchained, and the log says so every time —
      # :warn keeps calls running, it does not drop traces, and verification reports the
      # row as unchained rather than letting it pass unseen.
      def record(attributes)
        row = row_for(attributes)
        warn_about_enclosing_transaction(row[:invocation_id])

        keyring = Chain::Keyring.from(config)
        chain = Chain.new(entry_class: entry_class, keyring: keyring)
        return chain.append!(row) if keyring.signing? || config.audit_failure_mode == :fail

        warn("reeve: invocation #{row[:invocation_id]} was recorded unchained: no ledger key is " \
             "configured and audit_failure_mode is :warn. Verification will report the row as " \
             "unchained. Set config.ledger_key to chain the ledger.")
        chain.append_unchained!(row)
      end

      private

      attr_reader :entry_class

      def config
        @config || Reeve.config
      end

      def warn(message)
        logger = config.logger
        logger ? logger.warn(message) : Kernel.warn(message)
      end

      def row_for(attributes)
        ids, count, truncated = identifiers(attributes)

        identity(attributes).merge(
          arguments: redact(attributes),
          outcome: attributes[:outcome].to_s,
          rule: attributes[:rule],
          detail: detail(attributes),
          record_type: attributes[:record_type],
          record_ids: ids,
          record_count: count,
          truncated: truncated,
          derived: attributes[:derived] ? true : false,
          guard: blank?(attributes[:guard]) ? "policy" : attributes[:guard].to_s,
          duration_ms: attributes[:duration_ms],
          metadata: redact_metadata(attributes),
          # Stamped from the constant rather than from the caller: the row records the
          # shape the gem that wrote it implements, which is not something an adapter or
          # a host is in a position to assert.
          contract_version: CONTRACT_VERSION
        )
      end

      def identity(attributes)
        {
          invocation_id: attributes[:invocation_id],
          occurred_at: attributes[:occurred_at],
          agent_id: agent_id(attributes),
          agent_name: attributes[:agent_name],
          principal_type: attributes[:principal_type],
          principal_id: attributes[:principal_id]&.to_s,
          tool_name: attributes[:tool_name]
        }
      end

      # An unidentifiable agent is recorded as unknown, never dropped: attribution is not
      # authorization, and a row that names no agent still answers most of the question.
      def agent_id(attributes)
        blank?(attributes[:agent_id]) ? Context::UNKNOWN_AGENT_ID : attributes[:agent_id]
      end

      def redact(attributes)
        Redactor.for(attributes[:tool_name], config: config).call(attributes[:arguments])
      end

      # Metadata is transport detail, and the transport is where the credentials are: the
      # fast-mcp bridge puts the whole header hash in here, `Authorization` included. It
      # goes through the same redactor as the arguments — which recurses into nested
      # hashes and already knows `authorization`, `token` and friends by name — so
      # recording metadata does not turn the ledger into a place bearer tokens accumulate.
      # nil stays nil rather than becoming `{}`: a call that carried no metadata should
      # not be indistinguishable from one whose metadata was emptied.
      def redact_metadata(attributes)
        metadata = attributes[:metadata]
        return nil if metadata.nil? || metadata.empty?

        Redactor.for(attributes[:tool_name], config: config).call(metadata)
      end

      # FR-014: identifiers are capped, never silently dropped — the count stays true and
      # the row says it was truncated. The scoper caps first; this is the backstop that
      # makes the guarantee hold at the ledger regardless of who produced the list.
      def identifiers(attributes)
        ids = Array(attributes[:record_ids]).map(&:to_s)
        count = attributes[:record_count] || ids.size
        truncated = attributes[:truncated] ? true : false
        limit = config.max_recorded_ids

        return [ids, count, truncated] unless ids.size > limit

        [ids.first(limit), [count, ids.size].max, true]
      end

      def detail(attributes)
        value = attributes[:detail]
        return nil if blank?(value)

        value.to_s[0, DETAIL_LIMIT]
      end

      # The host's transaction, not the tool's: the tool's own transaction is nested
      # inside this write and is exactly what `requires_new` protects against.
      def warn_about_enclosing_transaction(invocation_id)
        return unless enclosing_transaction?

        warn("reeve: invocation #{invocation_id} was recorded inside a transaction " \
             "the host opened around it, so the ledger row will be rolled back with " \
             "it, and the ledger chain stays locked until it ends, so every other " \
             "guarded call waits behind it. Set Reeve.config.audit_recorder = " \
             "Reeve::Audit::IsolatedRecorder to write on a connection the transaction " \
             "cannot reach (needs a database with concurrent writers; not SQLite).")
      end

      def enclosing_transaction?
        entry_class.connection.transaction_open?
      rescue StandardError
        false
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
