# frozen_string_literal: true

require "support/optional/authorization_records"
require "reeve/audit"
require "reeve/audit/support/ledger"

action_mcp_available = begin
  require "action_mcp"
  true
rescue LoadError
  false
end

# ActionMCP needs Rails 8.1 and so Ruby 3.2+. Below that it cannot be installed, and these
# specs skip rather than pretend otherwise.
#
# Every example calls a tool the way ActionMCP's server does: `from_wire`, `with_context`,
# then `call`, which returns the ToolResponse sent to the client.
RSpec.describe "the ActionMCP adapter", if: action_mcp_available do
  let(:alice) { Owner.new(1) }
  let(:bob)   { Owner.new(2) }

  # What ActionMCP's session gives a tool: the client it negotiated with, and an id.
  let(:session) { Struct.new(:id, :client_info).new("sess-#{SecureRandom.hex(4)}", { "name" => "claude-code", "version" => "2.1" }) }

  before do
    require "reeve/action_mcp"

    Ledger.prepare!
    Invoice.delete_all
    Invoice.create!(number: "A-0", owner_id: alice.id)
    Invoice.create!(number: "A-1", owner_id: alice.id)
    Invoice.create!(number: "B-0", owner_id: bob.id)

    Reeve.configure do |c|
      c.audit_recorder = Reeve::Audit::Recorder
      c.principal_resolver = ->(_context) { ActionMCP::Current.user }
    end
    ActionMCP::Current.user = alice

    stub_const("InvoiceListTool", Class.new(ActionMCP::Tool) do
      tool_name "invoice_list"
      property :prefix, type: "string"
      guard_with InvoicePolicy

      def perform
        scoped(Invoice).where("number LIKE ?", "#{prefix}%").order(:number).each do |invoice|
          render(text: invoice.number)
        end
      end
    end)
  end

  after { ActionMCP::Current.reset }

  def tool_class(name, &perform)
    klass = Class.new(ActionMCP::Tool)
    klass.tool_name(name)
    klass.guard_with(InvoicePolicy)
    klass.define_method(:perform, &perform)
    klass.send(:protected, :perform)
    klass
  end

  # As ActionMCP's server runs a tool for a `tools/call` over HTTP.
  def call_tool(klass, arguments = {}, user: alice)
    ActionMCP::Current.user = user
    tool = klass.from_wire(arguments)
    tool.with_context({ session: session, request: { params: { name: klass.tool_name, arguments: arguments } } })
    tool.call.to_h
  end

  def texts(response)
    response[:content].map { |block| block[:text] }
  end

  def entries
    Reeve::Audit::Entry.order(:id).to_a
  end

  describe "the DSL" do
    it "is on every ActionMCP::Tool subclass, under the name ActionMCP publishes" do
      expect(InvoiceListTool.reeve_guard.policy).to eq(InvoicePolicy)
      expect(Reeve.registry.guard_for("invoice_list")).not_to be_nil
    end
  end

  # Story 2.
  describe "calling a tool as the server does" do
    it "returns what the tool rendered from scoped(...) and records one allow for the user" do
      expect(texts(call_tool(InvoiceListTool))).to eq(%w[A-0 A-1])
      expect(texts(call_tool(InvoiceListTool, user: bob))).to eq(["B-0"])

      expect(entries.map { |e| [e.tool_name, e.outcome, e.principal_id, e.rule] })
        .to eq([%w[invoice_list allow 1 InvoicePolicy#index],
                %w[invoice_list allow 2 InvoicePolicy#index]])
    end

    it "releases nothing it rendered when the output was not scoped (FR-031)" do
      tool = tool_class("unscoped") { Invoice.find_each { |invoice| render(text: invoice.number) } }

      response = call_tool(tool)

      expect(response[:isError]).to be(true)
      expect(texts(response).join).to include("unscoped_derived_result")
      expect(texts(response).join).not_to match(/[AB]-\d/)
      expect(entries.map { |e| [e.outcome, e.rule] }).to eq([%w[deny unscoped_derived_result]])
    end

    it "records a raising tool as tool_error before ActionMCP's own message, unchanged" do
      tool = tool_class("broken") do
        render(text: "partial")
        raise "boom"
      end

      response = call_tool(tool)

      expect(response[:isError]).to be(true)
      expect(texts(response)).to eq(["An unexpected error occurred."])
      expect(entries.map(&:rule)).to eq(["tool_error"])
    end

    it "shows an authorize! denial as the rule, not ActionMCP's generic error" do
      tool = tool_class("chase") do
        render(text: "before the check")
        authorize!(Invoice.find_by(number: "B-0"))
      end

      response = call_tool(tool)

      expect(texts(response)).to eq([texts(response).first])
      expect(texts(response).first).to include("InvoicePolicy#index")
      expect(texts(response).first).not_to include("B-0", "before the check")
      expect(entries.map(&:outcome)).to eq(["deny"])
    end

    it "denies no_principal, and records it, when no user is set" do
      ran = false
      tool = tool_class("watched") { ran = true }

      response = call_tool(tool, user: nil)

      expect(texts(response).join).to include("no_principal")
      expect(ran).to be(false)
      expect(entries.map(&:rule)).to eq(["no_principal"])
    end

    # A background task runs in ToolExecutionJob, which sets the session on the tool but
    # not ActionMCP::Current.user (FR-033).
    it "denies a background-task call no_principal unless the resolver finds the user" do
      tool = InvoiceListTool.from_wire({})
      tool.with_context({ session: session, request: { params: { name: "invoice_list" } } })
      ActionMCP::Current.reset

      expect(texts(tool.call.to_h).join).to include("no_principal")
      expect(entries.map(&:rule)).to eq(["no_principal"])
    end
  end

  describe "the edges of a call" do
    it "records request_input! as tool_error and leaks nothing rendered before it" do
      tool = tool_class("asks") do
        render(text: scoped(Invoice).pluck(:number).join(","))
        request_input!(prompt: "Which one?")
      end

      response = call_tool(tool)

      expect(texts(response).join).not_to match(/A-\d/)
      expect(entries.map(&:rule)).to eq(["tool_error"])
    end

    it "writes no row when a before_perform callback halts the call" do
      tool = tool_class("halted") { render(text: "never") }
      tool.before_perform { throw :abort }

      call_tool(tool)

      expect(entries).to be_empty
    end

    it "keeps an error the tool reported on itself, with its content" do
      tool = tool_class("self_reported") do
        scoped(Invoice)
        report_error("nothing matched")
      end

      response = call_tool(tool)

      expect([response[:isError], texts(response)]).to eq([true, ["nothing matched"]])
    end

    it "keeps structured content" do
      tool = tool_class("structured") do
        render(structured: { count: scoped(Invoice).count })
      end

      expect(call_tool(tool)[:structuredContent]).to eq(count: 2)
    end

    it "records the tool's attributes as arguments, with redact applied" do
      tool = tool_class("search") { scoped(Invoice) && render(text: prefix.to_s) }
      tool.property :prefix, type: "string"
      tool.property :customer_ssn, type: "string"
      tool.redact :customer_ssn

      call_tool(tool, { "prefix" => "A", "customer_ssn" => "123-45-6789" })

      expect(entries.last.arguments).to include("prefix" => "A")
      expect(entries.last.arguments.to_s).not_to include("123-45-6789")
    end

    it "attributes the call to the client, and records neither session nor its id (SC-002)" do
      seen = nil
      Reeve.configure do |c|
        c.principal_resolver = lambda { |context|
          seen = context.request[:session]
          ActionMCP::Current.user
        }
      end

      call_tool(InvoiceListTool)

      expect(seen).to eq(session)
      expect([entries.last.agent_id, entries.last.agent_name]).to eq(["claude-code", "claude-code 2.1"])
      expect(entries.last.attributes.to_s).not_to include(session.id)
    end
  end

  describe "installing" do
    it "keeps an abstract! base out of the compliance suite" do
      stub_const("ApplicationMCPTool", Class.new(ActionMCP::Tool) { abstract! })

      expect(Reeve.registry.abstract?(ApplicationMCPTool)).to be(true)
      expect(Reeve.registry.unguarded_tool_classes).not_to include(ApplicationMCPTool)
    end

    it "records a call once after a second install (FR-004)" do
      Reeve::Integrations::ActionMcp.install!

      call_tool(InvoiceListTool)

      expect(entries.size).to eq(1)
    end
  end
end

# Each in its own process, because in this one the adapter is already loaded.
RSpec.describe "loading reeve/action_mcp", if: action_mcp_available do
  def run(script, *flags, env: {})
    lib = File.expand_path("../../../lib", __dir__)
    IO.popen([env, RbConfig.ruby, *flags, "-I", lib, "-e", script, { err: %i[child out] }], &:read)
  end

  it "guards a tool that was defined before the adapter loaded" do
    output = run(<<~RUBY)
      require "action_mcp"
      class EarlyTool < ActionMCP::Tool
        def perform = render(text: "leaked")
      end
      require "reeve/action_mcp"
      rows = []
      recorder = Object.new
      recorder.define_singleton_method(:record) { |row| rows << row }
      Reeve.configure { |c| c.audit_recorder = recorder }
      response = EarlyTool.new.call.to_h
      puts [response[:isError], response[:content].map { |c| c[:text] }.join[/no_principal|leaked/], rows.size].inspect
    RUBY

    expect(output.strip.lines.last).to eq('[true, "no_principal", 1]')
  end

  it "refuses an ActionMCP version outside the verified range, naming it" do
    output = run(<<~RUBY)
      require "action_mcp"
      ActionMCP.send(:remove_const, :VERSION)
      ActionMCP::VERSION = "0.204.0"
      begin
        require "reeve/action_mcp"
      rescue Reeve::ConfigurationError => e
        puts e.message
      end
    RUBY

    expect(output).to include("reeve/action_mcp supports actionmcp", "< 0.204",
                              "actionmcp 0.204.0 is loaded")
  end

  it "names the missing gem and points to Reeve.invoke when actionmcp is absent" do
    script = <<~RUBY
      begin
        require "reeve/action_mcp"
      rescue Reeve::ConfigurationError => e
        puts e.message
      end
    RUBY
    output = run(script, "--disable-gems", env: { "RUBYOPT" => nil })

    expect(output).to include("needs the actionmcp gem", "Reeve.invoke")
  end
end
