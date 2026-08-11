# frozen_string_literal: true

module Reeve
  module Audit
    # One ledger row: which agent, acting for which principal, called which tool with
    # which arguments, what came back, and which rule decided (FR-009).
    #
    # Append-only (FR-010). The model enforces that as far as a library can: a persisted
    # row is readonly, so `update` and `save` raise, and `destroy` aborts. It cannot
    # enforce it against raw SQL and does not pretend to — the generated migration
    # documents the INSERT+SELECT grant that closes the rest of the gap.
    class Entry < ActiveRecord::Base
      self.table_name = TABLE_NAME

      ALLOW = "allow"
      DENY  = "deny"
      OUTCOMES = [ALLOW, DENY].freeze

      REQUIRED = %i[invocation_id occurred_at agent_id tool_name outcome rule guard].freeze

      validates(*REQUIRED, presence: true)
      validates :invocation_id, uniqueness: true
      validates :outcome, inclusion: { in: OUTCOMES, message: "must be allow or deny" }

      before_destroy { throw :abort }

      # The contract version this table's shape implements (FR-015). Exposed on the model
      # so an export can stamp the rows it carries.
      def self.contract_version
        CONTRACT_VERSION
      end

      # False while the row is being inserted, true forever after: the insert is the only
      # write the ledger ever performs.
      def readonly?
        persisted?
      end

      def allowed?
        outcome == ALLOW
      end

      def denied?
        outcome == DENY
      end
    end
  end
end
