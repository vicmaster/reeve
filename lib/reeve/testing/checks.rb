# frozen_string_literal: true

require_relative "checks/base"
require_relative "checks/guard_declared"
require_relative "checks/cross_principal_leak"
require_relative "checks/audit_coverage"
require_relative "checks/rule_present"
require_relative "checks/redaction_holds"
require_relative "checks/principal_required"
require_relative "checks/contract_version"

module Reeve
  module Testing
    # The seven guarantees, as objects.
    #
    # This is the whole of the testing kit's logic. The RSpec matchers and the Minitest
    # assertions are adapters over it and contain no assertions of their own, which is why
    # the same violation reads identically from either — and from neither:
    #
    #   report = Reeve::Checks.run_all(principals: [alice, bob])
    #   abort report.to_s unless report.passed?
    #
    # Nothing here loads a test framework (FR-026).
    module Checks
      ALL = [
        GuardDeclared,
        CrossPrincipalLeak,
        AuditCoverage,
        RulePresent,
        RedactionHolds,
        PrincipalRequired,
        ContractVersion
      ].freeze

      # The checks that are asked once about the ledger rather than once per tool.
      GLOBAL = [ContractVersion].freeze

      # The compliance suite's engine (FR-018): every check, against every registered
      # guarded tool, in one Report.
      #
      # +principals+ must be two fixture principals with disjoint records — that
      # disjointness is what makes a shared identifier proof of a leak.
      def self.run_all(principals:, tools: nil, arguments: {}, invoke: nil, ledger: nil)
        subjects = tools || Reeve.registry.map(&:tool_class)
        results = GLOBAL.map { |check| check.new(ledger: ledger).call }

        subjects.each do |tool|
          results.concat(
            for_tool(tool, principals: principals, arguments: arguments, invoke: invoke,
                           ledger: ledger).map(&:call)
          )
        end

        Report.new(results)
      end

      # Every per-tool check, instantiated but not run. Exposed because both front-ends
      # build their per-check test methods from it, and because a host that wants to run
      # one tool's checks in isolation should not have to know the constructors.
      def self.for_tool(tool, principals:, arguments: {}, invoke: nil, ledger: nil)
        principal = Array(principals).first
        common = { tool: tool, arguments: arguments, invoke: invoke, ledger: ledger }

        [
          GuardDeclared.new(tool: tool, ledger: ledger),
          CrossPrincipalLeak.new(principals: Array(principals), **common),
          AuditCoverage.new(principal: principal, **common),
          RulePresent.new(principal: principal, **common),
          RedactionHolds.new(principal: principal, **common),
          PrincipalRequired.new(**common)
        ]
      end
    end
  end

  # The name the contract and every host will type. `Reeve::Checks::CrossPrincipalLeak`
  # is the public spelling; the file layout under testing/ is an implementation detail.
  Checks = Testing::Checks
end
