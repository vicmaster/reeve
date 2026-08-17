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
      # What each half of this check is worth, stated plainly because it is easy to read
      # more into the version number than it carries:
      #
      # * The **column list** is the real test. It is compared against the columns the
      #   host's table actually has, and it is written out by hand rather than read back
      #   off the model — a check that derives its expectation from the thing it is
      #   checking checks nothing.
      # * The **version number** is compared against what the ledger model reports, which
      #   is this gem's own +Audit::CONTRACT_VERSION+ — so by default it compares the gem
      #   to itself and can only pass. It earns its keep when a host passes `expected:` to
      #   pin the version it built its exports against.
      #
      # Those two are not as separate as they look, and that is by design. A contract bump
      # is defined as a change to the shape or to what a value means; every such bump also
      # moves the `contract_version` column, which means the column list catches a stale
      # table even when the bump was purely semantic. Contract 2 is the worked example: the
      # change was `metadata`'s meaning, no existing column moved, and a host still on the
      # contract 1 table fails here on a missing `contract_version` column rather than
      # passing while writing rows nothing can interpret.
      #
      # The constant below is written out rather than read from +Audit+ for the same
      # reason the column list is, and one more: the testing kit loads with no ledger and
      # no ActiveRecord at all (spec/reeve/testing/isolation_spec.rb), so it cannot
      # reference the audit module. Bumping the contract means editing both by hand, and
      # spec/reeve/audit/contract_version_spec.rb fails if they drift.
      #
      #   Reeve::Checks::ContractVersion.new.call
      #   Reeve::Checks::ContractVersion.new(expected: 2).call   # pinned by the host
      class ContractVersion < Base
        TABLE = "reeve_audit_entries"

        COLUMNS = %w[
          invocation_id occurred_at agent_id agent_name principal_type principal_id
          tool_name arguments outcome rule detail record_type record_ids record_count
          truncated derived guard duration_ms metadata contract_version
        ].freeze

        EXPECTED_VERSION = 2

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

        # Names the generator that actually fixes this. It used to say `reeve:install`,
        # which is wrong for the case this failure describes: the table exists, so Rails
        # resolves that migration by name and either emits nothing or offers to overwrite
        # one that has already run.
        def missing_columns(missing)
          failed(
            "expected the ledger to implement audit-entry contract version #{@expected}, " \
            "but #{TABLE} is missing: #{missing.join(', ')} — run `rails g reeve:upgrade` " \
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
