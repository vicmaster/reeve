# frozen_string_literal: true

require_relative "support/ledger"

# T030 / FR-010. The ledger is append-only, and "append-only" has to mean something a
# host can rely on: the model refuses to change a persisted row and refuses to delete
# one, and the unique invocation_id makes a duplicate row impossible rather than
# unlikely.
RSpec.describe Reeve::Audit::Entry do
  before { Ledger.prepare! }

  def attributes(overrides = {})
    {
      invocation_id: SecureRandom.uuid,
      occurred_at: Time.now,
      agent_id: "claude-desktop",
      tool_name: "InvoiceSearchTool",
      arguments: { query: "acme" },
      outcome: "allow",
      rule: "InvoicePolicy::Scope",
      record_ids: %w[1 2],
      record_count: 2,
      guard: "policy",
      contract_version: Reeve::Audit::CONTRACT_VERSION
    }.merge(overrides)
  end

  describe "immutability" do
    it "is readonly once persisted, so update raises instead of rewriting history" do
      entry = described_class.create!(attributes)

      expect(entry).to be_readonly
      expect { entry.update!(rule: "something-else") }
        .to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(entry.reload.rule).to eq("InvoicePolicy::Scope")
    end

    it "refuses to save an attribute change on a reloaded row" do
      created = described_class.create!(attributes)
      entry = described_class.find(created.id)
      entry.outcome = "deny"

      expect { entry.save }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(described_class.find(created.id).outcome).to eq("allow")
    end

    it "aborts destroy" do
      entry = described_class.create!(attributes)

      expect(entry.destroy).to be(false)
      expect(described_class.count).to eq(1)
    end

    it "aborts destroy! too" do
      entry = described_class.create!(attributes)

      expect { entry.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(described_class.count).to eq(1)
    end

    it "exposes no library method that mutates an entry by id" do
      forbidden = described_class.methods(false).grep(/update|delete|destroy/)

      expect(forbidden).to be_empty
    end
  end

  describe "validation" do
    it "rejects a second entry for the same invocation" do
      shared = SecureRandom.uuid
      described_class.create!(attributes(invocation_id: shared))

      expect { described_class.create!(attributes(invocation_id: shared)) }
        .to raise_error(ActiveRecord::RecordInvalid, /invocation/i)
    end

    it "enforces uniqueness in the database, not only in Ruby" do
      shared = SecureRandom.uuid
      described_class.create!(attributes(invocation_id: shared))
      duplicate = described_class.new(attributes(invocation_id: shared))

      expect { duplicate.save!(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    %i[invocation_id occurred_at agent_id tool_name outcome rule guard].each do |column|
      it "refuses an entry with no #{column}" do
        entry = described_class.new(attributes(column => nil))

        expect(entry).not_to be_valid
        expect(entry.errors[column]).not_to be_empty
        expect { entry.save! }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    it "refuses an outcome that is neither allow nor deny" do
      expect { described_class.create!(attributes(outcome: "maybe")) }
        .to raise_error(ActiveRecord::RecordInvalid, /outcome/i)
    end

    it "accepts a denial with no principal, which is exactly the no_principal row" do
      entry = described_class.create!(
        attributes(outcome: "deny", rule: Reeve::Decision::NO_PRINCIPAL,
                   principal_type: nil, principal_id: nil, record_ids: [], record_count: 0)
      )

      expect(entry).to be_persisted
    end
  end

  describe "storage" do
    it "round-trips arguments and record identifiers as JSON" do
      entry = described_class.create!(
        attributes(arguments: { query: "acme", page: 2 }, record_ids: %w[7 8 9])
      )

      reloaded = entry.reload
      expect(reloaded.arguments).to eq("query" => "acme", "page" => 2)
      expect(reloaded.record_ids).to eq(%w[7 8 9])
    end

    it "keeps occurred_at as given rather than as write time" do
      invoked_at = Time.now - 3600
      entry = described_class.create!(attributes(occurred_at: invoked_at))

      expect(entry.reload.occurred_at).to be_within(1).of(invoked_at)
    end

    it "defaults the flags so a minimal insert is still a complete row" do
      entry = described_class.create!(attributes)

      expect(entry.truncated).to be(false)
      expect(entry.derived).to be(false)
      expect(entry.metadata).to be_nil
    end
  end

  describe "predicates" do
    it "answers allowed? and denied? without the caller comparing strings" do
      allowed = described_class.create!(attributes)
      denied  = described_class.create!(
        attributes(outcome: "deny", rule: Reeve::Decision::NO_PRINCIPAL)
      )

      expect(allowed).to be_allowed
      expect(allowed).not_to be_denied
      expect(denied).to be_denied
    end
  end
end
