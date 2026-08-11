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
        reports = ALL.map do |check|
          run(check, principals: principals, tools: tools, arguments: arguments,
                     invoke: invoke, ledger: ledger)
        end

        Report.new(reports.flat_map(&:results))
      end

      # One check, across every tool it applies to. This is what both front-ends build a
      # test method out of, so that a failing suite names the guarantee that broke rather
      # than reporting "compliance" as one undifferentiated red.
      def self.run(check, principals:, tools: nil, arguments: {}, invoke: nil, ledger: nil)
        return Report.new([check.new(ledger: ledger).call]) if GLOBAL.include?(check)

        subjects = tools || Reeve.registry.map(&:tool_class)
        Report.new(
          subjects.map do |tool|
            build(check, tool: tool, principals: principals, arguments: arguments,
                         invoke: invoke, ledger: ledger).call
          end
        )
      end

      # Every per-tool check for one tool, instantiated but not run.
      def self.for_tool(tool, principals:, arguments: {}, invoke: nil, ledger: nil)
        (ALL - GLOBAL).map do |check|
          build(check, tool: tool, principals: principals, arguments: arguments,
                       invoke: invoke, ledger: ledger)
        end
      end

      # The one place that knows what each check's constructor wants. Front-ends and hosts
      # ask for a check by class and get a configured one back.
      def self.build(check, tool:, principals:, arguments: {}, invoke: nil, ledger: nil)
        common = { tool: tool, arguments: arguments, invoke: invoke, ledger: ledger }

        case check.check_name
        when "GuardDeclared"      then GuardDeclared.new(tool: tool, ledger: ledger)
        when "ContractVersion"    then ContractVersion.new(ledger: ledger)
        when "PrincipalRequired"  then PrincipalRequired.new(**common)
        when "CrossPrincipalLeak" then CrossPrincipalLeak.new(principals: Array(principals),
                                                              **common)
        else check.new(principal: Array(principals).first, **common)
        end
      end
    end
  end

  # The name the contract and every host will type. `Reeve::Checks::CrossPrincipalLeak`
  # is the public spelling; the file layout under testing/ is an implementation detail.
  Checks = Testing::Checks
end
