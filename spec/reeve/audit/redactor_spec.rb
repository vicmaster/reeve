# frozen_string_literal: true

require_relative "support/ledger"

# T032 / FR-011. Argument names are the point of the ledger — "which invoice did it ask
# for?" — and argument values are the risk. The redactor keeps the first and destroys the
# second, before anything reaches the database.
RSpec.describe Reeve::Audit::Redactor do
  # A stand-in for the authorization registry (W1): the guard a tool declares carries the
  # extra argument names that tool wants redacted.
  FakeGuard = Struct.new(:redacted_arguments)

  let(:registry) { instance_double("Registry") }

  def redact(arguments, names: %i[password token])
    described_class.new(names).call(arguments)
  end

  it "replaces a declared value with the marker and keeps the name" do
    result = redact({ query: "acme", password: "hunter2" })

    expect(result).to eq(query: "acme", password: described_class::MARKER)
  end

  it "matches string keys as well as symbol keys" do
    result = redact({ "password" => "hunter2" })

    expect(result).to eq("password" => described_class::MARKER)
  end

  it "matches case-insensitively, because transports do not agree on casing" do
    result = redact({ "Authorization" => "Bearer abc", :Token => "t", "PASSWORD" => "p" })

    expect(result.values).to eq([
                                  "Bearer abc", described_class::MARKER,
                                  described_class::MARKER
                                ])
  end

  it "recurses into nested hashes" do
    result = redact({ filters: { owner: "acme", token: "secret" } })

    expect(result).to eq(filters: { owner: "acme", token: described_class::MARKER })
  end

  it "recurses into hashes inside arrays" do
    result = redact({ accounts: [{ id: 1, password: "a" }, { id: 2, password: "b" }] })

    expect(result[:accounts].map { |a| a[:password] })
      .to eq([described_class::MARKER, described_class::MARKER])
    expect(result[:accounts].map { |a| a[:id] }).to eq([1, 2])
  end

  it "redacts a whole subtree when the subtree itself is declared sensitive" do
    result = redact({ token: { access: "a", refresh: "b" } }, names: %i[token])

    expect(result).to eq(token: described_class::MARKER)
  end

  it "leaves the caller's arguments untouched — no unredacted copy is written anywhere" do
    arguments = { password: "hunter2", filters: { token: "secret" } }
    frozen_copy = Marshal.load(Marshal.dump(arguments))

    redact(arguments)

    expect(arguments).to eq(frozen_copy)
  end

  it "handles a nil or empty argument hash" do
    expect(described_class.new(%i[password]).call(nil)).to eq({})
    expect(described_class.new(%i[password]).call({})).to eq({})
  end

  it "redacts nothing when nothing is declared" do
    expect(described_class.new([]).call(password: "hunter2"))
      .to eq(password: "hunter2")
  end

  describe ".for" do
    before do
      Reeve.config.redact_arguments = %i[ssn]
    end

    it "uses the globally declared names" do
      redactor = described_class.for("InvoiceSearchTool", registry: nil)

      expect(redactor.call(ssn: "111", query: "acme"))
        .to eq(ssn: described_class::MARKER, query: "acme")
    end

    it "adds the names the tool's own guard declared" do
      allow(registry).to receive(:guard_for)
        .with("InvoiceSearchTool").and_return(FakeGuard.new(%i[query]))

      redactor = described_class.for("InvoiceSearchTool", registry: registry)

      expect(redactor.call(ssn: "111", query: "acme"))
        .to eq(ssn: described_class::MARKER, query: described_class::MARKER)
    end

    it "does not carry one tool's declaration into another's entry" do
      allow(registry).to receive(:guard_for).with("OtherTool").and_return(nil)

      redactor = described_class.for("OtherTool", registry: registry)

      expect(redactor.call(query: "acme")).to eq(query: "acme")
    end

    it "tolerates a registry that knows nothing about guards" do
      redactor = described_class.for("InvoiceSearchTool", registry: Object.new)

      expect(redactor.call(ssn: "111")).to eq(ssn: described_class::MARKER)
    end
  end
end
