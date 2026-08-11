# frozen_string_literal: true

module Reeve
  module Audit
    # The documented way to read the ledger (FR-013): one scope per query axis —
    # principal, agent, tool, outcome, time range — each backed by one of the composite
    # indexes the generated migration creates.
    #
    #   Q = Reeve::Audit::Query
    #   Q.for_principal(user)
    #     .for_agent("claude-desktop")
    #     .between(1.week.ago, Time.current)
    #     .pluck(:tool_name, :record_type, :record_ids, :outcome, :rule)
    #
    # The scopes are also extended onto Entry, so a host that would rather work with the
    # model directly gets the same chain. There is deliberately no scope that writes.
    module Query
      # Defined once and used from two places: on Query, +all+ opens on the whole ledger;
      # on Entry (and on a relation being chained), +all+ is the current scope, which is
      # what makes these compose in any order.
      module Scopes
        def for_principal(principal)
          all.where(Query.principal_key(principal))
        end

        def for_agent(agent_id)
          all.where(agent_id: agent_id.to_s)
        end

        def for_tool(tool_name)
          all.where(tool_name: tool_name.to_s)
        end

        def allowed
          all.where(outcome: Entry::ALLOW)
        end

        def denied
          all.where(outcome: Entry::DENY)
        end

        # By occurred_at: the ledger is ordered by when the call happened, not by when the
        # row landed.
        def between(from, to)
          all.where(occurred_at: from..to)
        end
      end

      extend Scopes

      class << self
        def all
          Entry.all
        end

        # How a principal becomes a pair of columns. Mirrors Reeve::Context#principal_type
        # and #principal_id exactly — a query that derived the key differently would
        # quietly fail to find the rows the envelope wrote.
        #
        # Accepts the principal itself, or `type:`/`id:` for when an incident report is
        # all that survives of them.
        def principal_key(principal)
          return explicit_key(principal) if principal.is_a?(Hash)

          {
            principal_type: principal.class.name,
            principal_id: principal.respond_to?(:id) ? principal.id.to_s : principal.to_s
          }
        end

        private

        def explicit_key(attributes)
          {
            principal_type: attributes[:type]&.to_s,
            principal_id: attributes[:id]&.to_s
          }
        end
      end
    end
  end
end

Reeve::Audit::Entry.extend(Reeve::Audit::Query::Scopes)
