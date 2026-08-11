# frozen_string_literal: true

module Reeve
  module Testing
    module Checks
      # FR-015: the ledger the host actually migrated implements the entry shape this
      # version of the gem writes.
      #
      # The audit-entry contract is versioned in prose and in +Audit::CONTRACT_VERSION+;
      # what this check adds is the third party to that agreement — the table. A host that
      # upgraded the gem and skipped the migration has a ledger one shape behind, and every
      # other check in this kit would go on passing while columns quietly went unwritten.
      #
      #   Reeve::Checks::ContractVersion.new.call
      class ContractVersion < Base
        TABLE = "reeve_audit_entries"

        # Contract version 1, as documented in contracts/audit-entry.md. This list is
        # deliberately written out rather than read back off the model: a check that
        # derives its expectation from the thing it is checking checks nothing.
        COLUMNS = %w[
          invocation_id occurred_at agent_id agent_name principal_type principal_id
          tool_name arguments outcome rule detail record_type record_ids record_count
          truncated derived guard duration_ms metadata
        ].freeze

        EXPECTED_VERSION = 1

        def initialize(tool: nil, expected: EXPECTED_VERSION, ledger: nil)
          super(tool: tool, ledger: ledger)
          @expected = expected
        end

        def call
          return ledger_unavailable("the audit-entry contract version") unless ledger.available?

          recorded = ledger.contract_version
          return version_mismatch(recorded) unless recorded == @expected

          missing = COLUMNS - ledger.columns
          return missing_columns(missing) unless missing.empty?

          passed("the ledger implements audit-entry contract version #{@expected}",
                 version: @expected)
        end

        private

        def version_mismatch(recorded)
          failed(
            "expected the ledger to implement audit-entry contract version #{@expected}, " \
            "but it reports version #{recorded.inspect} — this reeve version cannot read " \
            "that shape",
            version: recorded
          )
        end

        def missing_columns(missing)
          failed(
            "expected the ledger to implement audit-entry contract version #{@expected}, " \
            "but #{TABLE} is missing: #{missing.join(', ')} — run `rails g reeve:install` " \
            "and migrate",
            version: @expected, missing: missing
          )
        end

        def base_details
          { tool: nil }
        end
      end
    end
  end
end
