# frozen_string_literal: true

require "support/optional/authorization_records"
require "reeve/audit"
require "reeve/audit/support/ledger"
require "reeve/testing"

# Reeve::Inventory: the host's registered tool names, checked against what routes through
# reeve.
#
# The hazard is not a policy that denies wrongly. It is a real tool that never enters the
# envelope, so deny-by-default, scoping, rollback and the ledger are all skipped together
# and nothing says so. Everything below is written against a dispatcher that registers
# names and blocks — the shape that defeats the guard registry, because a block has no
# class for `include Reeve::Guard` to record.
RSpec.describe Reeve::Inventory do
  let(:alice) { Owner.new(1) }
  let(:bob)   { Owner.new(2) }

  # The host's own server: names and handler blocks, no MCP library anywhere.
  let(:server) do
    Class.new do
      attr_reader :handlers

      def initialize
        @handlers = {}
      end

      def tool(name, &handler)
        @handlers[name] = handler
      end

      def tool_names = handlers.keys
    end.new
  end

  before do
    Ledger.prepare!
    Invoice.delete_all
    Invoice.create!(number: "A-1", owner_id: alice.id)
    Invoice.create!(number: "B-1", owner_id: bob.id)
    Reeve.config.audit_recorder = Reeve::Audit::Recorder

    stub_const("InvoiceSearchTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy
      def call = Invoice.all
    end)

    stub_const("LegacyStatsTool", Class.new { def call = Invoice.count })

    server.tool("search_invoices") { Invoice.all }
    server.tool("export_invoices") { Invoice.pluck(:number).join(",") }
    server.tool("healthcheck") { { ok: true } }
  end

  def inventory(**parts)
    described_class.new(registered: -> { server.tool_names }, **parts)
  end

  def entries
    Reeve::Audit::Entry.order(:id).to_a
  end

  # The dispatcher the README describes: every call goes through the inventory.
  def dispatch(inventory, name, principal: alice)
    inventory.dispatch(name, principal: principal) { server.handlers.fetch(name).call }
  end

  # ---- 1. three registered names, one binding --------------------------------------

  describe "classifying the registered names" do
    it "reports every registered name with no route as bypassing reeve" do
      report = inventory(routed: { "search_invoices" => InvoiceSearchTool }).report

      expect(report.guarded.map(&:name)).to eq(["search_invoices"])
      expect(report.bypassing.map(&:name)).to contain_exactly("export_invoices", "healthcheck")
      expect(report).not_to be_complete
    end

    it "tells a guarded route from one that reaches reeve with no guard" do
      report = inventory(
        routed: { "search_invoices" => InvoiceSearchTool, "export_invoices" => LegacyStatsTool },
        exemptions: { "healthcheck" => { reason: "returns no application data" } }
      ).report

      expect(report.guarded.map(&:name)).to eq(["search_invoices"])
      expect(report.unguarded.map(&:name)).to eq(["export_invoices"])
      expect(report).not_to be_complete
    end

    it "is complete when every name is guarded or exempt" do
      report = inventory(
        routed: { "search_invoices" => InvoiceSearchTool, "export_invoices" => InvoiceSearchTool },
        exemptions: { "healthcheck" => { reason: "returns no application data" } }
      ).report

      expect(report).to be_complete
    end

    # A route for a name the server does not register is almost always a rename, and the
    # real name is then the one bypassing. Treating it as noise would hide exactly that.
    it "is incomplete when the inventory names a tool the server does not register" do
      report = inventory(
        routed: { "search_invoices" => InvoiceSearchTool, "export_invoice" => InvoiceSearchTool },
        exemptions: { "healthcheck" => { reason: "returns no application data" } }
      ).report

      expect(report.unregistered_entries.map(&:name)).to eq(["export_invoice"])
      expect(report.bypassing.map(&:name)).to eq(["export_invoices"])
      expect(report.to_s).to include("NOT REGISTERED export_invoice")
    end

    it "is incomplete on a stale entry alone, with every registered name covered" do
      report = inventory(
        routed: { "search_invoices" => InvoiceSearchTool, "export_invoices" => InvoiceSearchTool },
        exemptions: { "healthcheck" => { reason: "no data" }, "retired_tool" => { reason: "gone" } }
      ).report

      expect(report.bypassing).to be_empty
      expect(report).not_to be_complete
      expect(report.to_s).to include("1 declared but not registered", "NOT REGISTERED retired_tool")
    end

    it "reads the server's list when asked, not when declared" do
      routes = inventory(routed: { "search_invoices" => InvoiceSearchTool })
      server.tool("late_tool") { nil }

      expect(routes.report.bypassing.map(&:name)).to include("late_tool")
    end

    it "prints the summary the issue asked for, then one actionable block per gap" do
      report = inventory(
        routed: { "search_invoices" => InvoiceSearchTool, "export_invoices" => LegacyStatsTool }
      ).report

      expect(report.to_s).to start_with(<<~TEXT.chomp)
        reeve inventory: 3 registered
          1 protected and guarded
          1 routed through reeve but unguarded
          1 bypasses reeve
          0 exempted
        coverage: incomplete
      TEXT
      expect(report.to_s).to include("UNGUARDED export_invoices\n  routed to LegacyStatsTool")
      expect(report.to_s).to include("BYPASS healthcheck\n  registered with the server")
    end
  end

  # ---- 2. strict: boot, CI, and dispatch -------------------------------------------

  describe "#verify!" do
    it "raises with the whole report when a registered tool is unbound" do
      subject = inventory(routed: { "search_invoices" => InvoiceSearchTool })

      expect { subject.verify! }.to raise_error(Reeve::IncompleteInventoryError) { |error|
        expect(error.message).to include("BYPASS export_invoices", "BYPASS healthcheck")
        expect(error.report).not_to be_complete
      }
    end

    it "returns the report when coverage is complete" do
      subject = inventory(
        routed: { "search_invoices" => InvoiceSearchTool, "export_invoices" => InvoiceSearchTool },
        exemptions: { "healthcheck" => { reason: "returns no application data" } }
      )

      expect(subject.verify!).to be_complete
    end
  end

  describe "#dispatch" do
    let(:subject_inventory) do
      inventory(
        routed: { "search_invoices" => InvoiceSearchTool },
        exemptions: { "healthcheck" => { reason: "returns no application data" } }
      )
    end

    it "runs a routed tool through the envelope, with the handler block as its body" do
      records = dispatch(subject_inventory, "search_invoices")

      expect(records.map(&:number)).to eq(["A-1"])
      expect(entries.map(&:rule)).to eq(["InvoicePolicy#index"])
    end

    it "runs the routed class itself when no block is given" do
      records = subject_inventory.dispatch("search_invoices", principal: bob)

      expect(records.map(&:number)).to eq(["B-1"])
    end

    it "refuses an unbound tool before its handler runs, and records the refusal" do
      ran = false
      server.tool("export_invoices") { ran = true }

      expect { dispatch(subject_inventory, "export_invoices") }
        .to raise_error(Reeve::DeniedError) { |error|
          expect(error.rule).to eq(Reeve::Decision::UNBOUND_TOOL)
        }
      expect(ran).to be(false)
      expect(entries.map { |entry| [entry.tool_name, entry.outcome, entry.rule] })
        .to eq([%w[export_invoices deny unbound_tool]])
    end

    it "still asks who the caller is first, so an unidentified caller reads as one" do
      expect { dispatch(subject_inventory, "export_invoices", principal: nil) }
        .to raise_error(Reeve::DeniedError) { |error|
          expect(error.rule).to eq(Reeve::Decision::NO_PRINCIPAL)
        }
    end

    # The migration path: an unbound name runs, but through the envelope, so the ledger
    # is the worklist instead of the tool vanishing from it.
    it "runs an unbound tool unscoped and recorded under :allow_with_warning" do
      Reeve.config.unguarded_tools = :allow_with_warning
      Reeve.config.logger = CapturingLogger.new

      expect(dispatch(subject_inventory, "export_invoices")).to eq("A-1,B-1")
      expect(entries.map { |entry| [entry.tool_name, entry.guard, entry.rule] })
        .to eq([%w[export_invoices none unguarded_tool]])
    end

    it "runs an exempt tool as the host wrote it, outside the envelope" do
      expect(dispatch(subject_inventory, "healthcheck")).to eq(ok: true)
      expect(entries).to be_empty
    end

    it "needs a handler for any name it cannot run itself" do
      expect { subject_inventory.dispatch("healthcheck") }
        .to raise_error(ArgumentError, /handler block/)
    end
  end

  # ---- 3. exemptions --------------------------------------------------------------

  describe "an exemption" do
    ["", "   ", nil].each do |reason|
      it "is refused with a reason of #{reason.inspect}" do
        expect { inventory_with_literal_exemption(reason: reason) }
          .to raise_error(ArgumentError, /exemption for healthcheck needs a reason/)
      end
    end

    it "is refused as a bare value, with no reason at all" do
      expect { inventory_with_literal_exemption(true) }
        .to raise_error(ArgumentError, /needs a reason/)
    end

    it "is checked when the report reads it, if it was declared lazily" do
      lazy = inventory(exemptions: -> { { "healthcheck" => { reason: "" } } })

      expect { lazy.report }.to raise_error(ArgumentError, /needs a reason/)
    end

    it "stays visible in the report, with its reason, even when coverage is complete" do
      report = inventory(
        routed: { "search_invoices" => InvoiceSearchTool, "export_invoices" => InvoiceSearchTool },
        exemptions: { "healthcheck" => { reason: "returns no application data" } }
      ).report

      expect(report).to be_complete
      expect(report.to_s).to include("1 exempted", "EXEMPT healthcheck\n  returns no application data")
    end

    it "cannot also be a route" do
      expect do
        described_class.new(registered: %w[healthcheck],
                            routed: { "healthcheck" => InvoiceSearchTool },
                            exemptions: { "healthcheck" => { reason: "no data" } })
      end.to raise_error(ArgumentError, /not both: healthcheck/)
    end

    def inventory_with_literal_exemption(options)
      described_class.new(registered: %w[healthcheck],
                          exemptions: { "healthcheck" => options })
    end
  end

  describe "declaring one" do
    it "rejects a route to something that is not a tool class" do
      expect { described_class.new(registered: %w[a], routed: { "a" => -> {} }) }
        .to raise_error(ArgumentError, /routed must map each name to a tool class/)
    end

    it "rejects a blank tool name" do
      expect { described_class.new(registered: ["search", " "]) }
        .to raise_error(ArgumentError, /blank or non-string tool name/)
    end

    it "rejects a registered list that is not a list" do
      expect { described_class.new(registered: "search_invoices") }
        .to raise_error(ArgumentError, /registered must list tool names/)
    end

    it "is the only kind of object config.inventory accepts" do
      expect { Reeve.config.inventory = { "a" => InvoiceSearchTool } }
        .to raise_error(ArgumentError, /Reeve::Inventory/)
    end
  end

  # ---- 4. a subset cannot pass for the endpoint ------------------------------------

  describe "the compliance suite's EndpointCoverage" do
    def coverage(**options)
      Reeve::Checks::EndpointCoverage.new(**options).call
    end

    after { Reeve::Testing.reset! }

    it "skips, rather than passes, when no inventory is declared" do
      result = coverage

      expect(result).to be_skipped
      expect(result.message).to include("no endpoint inventory is declared")
    end

    it "fails an unnarrowed run when the endpoint has a tool that bypasses reeve" do
      Reeve.config.inventory = inventory(routed: { "search_invoices" => InvoiceSearchTool })

      result = coverage

      expect(result).to be_failed
      expect(result.message).to include("2 bypass it", "BYPASS export_invoices")
    end

    it "skips a narrowed run as a subset, and says what it left out" do
      Reeve.config.inventory = inventory(
        routed: { "search_invoices" => InvoiceSearchTool, "export_invoices" => LegacyStatsTool },
        exemptions: { "healthcheck" => { reason: "no data" } }
      )
      Reeve.config.compliance_tools = [InvoiceSearchTool]

      result = coverage

      expect(result).to be_skipped
      expect(result.message).to start_with("this run certifies a subset, not the endpoint: " \
                                           "1 of the 2 tools routed through reeve")
      expect(result.message).to include("not certified: LegacyStatsTool")
    end

    it "treats an explicit tools: list as narrowed too" do
      Reeve.config.inventory = inventory(
        routed: { "search_invoices" => InvoiceSearchTool, "export_invoices" => InvoiceSearchTool },
        exemptions: { "healthcheck" => { reason: "no data" } }
      )

      expect(coverage(tools: [InvoiceSearchTool])).to be_skipped
    end

    it "passes only for a complete inventory and a run that covered all of it" do
      Reeve.config.inventory = inventory(
        routed: { "search_invoices" => InvoiceSearchTool, "export_invoices" => InvoiceSearchTool },
        exemptions: { "healthcheck" => { reason: "no data" } }
      )

      result = coverage

      expect(result).to be_passed
      expect(result.message).to include("every one of the 3 tools the server registers")
    end

    it "fails, rather than raises, when the inventory cannot be read" do
      Reeve.config.inventory = inventory(routed: -> { raise NameError, "uninitialized Foo" })

      result = coverage

      expect(result).to be_failed
      expect(result.message).to include("could not be read", "uninitialized Foo")
    end

    # A routed class need not include Reeve::Guard at all — a registry of blocks often
    # has no reason to — so the per-tool checks would never see it unless the inventory
    # adds it to the population.
    it "puts every routed class in the population the per-tool checks walk" do
      Reeve.config.inventory = inventory(routed: { "export_invoices" => LegacyStatsTool })

      report = Reeve::Checks.run(Reeve::Checks::GuardDeclared, principals: [alice, bob])

      expect(report.failures.map(&:message).join).to include("LegacyStatsTool")
    end
  end

  # ---- 6. what the diagnostics may contain -----------------------------------------

  describe "diagnostic output" do
    it "names tools, classes and reasons — never arguments, principals or records" do
      secret_principal = Owner.new(424_242)
      record = Invoice.create!(id: 919_191, number: "SECRET-NUMBER", owner_id: 424_242)
      routes = inventory(routed: { "search_invoices" => InvoiceSearchTool })
      Reeve.config.inventory = routes

      routes.dispatch("search_invoices", principal: secret_principal,
                                         arguments: { token: "sk-live-credential" }) do
        Invoice.where(id: record.id)
      end

      output = [
        routes.report.to_s,
        verification_message(routes),
        Reeve::Checks::EndpointCoverage.new.call.message
      ].join("\n")

      expect(output).to include("BYPASS export_invoices")
      expect(output).not_to include("424242", "919191", "SECRET-NUMBER", "sk-live-credential")
    end

    def verification_message(inventory)
      inventory.verify!
      raise "expected an incomplete inventory"
    rescue Reeve::IncompleteInventoryError => e
      e.message
    end
  end
end
