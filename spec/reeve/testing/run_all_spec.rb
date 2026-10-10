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
    expect(report.to_s).to start_with(
      "reeve compliance: 9 checks, 8 passed, 0 failed, 1 skipped\n\nSKIP EndpointCoverage"
    )
  end

  it "fails as a whole when any one check fails" do
    report = run_all(tools: [ReeveFixtures::LeakyInvoiceTool])

    expect(report).to be_failed
    expect(report.failures.map(&:check)).to include("CrossPrincipalLeak")
  end

  it "names the offending tool and check in a body a human can act on (SC-007)" do
    report = run_all(tools: [ReeveFixtures::LeakyInvoiceTool])

    expect(report.to_s).to start_with("reeve compliance: 9 checks, 7 passed, 1 failed, 1 skipped")
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
    expect(report.size).to eq(15) # six per-tool checks for each of two tools, plus three ledger-wide
  end

  it "runs with an empty registry rather than blowing up, and claims nothing per tool" do
    Reeve.reset_registry!

    report = run_all
    per_tool = report.results.reject do |result|
      %w[ContractVersion EndpointCoverage LedgerChain].include?(result.check)
    end

    # One skip for each of the six per-tool checks, plus the three ledger-wide checks, of
    # which only ContractVersion establishes anything: the ledger's shape needs no tool.
    expect(report.size).to eq(9)
    expect(per_tool.map(&:check)).to contain_exactly(
      "GuardDeclared", "CrossPrincipalLeak", "AuditCoverage", "RulePresent",
      "RedactionHolds", "PrincipalRequired"
    )
    expect(per_tool).to all(be_skipped)
    expect(report.passes.map(&:check)).to eq(["ContractVersion"])
    expect(report).not_to be_skipped
  end

  # A per-tool check over no tools establishes nothing, and a Report of no results reads as
  # passed. So an empty population is one skipped result, with its reason, never zero.
  describe "Reeve::Checks.run with no tools to check" do
    per_tool = Reeve::Checks::ALL - Reeve::Checks::GLOBAL

    per_tool.each do |check|
      it "skips #{check.check_name} rather than passing it" do
        report = Reeve::Checks.run(check, principals: [alice, bob], tools: [])

        expect(report.size).to eq(1)
        expect(report).to be_skipped
        expect(report.results.first.check).to eq(check.check_name)
        expect(report.to_s).to include("no compliance tools to check")
      end
    end

    it "says the run was given an empty tools: list" do
      report = Reeve::Checks.run(Reeve::Checks::GuardDeclared, principals: [alice, bob], tools: [])

      expect(report.results.first.message).to eq(
        "no compliance tools to check, so GuardDeclared established nothing — " \
        "the run was given tools: []"
      )
    end

    it "says compliance_tools is empty when the host narrowed it to nothing" do
      Reeve::Testing.compliance_tools = []

      report = Reeve::Checks.run(Reeve::Checks::GuardDeclared, principals: [alice, bob])

      expect(report.results.first.message).to end_with("— compliance_tools is []")
    ensure
      Reeve::Testing.reset!
    end

    it "says the registry is empty when reeve knows of no tool at all" do
      Reeve.reset_registry!

      report = Reeve::Checks.run(Reeve::Checks::GuardDeclared, principals: [alice, bob])

      expect(report.results.first.message).to end_with(
        "— the registry is empty and no endpoint inventory routes a tool"
      )
    end
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

    describe "a skipped check" do
      let(:skipped) do
        Reeve::Testing::Result.skipped(check: "EndpointCoverage", message: "did not look\nhere")
      end

      it "is neither a pass nor a failure, and is printed with its reason" do
        report = described_class.new([passing, skipped])

        expect(report).to be_passed
        expect(report.passes.size).to eq(1)
        expect(report.to_s).to eq(
          "reeve compliance: 2 checks, 1 passed, 0 failed, 1 skipped\n\n" \
          "SKIP EndpointCoverage\n  did not look\n  here"
        )
      end

      it "makes the report skipped only when nothing else was established" do
        expect(described_class.new([skipped])).to be_skipped
        expect(described_class.new([passing, skipped])).not_to be_skipped
        expect(described_class.new([])).not_to be_skipped
      end

      it "lists failures before skips, so the red reads first" do
        report = described_class.new([skipped, failing])

        expect(report.to_s.index("FAIL")).to be < report.to_s.index("SKIP")
      end
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
