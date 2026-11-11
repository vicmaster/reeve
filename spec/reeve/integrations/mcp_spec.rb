# frozen_string_literal: true

require "json"
require "support/optional/mcp_sdk"
require "support/optional/authorization_records"
require "reeve/audit"
require "reeve/audit/support/ledger"

mcp_available = begin
  require "mcp"
  true
rescue LoadError
  false
end

# The official SDK drives every example here the way a client does: a JSON-RPC
# `tools/call` through MCP::Server#handle_json.
RSpec.describe "the official MCP SDK adapter", if: mcp_available do
  let(:alice) { Owner.new(1) }
  let(:bob)   { Owner.new(2) }

  before do
    require "reeve/mcp"

    Ledger.prepare!
    Invoice.delete_all
    Invoice.create!(number: "A-0", owner_id: alice.id)
    Invoice.create!(number: "A-1", owner_id: alice.id)
    Invoice.create!(number: "B-0", owner_id: bob.id)

    Reeve.configure do |c|
      c.audit_recorder = Reeve::Audit::Recorder
      c.principal_resolver = ->(context) { context.request[:server_context]&.dig(:user) }
    end

    stub_const("InvoiceListTool", Class.new(MCP::Tool) do
      tool_name "invoice_list"
      guard_with InvoicePolicy

      def self.call
        numbers = scoped(Invoice).order(:number).pluck(:number)
        MCP::Tool::Response.new([{ type: "text", text: numbers.join(",") }])
      end
    end)
  end

  def server(user: alice, tools: [InvoiceListTool])
    MCP::Server.new(name: "app", tools: tools, server_context: { user: user })
  end

  def call_tool(name, arguments = {}, on: server)
    request = { jsonrpc: "2.0", id: 1, method: "tools/call",
                params: { name: name, arguments: arguments } }
    JSON.parse(on.handle_json(request.to_json), symbolize_names: true)
  end

  def text_of(response)
    response.dig(:result, :content).map { |block| block[:text] }.join
  end

  def entries
    Reeve::Audit::Entry.order(:id).to_a
  end

  def guarded_tool(name, &body)
    klass = Class.new(MCP::Tool)
    klass.tool_name(name)
    klass.guard_with(InvoicePolicy)
    klass.define_singleton_method(:call, &body)
    klass
  end

  describe "the DSL" do
    it "is on every MCP::Tool subclass without including anything" do
      expect(InvoiceListTool.reeve_guard.policy).to eq(InvoicePolicy)
      expect(InvoiceListTool).to respond_to(:scoped, :authorize!)
    end

    it "registers the tool under the name the SDK publishes (FR-011)" do
      expect(Reeve.registry.guard_for("invoice_list")).not_to be_nil
    end
  end

  # Story 1.
  describe "calling a tool through the server" do
    it "returns what the principal's scope allowed and records one allow" do
      expect(text_of(call_tool("invoice_list"))).to eq("A-0,A-1")
      expect(text_of(call_tool("invoice_list", on: server(user: bob)))).to eq("B-0")

      expect(entries.map { |e| [e.tool_name, e.outcome, e.principal_id, e.rule] })
        .to eq([%w[invoice_list allow 1 InvoicePolicy#index],
                %w[invoice_list allow 2 InvoicePolicy#index]])
    end

    it "refuses output built without scoped(...), with no invoice data" do
      stub_const("UnscopedTool", guarded_tool("unscoped") do
        MCP::Tool::Response.new([{ type: "text", text: Invoice.pluck(:number).join(",") }])
      end)

      response = call_tool("unscoped", on: server(tools: [UnscopedTool]))

      expect(response.dig(:result, :isError)).to be(true)
      expect(text_of(response)).to include("unscoped_derived_result")
      expect(text_of(response)).not_to match(/[AB]-\d/)
      expect(entries.map { |e| [e.outcome, e.rule] }).to eq([%w[deny unscoped_derived_result]])
    end

    it "refuses a record authorize! rejects, names the rule only, and rolls back writes" do
      stub_const("ChaseTool", guarded_tool("chase") do |number:|
        invoice = Invoice.find_by(number: number)
        invoice.update!(overdue: true)
        authorize!(invoice)
        MCP::Tool::Response.new([{ type: "text", text: "chased" }])
      end)

      response = call_tool("chase", { number: "B-0" }, on: server(tools: [ChaseTool]))

      expect(response.dig(:result, :isError)).to be(true)
      expect(text_of(response)).to include("InvoicePolicy#index")
      expect(text_of(response)).not_to include("B-0")
      expect(Invoice.find_by(number: "B-0").overdue).to be(false)
      expect(entries.map(&:outcome)).to eq(["deny"])
    end

    it "refuses with no_principal before the body runs" do
      ran = false
      stub_const("WatchedTool", guarded_tool("watched") do
        ran = true
        MCP::Tool::Response.new([])
      end)

      response = call_tool("watched", on: server(user: nil, tools: [WatchedTool]))

      expect(text_of(response)).to include("no_principal")
      expect(ran).to be(false)
      expect(entries.map(&:rule)).to eq(["no_principal"])
    end

    it "records a raising tool as tool_error and leaves the SDK's error as it was" do
      stub_const("BrokenTool", guarded_tool("broken") { raise "boom" })

      response = call_tool("broken", on: server(tools: [BrokenTool]))

      # The SDK's own internal error; whether it carries the message is the SDK's choice
      # (1.0.0 does, later versions do not).
      expect(response[:error]).to include(code: -32_603)
      expect(response[:error][:data]).to start_with("Internal error calling tool broken")
      expect(entries.map(&:rule)).to eq(["tool_error"])
    end
  end

  # FR-020: a tool receives exactly what the SDK gives it without reeve. The SDK passes
  # `server_context:` to a `call` that names it or takes `**`, and to no other.
  describe "what a tool receives" do
    let(:received) { [] }

    def recording_tool(name, sink, &signature)
      klass = guarded_tool(name, &signature)
      klass.define_singleton_method(:sink) { sink }
      klass
    end

    it "gives server_context to a tool that declares it" do
      sink = received
      tool = guarded_tool("with_context") do |query:, server_context:|
        sink << [query, server_context.class]
        scoped(Invoice)
        MCP::Tool::Response.new([])
      end

      call_tool("with_context", { query: "q" }, on: server(tools: [tool]))

      expect(received).to eq([["q", MCP::ServerContext]])
    end

    it "gives nothing extra to a tool that does not" do
      sink = received
      tool = guarded_tool("without_context") do |*args, query:|
        sink << [args, query]
        scoped(Invoice)
        MCP::Tool::Response.new([])
      end

      call_tool("without_context", { query: "q" }, on: server(tools: [tool]))

      expect(received).to eq([[[], "q"]])
    end

    it "gives a **rest tool its arguments and the server context" do
      sink = received
      tool = guarded_tool("rest") do |**rest|
        sink << rest.keys.sort
        scoped(Invoice)
        MCP::Tool::Response.new([])
      end

      call_tool("rest", { query: "q" }, on: server(tools: [tool]))

      expect(received).to eq([%i[query server_context]])
    end

    it "records the arguments without the server context" do
      tool = guarded_tool("args") do |query:, server_context:|
        scoped(Invoice)
        MCP::Tool::Response.new([{ type: "text", text: "#{query} #{server_context.class}" }])
      end

      call_tool("args", { query: "q" }, on: server(tools: [tool]))

      expect(entries.last.arguments).to eq("query" => "q")
    end
  end

  describe "the context it builds" do
    let(:secret) { "tok-#{SecureRandom.hex(4)}" }

    # Stands in for MCP::ServerContext: the two readers the adapter uses, and `dig` on the
    # host's own hash for the resolver.
    let(:server_context) do
      user = alice
      token = { subject: "1", token: secret }
      Class.new do
        define_method(:client_info) { { "name" => "claude-code", "version" => "2.1" } }
        define_method(:auth_info) { token }
        define_method(:dig) { |*keys| { user: user, api_key: token[:token] }.dig(*keys) }
        define_method(:[]) { |key| dig(key) }
      end.new
    end

    it "attributes the call to the client's own name and version" do
      InvoiceListTool.call(server_context: server_context)

      expect([entries.last.agent_id, entries.last.agent_name]).to eq(["claude-code", "claude-code 2.1"])
      expect(entries.last.metadata).to eq("client" => { "name" => "claude-code", "version" => "2.1" })
    end

    it "records an unknown agent rather than refusing" do
      call_tool("invoice_list")

      expect(entries.last.agent_id).to eq("unknown")
    end

    it "hands the server context and token to the resolver and records neither (SC-002)" do
      seen = nil
      Reeve.configure do |c|
        c.principal_resolver = lambda { |context|
          seen = context.request[:auth_info]
          context.request[:server_context][:user]
        }
      end

      InvoiceListTool.call(server_context: server_context)

      expect(seen).to include(token: secret)
      expect(entries.last.attributes.to_s).not_to include(secret)
    end
  end

  describe "installing" do
    it "guards a tool whether it is defined before or after a second install, once (FR-004)" do
      Reeve::Integrations::Mcp.install!
      later = guarded_tool("later") do
        scoped(Invoice)
        MCP::Tool::Response.new([])
      end
      Reeve::Integrations::Mcp.install!

      call_tool("invoice_list")
      call_tool("later", on: server(tools: [later]))

      expect(entries.map(&:tool_name)).to eq(%w[invoice_list later])
    end

    it "guards a subclass of a guarded tool that defines its own call, once" do
      stub_const("NarrowListTool", Class.new(InvoiceListTool) do
        tool_name "narrow_list"

        def self.call
          scoped(Invoice)
          super
        end
      end)

      expect(text_of(call_tool("narrow_list", on: server(tools: [NarrowListTool]))))
        .to eq("A-0,A-1")
      expect(entries.size).to eq(1)
    end
  end

  # Story 4. The SDK builds a class for every block, so block tools go through reeve like
  # class tools: refused until guarded, guarded on the class the server holds.
  describe "block-registered tools" do
    def list_block(server)
      server.define_tool(name: "list_block") do |server_context:|
        server_context.class # the block takes it, as SDK block tools usually do
        MCP::Tool::Response.new([{ type: "text", text: scoped(Invoice).pluck(:number).join(",") }])
      end
    end

    it "refuses an unguarded block tool with no_guard_declared, without running it" do
      app = server(tools: [])
      app.define_tool(name: "raw_block") { |**| raise "must not run" }

      response = call_tool("raw_block", on: app)

      expect(text_of(response)).to include("no_guard_declared")
      expect(entries.map { |e| [e.tool_name, e.rule] }).to eq([%w[raw_block no_guard_declared]])
    end

    it "allows it once guarded on the server's tool for that name" do
      app = server(tools: [])
      list_block(app)
      app.tools["list_block"].guard_with InvoicePolicy

      expect(text_of(call_tool("list_block", on: app))).to eq("A-0,A-1")
      expect(entries.map(&:outcome)).to eq(["allow"])
    end

    it "treats MCP::Tool.define the same" do
      tool = MCP::Tool.define(name: "defined_block") { |**| MCP::Tool::Response.new([]) }

      expect(text_of(call_tool("defined_block", on: server(tools: [tool]))))
        .to include("no_guard_declared")
    end

    it "runs an unguarded block tool with a warning under :allow_with_warning" do
      Reeve.configure do |c|
        c.unguarded_tools = :allow_with_warning
        c.logger = CapturingLogger.new
      end
      app = server(tools: [])
      app.define_tool(name: "open_block") { |**| MCP::Tool::Response.new([{ type: "text", text: "ok" }]) }

      expect(text_of(call_tool("open_block", on: app))).to eq("ok")
      expect(entries.map(&:rule)).to eq(["unguarded_tool"])
    end
  end
end

# Each in its own process, because in this one the adapter is already loaded.
RSpec.describe "loading reeve/mcp", if: mcp_available do
  def run(script, *flags, env: {})
    lib = File.expand_path("../../../lib", __dir__)
    IO.popen([env, RbConfig.ruby, *flags, "-I", lib, "-e", script, { err: %i[child out] }], &:read)
  end

  it "guards a tool that was defined before the adapter loaded" do
    output = run(<<~RUBY)
      require "mcp"
      class EarlyTool < MCP::Tool
        def self.call = MCP::Tool::Response.new([{ type: "text", text: "leaked" }])
      end
      require "reeve/mcp"
      rows = []
      recorder = Object.new
      recorder.define_singleton_method(:record) { |row| rows << row }
      Reeve.configure { |c| c.audit_recorder = recorder }
      response = EarlyTool.call
      puts [response.to_h[:isError], response.to_h[:content].first[:text][/no_principal/], rows.size].inspect
    RUBY

    expect(output.strip).to eq('[true, "no_principal", 1]')
  end

  it "refuses an SDK version outside the verified range, naming it" do
    output = run(<<~RUBY)
      require "mcp"
      MCP.send(:remove_const, :VERSION)
      MCP::VERSION = "2.0.0"
      begin
        require "reeve/mcp"
      rescue Reeve::ConfigurationError => e
        puts e.message
      end
    RUBY

    expect(output).to include("reeve/mcp supports mcp", "< 2.0", "mcp 2.0.0 is loaded")
  end

  it "names the missing gem and points to Reeve.invoke when mcp is absent" do
    script = <<~RUBY
      begin
        require "reeve/mcp"
      rescue Reeve::ConfigurationError => e
        puts e.message
      end
    RUBY
    # Bundler would put mcp on the load path through RUBYOPT; this process has no gems.
    output = run(script, "--disable-gems", env: { "RUBYOPT" => nil })

    expect(output).to include("needs the mcp gem", "Reeve.invoke")
  end

  it "explains the clash when fast-mcp loaded first and hid the SDK's classes" do
    unless Gem.loaded_specs.key?("fast-mcp")
      skip "fast-mcp needs Ruby 3.1+ and is not installed here"
    end

    output = run(<<~RUBY)
      require "fast_mcp"
      begin
        require "reeve/mcp"
      rescue Reeve::ConfigurationError => e
        puts e.message
      end
    RUBY

    expect(output).to include("fast-mcp", "one MCP server library per process")
  end

  it "wraps no other library's tools" do
    output = run(<<~RUBY)
      require "reeve/mcp"
      plain = Class.new { include Reeve::Guard; def self.call = :untouched }
      puts plain.call
    RUBY

    expect(output.strip).to eq("untouched")
  end
end
