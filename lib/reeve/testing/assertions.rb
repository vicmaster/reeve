# frozen_string_literal: true

module Reeve
  module Testing
    # The Minitest front-end.
    #
    #   require "reeve/minitest"
    #
    #   class InvoiceSearchToolTest < ActiveSupport::TestCase
    #     include Reeve::Testing::Assertions
    #
    #     test "does not leak across principals" do
    #       assert_denies_access_for InvoiceSearchTool, stranger, query: "AC"
    #     end
    #
    #     test "is audited" do
    #       assert_audits_every_call InvoiceSearchTool
    #     end
    #   end
    #
    # Note what this module does *not* reference: Minitest. It calls the +assert+ its
    # including class already provides, which is why requiring it costs a stock
    # `rails new` application nothing and adds no dependency to this gem (FR-026).
    #
    # Every message passed to +assert+ is the check's own. Nothing here writes a sentence.
    module Assertions
      # FR-016.
      def assert_denies_access_for(tool, principal, invoke: nil, ledger: nil, **arguments)
        assert_reeve_check(
          Checks::CrossPrincipalLeak.new(
            tool: tool, principals: [principal], expect: :nothing,
            arguments: arguments, invoke: invoke, ledger: ledger
          )
        )
      end

      # FR-016, the compliance form: two principals with disjoint records.
      def assert_no_cross_principal_leak(tool, principals: nil, invoke: nil, ledger: nil,
                                         **arguments)
        assert_reeve_check(
          Checks::CrossPrincipalLeak.new(
            tool: tool, principals: principals || Testing.compliance_principals,
            arguments: arguments, invoke: invoke, ledger: ledger
          )
        )
      end

      # FR-017. Pass `invoke:` to point the assertion at the host's own call site, which
      # is where an audit bypass actually lives.
      def assert_audits_every_call(tool, principal: nil, invoke: nil, ledger: nil, **arguments)
        assert_reeve_check(
          Checks::AuditCoverage.new(
            tool: tool, principal: principal || Testing.compliance_principals.first,
            arguments: arguments, invoke: invoke, ledger: ledger
          )
        )
      end

      # SC-009's escape hatch: any of the seven, straight from Minitest.
      def assert_reeve_check(check)
        result = check.call
        assert result.passed?, result.message
        result
      end

      # A whole Report at once, for a host that would rather have one test than seven.
      def assert_reeve_compliance(principals: nil, **options)
        report = Checks.run_all(
          principals: principals || Testing.compliance_principals, **options
        )
        assert report.passed?, report.to_s
        report
      end
    end
  end
end
