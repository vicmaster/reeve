# frozen_string_literal: true

require_relative "support/fixtures"
require "minitest"
require "reeve/rspec"
require "reeve/minitest"

# T047 / SC-009, FR-026. One table of scenarios, three front-ends.
#
# This is the spec that makes FR-019 mean something. Because the check builds the message
# and the front-ends only carry it, the same violation must produce the *identical string*
# through an RSpec matcher, a Minitest assertion, and a bare `check.call` — and if anyone
# ever writes a sentence in a matcher, this goes red on the same day.
RSpec.describe "the testing kit across all three front-ends", :reeve_fixtures do
  # Each scenario names the violation, how to build the check, and how each front-end is
  # asked the same question. Adding a check means adding a row here.
  SCENARIOS = [
    {
      name: "a cross-principal leak",
      outcome: :failed,
      check: lambda { |c|
        Reeve::Checks::CrossPrincipalLeak.new(
          tool: c[:tool], principals: [c[:principals].first], expect: :nothing
        )
      },
      tool: :leaker,
      matcher: ->(m, s) { m.deny_access_for(s[:principals].first) },
      assertion: ->(t, s, a) { a.assert_denies_access_for(t, s[:principals].first) }
    },
    {
      name: "a tool that denies the stranger correctly",
      outcome: :passed,
      check: lambda { |c|
        Reeve::Checks::CrossPrincipalLeak.new(
          tool: c[:tool], principals: [c[:principals].first], expect: :nothing
        )
      },
      tool: :unguarded,
      matcher: ->(m, s) { m.deny_access_for(s[:principals].first) },
      assertion: ->(t, s, a) { a.assert_denies_access_for(t, s[:principals].first) }
    },
    {
      name: "an audit bypass",
      outcome: :failed,
      check: lambda { |c|
        Reeve::Checks::AuditCoverage.new(
          tool: c[:tool], principal: c[:principals].first,
          invoke: ReeveFixtures::BYPASSING_INVOKER
        )
      },
      tool: :bypassing,
      matcher: lambda { |m, s|
        m.audit_every_call.for_principal(s[:principals].first)
         .invoked_by(ReeveFixtures::BYPASSING_INVOKER)
      },
      assertion: lambda { |t, s, a|
        a.assert_audits_every_call(t, principal: s[:principals].first,
                                      invoke: ReeveFixtures::BYPASSING_INVOKER)
      }
    },
    {
      name: "a correctly audited tool",
      outcome: :passed,
      check: lambda { |c|
        Reeve::Checks::AuditCoverage.new(tool: c[:tool], principal: c[:principals].first)
      },
      tool: :control,
      matcher: ->(m, s) { m.audit_every_call.for_principal(s[:principals].first) },
      assertion: ->(t, s, a) { a.assert_audits_every_call(t, principal: s[:principals].first) }
    },
    {
      name: "a missing guard declaration",
      outcome: :failed,
      check: ->(c) { Reeve::Checks::GuardDeclared.new(tool: c[:tool]) },
      tool: :unguarded,
      matcher: ->(m, _s) { m.pass_reeve_check },
      assertion: ->(t, _s, a) { a.assert_reeve_check(Reeve::Checks::GuardDeclared.new(tool: t)) },
      via_check_object: true
    }
  ].freeze

  TOOLS = {
    control: -> { ReeveFixtures::CompliantInvoiceTool },
    leaker: -> { ReeveFixtures::LeakyInvoiceTool },
    bypassing: -> { ReeveFixtures::BypassingInvoiceTool },
    unguarded: -> { ReeveFixtures::UnguardedInvoiceTool }
  }.freeze

  # ---- the three front-ends, each asked the same question ---------------------

  # 1. Plain Ruby: no test framework in sight.
  def via_plain_ruby(scenario, tool, setup)
    result = scenario[:check].call(tool: tool, principals: setup[:principals]).call
    result.passed? ? [:passed, nil] : [:failed, result.message]
  end

  # 2. RSpec, through the matcher protocol RSpec itself uses.
  def via_rspec(scenario, tool, setup)
    matchers = Object.new.extend(Reeve::Testing::Matchers)
    matcher = scenario[:matcher].call(matchers, setup)
    subject = scenario[:via_check_object] ? check_object(scenario, tool, setup) : tool

    matcher.matches?(subject) ? [:passed, nil] : [:failed, matcher.failure_message]
  end

  # 3. Minitest, inside a real Minitest::Test so `assert` behaves exactly as it would in
  #    a host application.
  def via_minitest(scenario, tool, setup)
    test_case = Class.new(Minitest::Test).new(:parity)
    test_case.extend(Reeve::Testing::Assertions)
    scenario[:assertion].call(tool, setup, test_case)
    [:passed, nil]
  rescue Minitest::Assertion => e
    [:failed, e.message]
  end

  def check_object(scenario, tool, setup)
    scenario[:check].call(tool: tool, principals: setup[:principals])
  end

  SCENARIOS.each do |scenario|
    context "with #{scenario[:name]}" do
      let(:tool)  { TOOLS.fetch(scenario[:tool]).call }
      let(:setup) { { principals: [bob, alice] } }

      it "reports the same outcome and the same message from all three front-ends" do
        plain    = via_plain_ruby(scenario, tool, setup)
        rspec    = via_rspec(scenario, tool, setup)
        minitest = via_minitest(scenario, tool, setup)

        expect(plain.first).to eq(scenario[:outcome]),
                               "the check itself did not #{scenario[:outcome]}: #{plain.last}"
        expect(rspec).to eq(plain), "RSpec diverged from the check"
        expect(minitest).to eq(plain), "Minitest diverged from the check"
      end
    end
  end

  it "covers both a failing and a passing scenario, so parity is not parity on nothing" do
    expect(SCENARIOS.map { |scenario| scenario[:outcome] }.uniq)
      .to contain_exactly(:passed, :failed)
  end

  # FR-018 from both suites at once: the shared example group and the Minitest compliance
  # test case must reach the same verdict on the same registry.
  describe "the two compliance suites" do
    before { Reeve::Testing.compliance_principals = -> { ReeveFixtures.principals } }

    after { Reeve::Testing.reset! }

    def minitest_compliance
      test_case = Class.new(Minitest::Test) { include Reeve::Testing::ComplianceAssertions }
      test_case.public_instance_methods.grep(/^test_reeve_/).sort.map do |method|
        instance = test_case.new(method)
        begin
          instance.public_send(method)
          [method.to_s, :passed]
        rescue Minitest::Assertion => e
          [method.to_s, [:failed, e.message]]
        end
      end
    end

    def rspec_compliance
      Reeve::Checks::ALL.map do |check|
        report = Reeve::Checks.run(check, principals: Reeve::Testing.compliance_principals)
        name = "test_reeve_#{check.check_name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase}"
        report.passed? ? [name, :passed] : [name, [:failed, report.to_s]]
      end.sort
    end

    it "agree, check by check and message by message, on a registry that leaks" do
      expect(minitest_compliance).to eq(rspec_compliance)
      outcomes = minitest_compliance.map(&:last)
      expect(outcomes).to include(:passed)
      expect(outcomes.reject { |outcome| outcome == :passed }).not_to be_empty
    end
  end
end
