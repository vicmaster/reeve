# frozen_string_literal: true

require "support/optional/authorization_records"

# The official SDK runs a tool's body on the class, not an instance, so `scoped` and
# `authorize!` must work as class methods and mean exactly what they mean on an instance.
RSpec.describe Reeve::Guard::Helpers do
  let(:alice) { Owner.new(1) }
  let(:recorder) { FakeRecorder.new }

  before do
    Invoice.delete_all
    Invoice.create!(number: "A-0", owner_id: 1)
    Invoice.create!(number: "A-1", owner_id: 1)
    Invoice.create!(number: "B-0", owner_id: 2)

    Reeve.configure { |c| c.audit_recorder = recorder }
  end

  def class_tool(&body)
    klass = Class.new do
      include Reeve::Guard
      extend Reeve::Guard::Helpers

      guard_with InvoicePolicy
    end
    klass.define_singleton_method(:call, &body)
    stub_const("ClassLevelTool", klass)
  end

  def run(tool)
    Reeve.invoke(tool: tool, principal: alice) { tool.call }
  end

  it "scopes a relation for the invoking principal, as on an instance" do
    tool = class_tool { scoped(Invoice).pluck(:number).sort }

    expect(run(tool)).to eq(%w[A-0 A-1])
  end

  it "marks the invocation as scoped, so a derived result is allowed" do
    tool = class_tool { scoped(Invoice).count.to_s }

    expect(run(tool)).to eq("2")
    expect(recorder.entry[:outcome]).to eq("allow")
  end

  it "leaves a derived result without scoped(...) denied" do
    tool = class_tool { Invoice.count.to_s }

    expect { run(tool) }.to raise_error(Reeve::DeniedError) { |e|
      expect(e.rule).to eq("unscoped_derived_result")
    }
  end

  it "denies through authorize! with the policy's rule and no record" do
    tool = class_tool { authorize!(Invoice.find_by(number: "B-0")) && "sent" }

    expect { run(tool) }.to raise_error(Reeve::DeniedError) { |e|
      expect(e.rule).to eq("InvoicePolicy#index")
      expect(e.message).not_to include("B-0")
    }
  end

  it "refuses outside an invocation, as on an instance" do
    tool = class_tool { scoped(Invoice) }

    expect { tool.call }.to raise_error(Reeve::Error, /inside a guarded invocation/)
  end
end
