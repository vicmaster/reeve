# frozen_string_literal: true

require_relative "support/envelope"

# T035 / FR-013, SC-003. The ledger only pays for itself if the question after an incident
# — "which agent, acting for whom, touched what, and when?" — is one query rather than an
# afternoon in the log aggregator. One scope per query axis, and they compose.
RSpec.describe Reeve::Audit::Query do
  include Envelope

  before { Ledger.prepare! }

  let(:alice) { Envelope::Principal.new(1) }
  let(:bob)   { Envelope::Principal.new(2) }

  def record(principal: alice, agent: "claude-desktop", tool: "InvoiceSearchTool",
             outcome: :allow, at: Time.now)
    decision = if outcome == :allow
                 Reeve::Decision.allow(rule: "InvoicePolicy#index?")
               else
                 Reeve::Decision.deny(rule: "InvoicePolicy#index?")
               end

    invoke(principal: principal, agent: { id: agent }, tool_name: tool,
           decision: decision, invoked_at: at) { [] }
  rescue Reeve::DeniedError
    nil
  end

  describe "one scope per axis" do
    it "finds the calls made for a principal" do
      record(principal: alice)
      record(principal: bob)

      expect(described_class.for_principal(alice).count).to eq(1)
      expect(described_class.for_principal(alice).first.principal_id).to eq("1")
    end

    it "finds a principal by type and id, for when only the identifiers survive" do
      record(principal: alice)

      found = described_class.for_principal(type: "Envelope::Principal", id: 1)

      expect(found.count).to eq(1)
    end

    it "does not match a different type that happens to share an id" do
      record(principal: alice)

      expect(described_class.for_principal(type: "Other", id: 1).count).to eq(0)
    end

    it "finds the calls made by an agent" do
      record(agent: "claude-desktop")
      record(agent: "some-other-client")

      expect(described_class.for_agent("claude-desktop").count).to eq(1)
    end

    it "finds the calls made against a tool" do
      record(tool: "InvoiceSearchTool")
      record(tool: "CustomerSearchTool")

      expect(described_class.for_tool("InvoiceSearchTool").count).to eq(1)
    end

    it "separates denials from allowed calls" do
      record(outcome: :allow)
      record(outcome: :deny)

      expect(described_class.denied.count).to eq(1)
      expect(described_class.allowed.count).to eq(1)
      expect(described_class.denied.first).to be_denied
    end

    it "finds the calls made in a time range, by invocation time" do
      record(at: Time.now - (8 * 86_400))
      record(at: Time.now - 3600)

      expect(described_class.between(Time.now - 86_400, Time.now).count).to eq(1)
    end

    it "excludes calls outside the range at both ends" do
      record(at: Time.now - 7200)

      expect(described_class.between(Time.now - 3600, Time.now).count).to eq(0)
      expect(described_class.between(Time.now - 10_800, Time.now - 9000).count).to eq(0)
    end
  end

  describe "composition (SC-003)" do
    it "answers the incident question in a single chain" do
      record(principal: alice, agent: "claude-desktop", at: Time.now - 3600)
      record(principal: bob, agent: "claude-desktop", at: Time.now - 3600)
      record(principal: alice, agent: "some-other-client", at: Time.now - 3600)
      record(principal: alice, agent: "claude-desktop", at: Time.now - (30 * 86_400))

      rows = described_class
             .for_principal(alice)
             .for_agent("claude-desktop")
             .between(Time.now - 86_400, Time.now)
             .pluck(:tool_name, :record_type, :record_ids, :outcome, :rule)

      expect(rows.size).to eq(1)
      expect(rows.first.first).to eq("InvoiceSearchTool")
    end

    it "composes an outcome axis onto a principal axis" do
      record(principal: alice, outcome: :deny)
      record(principal: alice, outcome: :allow)
      record(principal: bob, outcome: :deny)

      expect(described_class.for_principal(alice).denied.count).to eq(1)
      expect(described_class.denied.for_principal(alice).count).to eq(1)
    end

    it "starts from the whole ledger" do
      record
      record

      expect(described_class.all.count).to eq(2)
    end
  end

  describe "the same scopes on the model" do
    it "chains from the entry class, so a host is not forced through the facade" do
      record(principal: alice)
      record(principal: bob)

      expect(Reeve::Audit::Entry.for_principal(alice).count).to eq(1)
    end
  end
end
