# frozen_string_literal: true

require "support/optional/authorization_records"
require "reeve/audit"
require "reeve/audit/support/ledger"
require "reeve/testing"

# The tools the testing kit is pointed at: one that is correct, and one deliberately broken
# per guarantee (SC-007).
#
# Nothing here is stubbed. The leaker really does return another principal's invoices,
# because its policy really does forget the `where` — that is what a leak looks like in a
# real application, and a fixture that faked it would prove nothing about the check.
#
# The guards are declared in +install!+ rather than in the class bodies because
# spec_helper resets the registry before every example; a declaration made at load time
# would be swept away before the first one ran.
module ReeveFixtures
  # The correct policy: every principal sees only their own invoices.
  class GoodInvoicePolicy
    def self.name = "InvoicePolicy"

    def self.authorize(principal, _action, record)
      return false if principal.nil?
      return true if record.nil?

      record.owner_id == principal.id
    end

    def self.scope(principal, relation)
      relation.where(owner_id: principal.id)
    end
  end

  # The same policy with the `where` dropped from #scope. It still calls itself
  # InvoicePolicy, so it still governs Invoice — a wrong policy, not an absent one.
  class LeakyInvoicePolicy
    def self.name = "InvoicePolicy"

    def self.authorize(_principal, _action, _record) = true

    def self.scope(_principal, relation) = relation
  end

  # Correct: guarded, audited, redacting.
  class CompliantInvoiceTool
    include Reeve::Guard

    def call(query: "", customer_ssn: nil)
      _ = customer_ssn
      Invoice.where("number LIKE ?", "#{query}%")
    end
  end

  # Guarded by the policy that forgot to narrow: both principals see every invoice.
  class LeakyInvoiceTool
    include Reeve::Guard

    def call(query: "")
      Invoice.where("number LIKE ?", "#{query}%")
    end
  end

  # Correct in itself. What is broken is how it is invoked: see BYPASSING_INVOKER.
  class BypassingInvoiceTool
    include Reeve::Guard

    def call(query: "")
      Invoice.where("number LIKE ?", "#{query}%")
    end
  end

  # No guard_with at all.
  class UnguardedInvoiceTool
    include Reeve::Guard

    def call(query: "")
      Invoice.where("number LIKE ?", "#{query}%")
    end
  end

  # Declares `redact :ssn` while the argument it actually takes is `customer_ssn`. The
  # declaration is inert and the value reaches the ledger in the clear.
  class MisdeclaredRedactionTool
    include Reeve::Guard

    def call(query: "", customer_ssn: nil)
      _ = customer_ssn
      Invoice.where("number LIKE ?", "#{query}%")
    end
  end

  # A tool called straight through, with no envelope around it: no authorization, no
  # ledger row. The realistic shape of an audit bypass is not a broken tool but a caller
  # that reaches past Reeve.invoke.
  BYPASSING_INVOKER = lambda do |tool:, arguments: {}, **_ignored|
    instance = tool.new
    arguments.empty? ? instance.call : instance.call(**arguments)
  end

  # A host-written recorder that forgot to redact. The gem's own recorder cannot produce
  # this row; a custom one can, which is exactly why the check exists.
  class UnredactingRecorder
    COLUMNS = %i[
      invocation_id occurred_at agent_name principal_type principal_id tool_name rule
      detail record_type duration_ms metadata
    ].freeze

    def self.record(attributes)
      Reeve::Audit::Entry.create!(
        attributes.slice(*COLUMNS).merge(
          agent_id: attributes[:agent_id] || "unknown",
          arguments: attributes[:arguments] || {},
          outcome: attributes[:outcome].to_s,
          record_ids: attributes[:record_ids] || [],
          record_count: attributes[:record_count] || 0,
          truncated: attributes[:truncated] ? true : false,
          derived: attributes[:derived] ? true : false,
          guard: attributes[:guard] || "policy"
        )
      )
    end
  end

  # Stands in for a ledger the checks cannot read, or one whose shape is wrong. Used only
  # where a real broken ledger would mean dropping a column from the shared connection.
  class FakeLedger
    attr_reader :contract_version

    def initialize(entries: [], available: true, contract_version: 1, columns: nil,
                   reason: "the audit ledger is not loaded")
      @entries = entries
      @available = available
      @contract_version = contract_version
      @columns = columns
      @reason = reason
    end

    def available? = @available
    def unavailable_reason = @available ? nil : @reason
    def marker = 0
    def entries_after(_marker) = @entries
    def columns = @columns || Reeve::Testing::Checks::ContractVersion::COLUMNS.dup
    def count = @entries.size
  end

  # An entry-shaped double for the one row the real model refuses to create.
  RuleLessEntry = Struct.new(:id, :rule, :outcome, :tool_name, :arguments, keyword_init: true) do
    def attributes = to_h.transform_keys(&:to_s)
  end

  module_function

  def alice = Owner.new(1)
  def bob   = Owner.new(2)

  def principals = [alice, bob]

  # Called from a `before` hook: a clean ledger, a known record set, and the guard
  # declarations the registry reset just removed.
  def install!
    Ledger.prepare!
    Invoice.delete_all
    Reeve.configure { |config| config.audit_recorder = Reeve::Audit::Recorder }
    seed!
    declare!
  end

  def seed!
    Invoice.create!(number: "A-0", owner_id: alice.id)
    Invoice.create!(number: "A-1", owner_id: alice.id)
    Invoice.create!(number: "B-0", owner_id: bob.id)
  end

  # `redact` before `guard_with`, so the declaration is registered once with its
  # redactions already folded in rather than registered and then replaced.
  def declare!
    CompliantInvoiceTool.redact(:customer_ssn)
    CompliantInvoiceTool.guard_with(GoodInvoicePolicy)
    LeakyInvoiceTool.guard_with(LeakyInvoicePolicy)
    BypassingInvoiceTool.guard_with(GoodInvoicePolicy)
    MisdeclaredRedactionTool.redact(:ssn)
    MisdeclaredRedactionTool.guard_with(GoodInvoicePolicy)
  end
end

RSpec.shared_context "with reeve fixtures" do
  let(:alice) { ReeveFixtures.alice }
  let(:bob)   { ReeveFixtures.bob }

  before { ReeveFixtures.install! }
end

RSpec.configure do |config|
  config.include_context "with reeve fixtures", reeve_fixtures: true
end
