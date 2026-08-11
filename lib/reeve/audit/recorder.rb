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
    # The insert opens **its own** transaction rather than joining the tool's (R5,
    # corrected). A tool body that raises rolls its own work back, and the trace of an
    # invocation that blew up is the one most worth having; writing inside the tool's
    # transaction would delete exactly those rows.
    #
    # The known limit, stated rather than papered over: on a single connection there is a
    # narrow window where the tool's data commits and the ledger write then fails. In the
    # default :fail mode the caller still learns, by exception — but the data change has
    # already landed. Closing that window entirely needs a second connection or two-phase
    # commit, which is out of proportion for v1.
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
          metadata: attributes[:metadata]
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

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
