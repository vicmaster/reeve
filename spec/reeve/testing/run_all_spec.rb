# frozen_string_literal: true

require_relative "support/fixtures"

# T046 / FR-018. The compliance suite's engine: one call, every registered guarded tool,
# one report a CI step can print and stop on.
RSpec.describe "Reeve::Checks.run_all", :reeve_fixtures do
  def run_all(**options)
    Reeve::Checks.run_all(principals: [alice, bob], **options)
  end

  it "checks every registered guarded tool, plus the ledger itself" do
    report = run_all

    tools = report.results.map { |result| result.details[:tool] }.compact.uniq

    expect(tools).to contain_exactly(
      "ReeveFixtures::CompliantInvoiceTool",
      "ReeveFixtures::LeakyInvoiceTool",
      "ReeveFixtures::BypassingInvoiceTool",
      "ReeveFixtures::MisdeclaredRedactionTool"
    )
    expect(report.results.map(&:check)).to include("ContractVersion")
  end

  it "runs the ledger-wide checks once, not once per tool" do
    report = run_all

    expect(report.results.count { |result| result.check == "ContractVersion" }).to eq(1)
  end

  it "is green when every tool it is pointed at is compliant" do
    report = run_all(tools: [ReeveFixtures::CompliantInvoiceTool])

    expect(report).to be_passed
    expect(report.failures).to be_empty
    expect(report.to_s).to eq("reeve compliance: 7 checks, 7 passed, 0 failed")
  end

  it "fails as a whole when any one check fails" do
    report = run_all(tools: [ReeveFixtures::LeakyInvoiceTool])

    expect(report).to be_failed
    expect(report.failures.map(&:check)).to include("CrossPrincipalLeak")
  end

  it "names the offending tool and check in a body a human can act on (SC-007)" do
    report = run_all(tools: [ReeveFixtures::LeakyInvoiceTool])

    expect(report.to_s).to start_with("reeve compliance: 7 checks, 6 passed, 1 failed")
    expect(report.to_s).to include("FAIL CrossPrincipalLeak")
    expect(report.to_s).to include("ReeveFixtures::LeakyInvoiceTool")
  end

  it "catches the audit bypass when the host's own invoker reaches past the envelope" do
    report = run_all(
      tools: [ReeveFixtures::BypassingInvoiceTool], invoke: ReeveFixtures::BYPASSING_INVOKER
    )

    expect(report.failures.map(&:check))
      .to include("AuditCoverage", "PrincipalRequired", "CrossPrincipalLeak")
    expect(report.to_s).to include("it is invoked outside Reeve.invoke")
  end

  it "reports every failure, not only the first" do
    report = run_all(
      tools: [ReeveFixtures::LeakyInvoiceTool, ReeveFixtures::MisdeclaredRedactionTool]
    )

    expect(report.failures.size).to be >= 2
    expect(report.size).to eq(13)
  end

  it "runs with an empty registry rather than blowing up" do
    Reeve.reset_registry!

    report = run_all

    expect(report.size).to eq(1)
    expect(report).to be_passed
  end

  describe Reeve::Testing::Report do
    let(:passing) { Reeve::Testing::Result.passed(check: "GuardDeclared", message: "fine") }
    let(:failing) { Reeve::Testing::Result.failed(check: "AuditCoverage", message: "not fine") }

    it "summarises a single check in the singular" do
      expect(described_class.new([passing]).to_s)
        .to eq("reeve compliance: 1 check, 1 passed, 0 failed")
    end

    it "prints each failure in full beneath the summary" do
      expect(described_class.new([passing, failing]).to_s).to eq(
        "reeve compliance: 2 checks, 1 passed, 1 failed\n\nFAIL AuditCoverage\n  not fine"
      )
    end
  end

  # The plain-Ruby path the contract promises: no test framework anywhere in this example.
  it "is usable as a CI gate on its own" do
    report = run_all(tools: [ReeveFixtures::LeakyInvoiceTool])
    exit_code = report.passed? ? 0 : 1

    expect(exit_code).to eq(1)
    expect(report.to_s).to include("FAIL")
  end
end
