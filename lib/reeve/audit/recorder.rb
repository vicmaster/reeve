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
    # The insert runs in `requires_new: true`, which is what makes the trace survive a
    # tool body that opens a transaction and rolls it back (R5) — the case this was built
    # for, and the one it does solve.
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
    # isolation is impossible, the recorder detects the enclosing transaction and warns
    # that the guarantee is suspended for that call. A host that needs durability under a
    # wrapping transaction supplies its own `audit_recorder` — writing to a separate
    # connection, a queue, or an append-only log — which is what that setting is for.
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
      def record(attributes)
        row = row_for(attributes)
        warn_about_enclosing_transaction(row[:invocation_id])

        entry_class.transaction(requires_new: true) do
          entry_class.create!(row)
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        # A replayed invocation is the same invocation. One row per invocation_id means
        # a retry is a no-op insert, never a second row (contracts/audit-entry.md).
        existing = entry_class.find_by(invocation_id: row[:invocation_id])
        raise e if existing.nil?

        existing
      end

      private

      attr_reader :entry_class

      def config
        @config || Reeve.config
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
          metadata: redact_metadata(attributes)
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

        message = "reeve: invocation #{invocation_id} was recorded inside a transaction " \
                  "the host opened around it, so the ledger row will be rolled back with " \
                  "it. Configure Reeve.config.audit_recorder with a recorder that writes " \
                  "outside this transaction if the trace must survive."
        logger = config.logger
        logger ? logger.warn(message) : Kernel.warn(message)
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
