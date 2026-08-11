# frozen_string_literal: true

module Reeve
  module Testing
    module Checks
      # FR-009: every entry explains itself.
      #
      # A ledger row that records *that* a call was denied but not *what* denied it is the
      # row you are holding during an incident, and it answers nothing. The gem's own
      # recorder cannot write one — Entry validates the column — but a host-supplied
      # recorder can, which is exactly the case this check covers.
      #
      #   Reeve::Checks::RulePresent.new(tool: InvoiceSearchTool, principal: alice).call
      class RulePresent < Base
        def initialize(tool:, principal:, arguments: {}, invoke: nil, ledger: nil)
          super(tool: tool, arguments: arguments, invoke: invoke, ledger: ledger)
          @principal = principal
        end

        def call
          return ledger_unavailable("the deciding rule") unless ledger.available?

          entries = attempt(principal: @principal).rows
          return no_entry if entries.empty?

          missing = entries.reject { |entry| present?(entry.rule) }
          return held(entries) if missing.empty?

          failed(
            "expected every audit entry for #{tool_label} to name the rule that decided, " \
            "but entry #{missing.map(&:id).join(', ')} has no rule",
            entries: entries.size, without_rule: missing.map(&:id)
          )
        end

        private

        def held(entries)
          passed("every audit entry #{tool_label} produced names the rule that decided",
                 rules: entries.map(&:rule))
        end

        def no_entry
          failed("expected #{tool_label} to write an audit entry naming the rule that " \
                 "decided, but it produced no entry at all",
                 entries: 0)
        end

        def present?(value)
          !value.nil? && !value.to_s.strip.empty?
        end
      end
    end
  end
end
