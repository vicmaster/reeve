# frozen_string_literal: true

require "support/optional/authorization_records"

# One agent, many principals, at the same time — the normal case for an MCP server, and
# the one where a process-wide "current user" would quietly hand one person's records to
# another. Data-model invariant 4 exists for this spec.
RSpec.describe "concurrent invocations" do
  let(:owners) { (1..4).map { |id| Owner.new(id) } }
  let(:recorder) { ThreadSafeRecorder.new }

  before do
    Invoice.delete_all
    owners.each { |owner| 3.times { |i| Invoice.create!(number: "#{owner.id}-#{i}", owner_id: owner.id) } }

    Reeve.configure { |c| c.audit_recorder = recorder }

    stub_const("SlowInvoiceTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy

      # The sleep is the point: it guarantees the invocations overlap rather than
      # happening to run one after another.
      def call
        records = Invoice.all
        sleep 0.01
        records
      end
    end)
  end

  it "gives each thread only its own principal's records" do
    results = owners.map do |owner|
      Thread.new do
        records = Reeve.invoke(tool: SlowInvoiceTool, principal: owner)
        [owner.id, records.map(&:number)]
      end
    end.to_h(&:value)

    owners.each do |owner|
      expect(results[owner.id]).to all(start_with("#{owner.id}-"))
      expect(results[owner.id].size).to eq(3)
    end
  end

  it "records each invocation against the principal that made it" do
    threads = owners.map do |owner|
      Thread.new { Reeve.invoke(tool: SlowInvoiceTool, principal: owner) }
    end
    threads.each(&:join)

    by_principal = recorder.entries.group_by { |entry| entry[:principal_id] }

    expect(by_principal.keys).to match_array(owners.map { |owner| owner.id.to_s })
    expect(by_principal.values.map(&:size)).to all(eq(1))
    expect(recorder.entries.map { |entry| entry[:record_count] }).to all(eq(3))
  end

  it "leaves no invocation state behind on any thread" do
    threads = owners.map do |owner|
      Thread.new do
        Reeve.invoke(tool: SlowInvoiceTool, principal: owner)
        Reeve::Authorization::Current.state
      end
    end

    expect(threads.map(&:value)).to all(be_nil)
    expect(Reeve::Authorization::Current.state).to be_nil
  end

  it "does not let a scoped(...) call in one thread widen another's" do
    stub_const("CountTool", Class.new do
      include Reeve::Guard

      guard_with InvoicePolicy

      def call
        relation = scoped(Invoice)
        sleep 0.01
        relation.count
      end
    end)

    counts = owners.map { |owner| Thread.new { Reeve.invoke(tool: CountTool, principal: owner) } }
                   .map(&:value)

    expect(counts).to all(eq(3))
  end
end
