# frozen_string_literal: true

RSpec.describe Reeve::Context do
  let(:principal) { double("User", id: 42) }

  describe "construction" do
    it "requires a tool name" do
      expect { described_class.new(tool_name: nil) }.to raise_error(ArgumentError, /tool_name/)
      expect { described_class.new(tool_name: "  ") }.to raise_error(ArgumentError, /tool_name/)
    end

    it "coerces the tool name to a string" do
      expect(described_class.new(tool_name: :invoice_search).tool_name).to eq("invoice_search")
    end

    it "defaults arguments to an empty hash" do
      expect(described_class.new(tool_name: "t").arguments).to eq({})
    end

    it "defaults metadata to an empty hash" do
      expect(described_class.new(tool_name: "t").metadata).to eq({})
    end

    it "stamps invoked_at at construction" do
      context = described_class.new(tool_name: "t")

      expect(context.invoked_at).to be_a(Time)
      expect(context.invoked_at).to be <= Time.now
    end

    it "accepts an explicit invoked_at from an adapter that timed entry itself" do
      moment = Time.now - 60
      expect(described_class.new(tool_name: "t", invoked_at: moment).invoked_at).to eq(moment)
    end

    it "assigns a unique invocation id" do
      one = described_class.new(tool_name: "t")
      two = described_class.new(tool_name: "t")

      expect(one.invocation_id).to be_a(String)
      expect(one.invocation_id).not_to eq(two.invocation_id)
    end

    it "keeps an invocation id supplied by the caller" do
      expect(described_class.new(tool_name: "t", invocation_id: "abc").invocation_id).to eq("abc")
    end
  end

  describe "the agent" do
    # Attribution is not authorization: an unidentifiable agent is recorded, not rejected.
    it "defaults to an unknown agent" do
      expect(described_class.new(tool_name: "t").agent).to eq({ id: "unknown" })
    end

    it "fills in an unknown id when the adapter supplied only a name" do
      context = described_class.new(tool_name: "t", agent: { name: "Claude" })

      expect(context.agent[:id]).to eq("unknown")
      expect(context.agent[:name]).to eq("Claude")
    end

    it "symbolises agent keys so adapters may pass string keys" do
      context = described_class.new(tool_name: "t", agent: { "id" => "a1", "version" => "2" })

      expect(context.agent[:id]).to eq("a1")
      expect(context.agent[:version]).to eq("2")
    end

    it "exposes agent_id and agent_name for the ledger" do
      context = described_class.new(tool_name: "t", agent: { id: "a1", name: "Claude" })

      expect(context.agent_id).to eq("a1")
      expect(context.agent_name).to eq("Claude")
    end

    it "reports an unknown agent_id rather than nil when unidentifiable" do
      expect(described_class.new(tool_name: "t").agent_id).to eq("unknown")
      expect(described_class.new(tool_name: "t").agent_name).to be_nil
    end
  end

  describe "the principal" do
    # A nil principal is legal at construction; the envelope is what denies it.
    it "is nil until resolved" do
      context = described_class.new(tool_name: "t")

      expect(context.principal).to be_nil
      expect(context).not_to be_principal_resolved
    end

    it "may be supplied at construction" do
      context = described_class.new(tool_name: "t", principal: principal)

      expect(context.principal).to eq(principal)
      expect(context).to be_principal_resolved
    end

    it "is assignable once by the envelope" do
      context = described_class.new(tool_name: "t")
      context.principal = principal

      expect(context.principal).to eq(principal)
    end

    it "exposes principal_type and principal_id for the ledger" do
      context = described_class.new(tool_name: "t", principal: principal)

      expect(context.principal_type).to eq(principal.class.name)
      expect(context.principal_id).to eq("42")
    end

    it "reports nil identity when no principal was resolved" do
      context = described_class.new(tool_name: "t")

      expect(context.principal_type).to be_nil
      expect(context.principal_id).to be_nil
    end

    it "falls back to to_s when the principal has no id" do
      context = described_class.new(tool_name: "t", principal: "service-account")

      expect(context.principal_id).to eq("service-account")
    end

    it "clears the principal, so nothing leaks to the next invocation" do
      context = described_class.new(tool_name: "t", principal: principal)
      context.clear_principal!

      expect(context.principal).to be_nil
      expect(context).not_to be_principal_resolved
    end
  end

  describe "the arguments" do
    it "symbolises top-level argument keys" do
      context = described_class.new(tool_name: "t", arguments: { "query" => "acme" })

      expect(context.arguments).to eq(query: "acme")
    end

    it "does not mutate the hash the caller passed in" do
      original = { "query" => "acme" }
      described_class.new(tool_name: "t", arguments: original)

      expect(original).to eq("query" => "acme")
    end

    it "rejects arguments that are not a hash" do
      expect { described_class.new(tool_name: "t", arguments: %w[a b]) }
        .to raise_error(ArgumentError, /arguments/)
    end
  end

  describe "the metadata" do
    # Opaque to the core: an adapter's transport context passes through untouched.
    it "keeps whatever the adapter passed through" do
      metadata = { "user_id" => 7, nested: { deep: true } }
      context = described_class.new(tool_name: "t", metadata: metadata)

      expect(context.metadata[:user_id]).to eq(7)
      expect(context.metadata[:nested]).to eq(deep: true)
    end

    it "rejects metadata that is not a hash" do
      expect { described_class.new(tool_name: "t", metadata: "raw") }
        .to raise_error(ArgumentError, /metadata/)
    end
  end

  describe "#to_h" do
    it "returns the fields an audit entry is built from" do
      context = described_class.new(
        tool_name: "invoice_search",
        principal: principal,
        agent: { id: "a1", name: "Claude" },
        arguments: { query: "acme" }
      )

      expect(context.to_h).to include(
        invocation_id: context.invocation_id,
        occurred_at: context.invoked_at,
        tool_name: "invoice_search",
        agent_id: "a1",
        agent_name: "Claude",
        principal_type: principal.class.name,
        principal_id: "42",
        arguments: { query: "acme" }
      )
    end
  end
end
