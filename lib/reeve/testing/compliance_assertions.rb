# frozen_string_literal: true

module Reeve
  module Testing
    # The shared compliance suite (FR-018), for Minitest. Including it *is* the suite:
    # Minitest runs every `test_`-prefixed method it finds.
    #
    #   class ComplianceTest < ActiveSupport::TestCase
    #     include Reeve::Testing::ComplianceAssertions
    #   end
    #
    # Host setup is two fixture principals with disjoint records and nothing else:
    #
    #   Reeve::Testing.compliance_principals = -> { [users(:alice), users(:bob)] }
    #
    # One method per check, matching the RSpec shared example group one for one, so a red
    # build names the guarantee that broke rather than reporting "compliance" as one
    # undifferentiated failure.
    module ComplianceAssertions
      include Assertions

      Checks::ALL.each do |check|
        # CrossPrincipalLeak -> test_reeve_cross_principal_leak
        method_name = "test_reeve_#{check.check_name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase}"

        define_method(method_name) do
          report = Checks.run(check, principals: Testing.compliance_principals)
          assert report.passed?, report.to_s
          report
        end
      end
    end
  end
end
