# frozen_string_literal: true

require "support/optional/authorization_records"
require "reeve/audit"
require "reeve/audit/support/ledger"

fast_mcp_available = begin
  require "fast_mcp"
  true
rescue LoadError
  false
end

# fast-mcp depends on dry-schema, which requires Ruby 3.1+. A Ruby 3.0 application cannot
# run this adapter at all, so these specs skip there rather than pretending otherwise.
RSpec.describe "the fast-mcp adapter", if: fast_mcp_available do
  let(:alice) { Owner.new(1) }
  let(:bob)   { Owner.new(2) }

  before do
    require "reeve/fast_mcp"

    Ledger.prepare!
    Invoice.delete_all
    2.times { |i| Invoice.create!(number: "A-#{i}", owner_id: alice.id) }
    Invoice.create!(number: "B-0", owner_id: bob.id)

    Reeve.configure do |c|
      c.audit_recorder = Reeve::Audit::Recorder
      # The whole point of the adapter: the principal comes from the request the MCP
      # server received, which the tool sees as headers.
      c.principal_resolver = lambda { |context|
        id = context.metadata.dig(:headers, "X-Principal-Id")
        id.nil? ? nil : Owner.new(id.to_i)
      }
    end

    stub_const("InvoiceListTool", Class.new(FastMcp::Tool) do
      tool_name "invoice_list"
      description "Lists invoices"

      guard_with InvoicePolicy

      def call(**)
        Invoice.all
      end
    end)
  end

  def invoke(tool: InvoiceListTool, headers: { "X-Principal-Id" => "1" }, **arguments)
    tool.new(headers: headers).call(**arguments)
  end

  describe "the DSL" do
    it "is available on every FastMcp::Tool subclass without including anything" do
      expect(FastMcp::Tool).to respond_to(:guard_with)
      expect(InvoiceListTool.reeve_guard.policy).to eq(InvoicePolicy)
    end

    it "registers the tool under the name fast-mcp knows it by" do
      expect(Reeve.registry.guard_for("invoice_list")).not_to be_nil
    end
  end

  describe "invoking a tool the way the server does" do
    it "scopes the result to the principal the request identified" do
      expect(invoke.map(&:number)).to contain_exactly("A-0", "A-1")
    end

    it "gives a different principal only their own records" do
      expect(invoke(headers: { "X-Principal-Id" => "2" }).map(&:number)).to eq(["B-0"])
    end

    it "writes one ledger entry naming the principal and the rule" do
      invoke

      entry = Reeve::Audit::Entry.order(:id).last
      expect(Reeve::Audit::Entry.count).to eq(1)
      expect(entry.tool_name).to eq("invoice_list")
      expect(entry.principal_id).to eq("1")
      expect(entry.rule).to eq("InvoicePolicy#index")
    end

    it "denies when the request identifies nobody" do
      expect { invoke(headers: {}) }
        .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("no_principal") }
    end

    it "denies a tool that declared no guard" do
      stub_const("UnguardedMcpTool", Class.new(FastMcp::Tool) do
        tool_name "unguarded_mcp"
        description "Not declared"
        def call(**) = Invoice.all
      end)

      expect { invoke(tool: UnguardedMcpTool) }
        .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("no_guard_declared") }
    end

    it "passes the tool's arguments through untouched" do
      stub_const("EchoTool", Class.new(FastMcp::Tool) do
        tool_name "echo"
        description "Echoes"
        guard_with InvoicePolicy

        def call(query:)
          Invoice.where("number LIKE ?", "#{query}%")
        end
      end)

      expect(invoke(tool: EchoTool, query: "A").map(&:number)).to contain_exactly("A-0", "A-1")
      expect(Reeve::Audit::Entry.order(:id).last.arguments).to eq("query" => "A")
    end
  end

  describe "the context it builds" do
    it "carries the request headers through for the resolver, opaquely" do
      seen = nil
      Reeve.configure do |c|
        c.principal_resolver = lambda { |context|
          seen = context.metadata
          Owner.new(1)
        }
      end

      invoke(headers: { "X-Principal-Id" => "1", "User-Agent" => "claude-desktop/1.0" })

      expect(seen[:headers]).to include("User-Agent" => "claude-desktop/1.0")
    end

    it "attributes the call to the client the request named" do
      invoke(headers: { "X-Principal-Id" => "1", "User-Agent" => "claude-desktop/1.0" })

      expect(Reeve::Audit::Entry.order(:id).last.agent_id).to eq("claude-desktop/1.0")
    end

    # Attribution is not authorization: an unidentifiable client is recorded, not refused.
    it "records an unknown agent rather than denying" do
      invoke(headers: { "X-Principal-Id" => "1" })

      expect(Reeve::Audit::Entry.order(:id).last.agent_id).to eq("unknown")
    end
  end
end

RSpec.describe "the core without the fast-mcp adapter" do
  # FR-022/FR-024: the adapter is opt-in, and its absence changes nothing.
  it "never loads fast-mcp from the core require" do
    script = <<~RUBY
      require "reeve"
      abort "fast-mcp was loaded" if Object.const_defined?(:FastMcp)
      puts "clean"
    RUBY
    output = IO.popen([RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__),
                       "-e", script, { err: %i[child out] }], &:read)

    expect(output.strip).to eq("clean")
  end
end
