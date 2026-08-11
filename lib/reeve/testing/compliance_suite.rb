# frozen_string_literal: true

# The shared compliance suite (FR-018), for RSpec.
#
#   RSpec.describe "reeve compliance" do
#     it_behaves_like "a reeve-compliant server"
#   end
#
# Host setup is two fixture principals with disjoint records and nothing else:
#
#   Reeve::Testing.compliance_principals = -> { [users(:alice), users(:bob)] }
#
# One example per check rather than one for the lot, so a red build names the guarantee
# that broke — "CrossPrincipalLeak" is an incident, "compliance" is a shrug.
RSpec.shared_examples "a reeve-compliant server" do
  Reeve::Checks::ALL.each do |check|
    it "satisfies #{check.check_name} for every registered guarded tool" do
      report = Reeve::Checks.run(check, principals: Reeve::Testing.compliance_principals)

      expect(report).to be_passed, report.to_s
    end
  end
end
