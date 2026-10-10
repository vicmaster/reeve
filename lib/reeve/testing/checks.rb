# frozen_string_literal: true

require_relative "checks/base"
require_relative "checks/guard_declared"
require_relative "checks/cross_principal_leak"
require_relative "checks/audit_coverage"
require_relative "checks/rule_present"
require_relative "checks/redaction_holds"
require_relative "checks/principal_required"
require_relative "checks/contract_version"
require_relative "checks/endpoint_coverage"
require_relative "checks/ledger_chain"

module Reeve
  module Testing
    # The guarantees, as objects.
    #
    # This is the whole of the testing kit's logic. The RSpec matchers and the Minitest
    # assertions are adapters over it and contain no assertions of their own, which is why
    # the same violation reads identically from either — and from neither:
    #
    #   report = Reeve::Checks.run_all(principals: [alice, bob])
    #   abort report.to_s if report.failed? || report.nothing_checked?
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
        ContractVersion,
        EndpointCoverage,
        LedgerChain
      ].freeze

      # The checks that are asked once — about the ledger, or about the endpoint as a
      # whole — rather than once per tool.
      GLOBAL = [ContractVersion, EndpointCoverage, LedgerChain].freeze

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
        if GLOBAL.include?(check)
          return Report.new([build(check, tool: nil, principals: principals, tools: tools,
                                          invoke: invoke, ledger: ledger).call])
        end

        subjects = tools || Testing.compliance_tools
        return Report.new([nothing_to_check(check, tools)]) if subjects.empty?

        Report.new(
          subjects.map do |tool|
            build(check, tool: tool, principals: principals, arguments: arguments,
                         invoke: invoke, ledger: ledger).call
          end
        )
      end

      # A per-tool check over no tools establishes nothing, and an empty Report reads as
      # passed — the green that means "did not look". So an empty population is one skip,
      # saying which of the three ways the run came to have nothing in it.
      def self.nothing_to_check(check, tools)
        reason =
          if !tools.nil? then "the run was given tools: []"
          elsif Testing.compliance_tools_narrowed? then "compliance_tools is []"
          else "the registry is empty and no endpoint inventory routes a tool"
          end

        Result.skipped(
          check: check.check_name,
          message: "no compliance tools to check, so #{check.check_name} established " \
                   "nothing — #{reason}",
          details: { coverage: :none }
        )
      end
      private_class_method :nothing_to_check

      # Every per-tool check for one tool, instantiated but not run.
      def self.for_tool(tool, principals:, arguments: {}, invoke: nil, ledger: nil)
        (ALL - GLOBAL).map do |check|
          build(check, tool: tool, principals: principals, arguments: arguments,
                       invoke: invoke, ledger: ledger)
        end
      end

      # The one place that knows what each check's constructor wants. Front-ends and hosts
      # ask for a check by class and get a configured one back.
      #
      # +tools+ is the population the run was given, which only EndpointCoverage reads: an
      # explicit list is a narrowed run, and it must say so.
      def self.build(check, tool:, principals:, arguments: {}, invoke: nil, ledger: nil,
                     tools: nil)
        common = { tool: tool, arguments: arguments, invoke: invoke, ledger: ledger }

        case check.check_name
        when "GuardDeclared"      then GuardDeclared.new(tool: tool, ledger: ledger)
        when "ContractVersion"    then ContractVersion.new(ledger: ledger)
        when "EndpointCoverage"   then EndpointCoverage.new(tools: tools, ledger: ledger)
        when "LedgerChain"        then LedgerChain.new(tools: tools, principals: principals,
                                                       invoke: invoke, ledger: ledger)
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
