# frozen_string_literal: true

require "support/optional/mcp_sdk"
require_relative "support/fixtures"
require "minitest"
require "reeve/rspec"
require "reeve/minitest"

mcp_available = defined?(MCP::Tool) ? true : false

# Story 3: the testing kit runs a library's tools with the lines a fast-mcp host writes,
# with no custom `invoke:`, one ledger row per call, and the same verdict from the check,
# an RSpec matcher and a Minitest assertion (FR-050 to FR-052).
RSpec.shared_examples "the testing kit on an adapter's tools" do
  def via_check(check)
    result = check.call
    [result.status, result.message]
  end

  def via_rspec(matcher, tool)
    matcher.matches?(tool) ? [:passed, nil] : [:failed, matcher.failure_message]
  end

  def via_minitest
    test_case = Class.new(Minitest::Test).new(:parity)
    test_case.extend(Reeve::Testing::Assertions)
    yield test_case
    [:passed, nil]
  rescue Minitest::Assertion => e
    [:failed, e.message]
  end

  def matchers
    Object.new.extend(Reeve::Testing::Matchers)
  end

  it "runs every per-tool check on a guarded tool without a custom invoke:, and passes" do
    report = Reeve::Checks.run_all(principals: [alice, bob], tools: [guarded],
                                   arguments: arguments)
    failures = report.results.reject { |r| r.passed? || r.skipped? }

    expect(failures.map(&:message)).to eq([])
  end

  it "names an unguarded tool in GuardDeclared" do
    result = Reeve::Checks::GuardDeclared.new(tool: unguarded).call

    expect(result).to be_failed
    expect(result.message).to include("has no guard_with declaration")
  end

  it "writes exactly one ledger row per kit call (FR-051)" do
    result = Reeve::Checks::AuditCoverage.new(tool: guarded, principal: alice,
                                              arguments: arguments).call

    expect(result).to be_passed, result.message
  end

  it "gives the same verdict for deny_access_for from the check, RSpec and Minitest" do
    check = Reeve::Checks::CrossPrincipalLeak.new(tool: guarded, principals: [stranger],
                                                  expect: :nothing, arguments: arguments)
    plain = via_check(check)
    plain = [plain.first, plain.first == :passed ? nil : plain.last]

    rspec = via_rspec(matchers.deny_access_for(stranger).with(**arguments), guarded)
    minitest = via_minitest do |t|
      t.assert_denies_access_for(guarded, stranger, **arguments)
    end

    expect(plain.first).to eq(:passed)
    expect([rspec, minitest]).to eq([plain, plain])
  end

  it "gives the same verdict for audit_every_call from the check, RSpec and Minitest" do
    rspec = via_rspec(matchers.audit_every_call.for_principal(alice).with(**arguments), guarded)
    minitest = via_minitest do |t|
      t.assert_audits_every_call(guarded, principal: alice, **arguments)
    end

    expect(rspec).to eq([:passed, nil])
    expect(minitest).to eq(rspec)
  end

  # Unscoped output is refused, so nothing leaks and the leak check holds; the ledger
  # shows why every call was refused.
  it "sees unscoped output refused, not leaked" do
    marker = Reeve::Audit::Entry.maximum(:id).to_i
    result = Reeve::Checks::CrossPrincipalLeak.new(tool: leaky, principals: [alice, bob],
                                                   arguments: arguments).call

    expect(result).to be_passed
    expect(Reeve::Audit::Entry.where("id > ?", marker).pluck(:rule).uniq)
      .to eq(["unscoped_derived_result"])
  end
end

RSpec.describe "the testing kit on official SDK tools", :reeve_fixtures, if: mcp_available do
  let(:stranger) { Owner.new(99) }
  let(:arguments) { { query: "" } }

  before do
    require "reeve/mcp"

    stub_const("SdkInvoiceTool", Class.new(MCP::Tool) do
      tool_name "sdk_invoices"
      guard_with ReeveFixtures::GoodInvoicePolicy

      def self.call(query:, server_context:)
        _ = server_context
        numbers = scoped(Invoice).where("number LIKE ?", "#{query}%").pluck(:number)
        MCP::Tool::Response.new([{ type: "text", text: numbers.join(",") }])
      end
    end)

    stub_const("SdkLeakyTool", Class.new(MCP::Tool) do
      tool_name "sdk_leaky"
      guard_with ReeveFixtures::GoodInvoicePolicy

      def self.call(query:)
        numbers = Invoice.where("number LIKE ?", "#{query}%").pluck(:number)
        MCP::Tool::Response.new([{ type: "text", text: numbers.join(",") }])
      end
    end)

    stub_const("SdkUnguardedTool", Class.new(MCP::Tool) do
      tool_name "sdk_unguarded"

      def self.call(**) = MCP::Tool::Response.new([])
    end)
  end

  let(:guarded) { SdkInvoiceTool }
  let(:leaky) { SdkLeakyTool }
  let(:unguarded) { SdkUnguardedTool }

  include_examples "the testing kit on an adapter's tools"

  it "names a block-registered tool by its published name" do
    server = MCP::Server.new(name: "app", tools: [])
    server.define_tool(name: "list_block") { |**| MCP::Tool::Response.new([]) }

    result = Reeve::Checks::GuardDeclared.new(tool: server.tools["list_block"]).call

    expect(result.message).to start_with("expected list_block to declare a guard")
  end

  it "never offers MCP::Tool itself to the compliance suite" do
    expect(Reeve::Testing.compliance_tools).not_to include(MCP::Tool)
  end
end

action_mcp_available = begin
  require "action_mcp"
  true
rescue LoadError
  false
end

RSpec.describe "the testing kit on ActionMCP tools", :reeve_fixtures, if: action_mcp_available do
  let(:stranger) { Owner.new(99) }
  let(:arguments) { { query: "" } }

  before do
    require "reeve/action_mcp"

    stub_const("ActionInvoiceTool", Class.new(ActionMCP::Tool) do
      tool_name "action_invoices"
      property :query, type: "string"
      guard_with ReeveFixtures::GoodInvoicePolicy

      def perform
        scoped(Invoice).where("number LIKE ?", "#{query}%").each { |i| render(text: i.number) }
      end
    end)

    stub_const("ActionLeakyTool", Class.new(ActionMCP::Tool) do
      tool_name "action_leaky"
      property :query, type: "string"
      guard_with ReeveFixtures::GoodInvoicePolicy

      def perform
        Invoice.where("number LIKE ?", "#{query}%").each { |i| render(text: i.number) }
      end
    end)

    stub_const("ActionUnguardedTool", Class.new(ActionMCP::Tool) do
      tool_name "action_unguarded"

      def perform = render(text: "ok")
    end)
  end

  let(:guarded) { ActionInvoiceTool }
  let(:leaky) { ActionLeakyTool }
  let(:unguarded) { ActionUnguardedTool }

  include_examples "the testing kit on an adapter's tools"

  it "raises naming the tool when the kit passes input the schema refuses" do
    stub_const("StrictTool", Class.new(ActionMCP::Tool) do
      tool_name "strict"
      property :count, type: "integer", required: true
      guard_with ReeveFixtures::GoodInvoicePolicy

      def perform = render(text: count.to_s)
    end)

    expect { StrictTool.reeve_run({}) }.to raise_error(ArgumentError, /strict: invalid input/)
  end
end
