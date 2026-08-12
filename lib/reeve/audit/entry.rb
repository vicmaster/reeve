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

      REQUIRED = %i[
        invocation_id occurred_at agent_id tool_name outcome rule guard contract_version
      ].freeze

      validates(*REQUIRED, presence: true)
      validates :invocation_id, uniqueness: true
      validates :outcome, inclusion: { in: OUTCOMES, message: "must be allow or deny" }

      before_destroy { throw :abort }

      # The contract version this build of the gem writes (FR-015).
      #
      # Class-level, and deliberately not the same question as `entry.contract_version`:
      # this is what the gem implements *now*, while the column on each row is the shape
      # that row was actually written under. They differ for every row written before an
      # upgrade, which is the whole reason the column exists.
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
