# frozen_string_literal: true

module Reeve
  module Testing
    module Checks
      # FR-017, FR-008: exactly one ledger entry per invocation.
      #
      # The failure this is built to catch is not a broken tool but a caller that reaches
      # past the envelope — `MyTool.new.call(...)` somewhere in a controller. So the check
      # takes the invoker as a collaborator, defaulting to +Reeve.invoke+, and counts the
      # rows that appeared around it. A tool invoked outside the envelope produces none.
      #
      #   Reeve::Checks::AuditCoverage.new(tool: InvoiceExportTool, principal: alice).call
      class AuditCoverage < Base
        def initialize(tool:, principal:, arguments: {}, invoke: nil, ledger: nil)
          super(tool: tool, arguments: arguments, invoke: invoke, ledger: ledger)
          @principal = principal
        end

        def call
          return ledger_unavailable("audit coverage") unless ledger.available?

          made = attempt(principal: @principal)
          count = made.rows.size
          return held(count) if count == 1

          failed(message_for(count), entries: count, error: made.error&.class&.name)
        end

        private

        def held(count)
          passed("#{tool_label} produced exactly one audit entry for 1 invocation",
                 entries: count)
        end

        def message_for(count)
          entries = "#{count} audit #{count == 1 ? 'entry' : 'entries'}"
          base = "expected every call to be audited, but #{tool_label} produced " \
                 "#{entries} for 1 invocation"
          count.zero? ? "#{base} — it is invoked outside Reeve.invoke" : base
        end
      end
    end
  end
end
