# frozen_string_literal: true

module Reeve
  module Testing
    module Checks
      # FR-002, FR-004: a tool with no `guard_with` is not neutral, it is denied. This is
      # the check that tells you *before* production which of your tools that is.
      #
      #   Reeve::Checks::GuardDeclared.new(tool: InvoiceSearchTool).call
      class GuardDeclared < Base
        def call
          guard = declaration
          return failure if guard.nil?

          passed(
            "#{tool_label} is guarded by #{guard.policy_name} (action: #{guard.action})",
            policy: guard.policy_name, action: guard.action
          )
        end

        private

        def failure
          failed(
            "expected #{tool_label} to declare a guard, but it has no guard_with " \
            "declaration — reeve denies every call to an unguarded tool",
            policy: nil
          )
        end
      end
    end
  end
end
