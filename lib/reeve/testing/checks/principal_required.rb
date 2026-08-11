# frozen_string_literal: true

module Reeve
  module Testing
    module Checks
      # FR-001: with no resolvable principal, the call is denied before any policy is
      # consulted.
      #
      # The evidence is the rule. `no_principal` is only reachable on the path that denies
      # *ahead* of authorization; a denial carrying any other rule means the policy was
      # asked a question about nobody, and got an answer.
      #
      #   Reeve::Checks::PrincipalRequired.new(tool: InvoiceSearchTool).call
      class PrincipalRequired < Base
        def call
          made = attempt(principal: nil)
          return held(made) if made.denial&.rule == Decision::NO_PRINCIPAL
          return wrong_rule(made) if made.denied?
          return raised(made) if made.failed?

          allowed(made)
        end

        private

        def held(made)
          passed("#{tool_label} denies with no_principal when no principal resolves",
                 rule: made.denial.rule)
        end

        def wrong_rule(made)
          failed(
            "expected #{tool_label} to deny with no_principal when no principal resolves, " \
            "but it denied with #{made.denial.rule} — the policy was consulted before the " \
            "principal was established",
            rule: made.denial.rule
          )
        end

        def raised(made)
          failed(
            "expected #{tool_label} to deny with no_principal when no principal resolves, " \
            "but it raised #{made.error.class}: #{made.error.message}",
            rule: nil, error: made.error.class.name
          )
        end

        def allowed(made)
          returned = identifiers(made.records)
          failed(
            "expected #{tool_label} to deny when no principal resolves, but it allowed the " \
            "call and returned #{pluralize(returned.size, 'record')}: " \
            "#{format_identifiers(returned)}",
            rule: nil, returned: returned
          )
        end
      end
    end
  end
end
