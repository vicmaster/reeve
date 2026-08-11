# frozen_string_literal: true

RSpec.describe Reeve::Invocation do
  let(:principal) { double("User", id: 42) }
  let(:guard)     { double("GuardDeclaration") }
  let(:recorder)  { FakeRecorder.new }
  let(:registry)  { FakeRegistry.new("invoice_search" => guard) }
  let(:allowing)  { FakeAuthorizer.new(Reeve::Decision.allow(rule: "InvoicePolicy#index?")) }
  let(:scoper)    { FakeScoper.new(Reeve::ScopeResult.allow(records: %w[inv-1], record_type: "Invoice", record_ids: [1])) }

  def context(tool_name: "invoice_search", **overrides)
    Reeve::Context.new(tool_name: tool_name, **overrides)
  end

  def invoke(ctx = context, registry: self.registry, authorizer: allowing,
             scoper: self.scoper, recorder: self.recorder, &tool)
    described_class.call(
      ctx, registry: registry, authorizer: authorizer, scoper: scoper, recorder: recorder,
      &tool || -> { %w[inv-1] }
    )
  end

  before do
    Reeve.configure { |c| c.principal_resolver = ->(_ctx) { principal } }
  end

  describe "the happy path" do
    it "returns the scoped records" do
      expect(invoke).to eq(%w[inv-1])
    end

    it "runs the tool body exactly once" do
      runs = 0
      invoke { runs += 1 }

      expect(runs).to eq(1)
    end

    it "hands the tool's raw result to the scoper — nothing reaches the caller unscoped" do
      invoke { %w[raw] }

      expect(scoper.calls.last[:result]).to eq(%w[raw])
    end

    it "records one allowed entry naming the rule that allowed it" do
      invoke

      expect(recorder.entry).to include(
        outcome: "allow",
        rule: "InvoicePolicy#index?",
        tool_name: "invoice_search",
        principal_id: "42",
        record_type: "Invoice",
        record_ids: %w[1],
        record_count: 1,
        truncated: false,
        derived: false,
        guard: "policy"
      )
    end

    it "records the invocation id and the entry timing" do
      ctx = context
      invoke(ctx)

      expect(recorder.entry[:invocation_id]).to eq(ctx.invocation_id)
      expect(recorder.entry[:occurred_at]).to eq(ctx.invoked_at)
      expect(recorder.entry[:duration_ms]).to be_a(Integer)
    end

    it "passes the arguments through unredacted — redaction is the recorder's job" do
      invoke(context(arguments: { password: "hunter2" }))

      expect(recorder.entry[:arguments]).to eq(password: "hunter2")
    end
  end

  # Invariant 1: every path terminates in exactly one audit write attempt.
  describe "exactly one ledger entry per invocation" do
    it "writes one on allow" do
      invoke
      expect(recorder.entries.size).to eq(1)
    end

    it "writes one when the principal is missing" do
      Reeve.configure { |c| c.principal_resolver = ->(_ctx) {} }
      expect { invoke }.to raise_error(Reeve::DeniedError)

      expect(recorder.entries.size).to eq(1)
    end

    it "writes one when no guard is declared" do
      expect { invoke(registry: FakeRegistry.new) }.to raise_error(Reeve::DeniedError)

      expect(recorder.entries.size).to eq(1)
    end

    it "writes one when the policy denies" do
      denying = FakeAuthorizer.new(Reeve::Decision.deny(rule: "InvoicePolicy#index?"))
      expect { invoke(authorizer: denying) }.to raise_error(Reeve::DeniedError)

      expect(recorder.entries.size).to eq(1)
    end

    it "writes one when the tool body raises" do
      expect { invoke { raise "boom" } }.to raise_error(RuntimeError, "boom")

      expect(recorder.entries.size).to eq(1)
    end

    it "writes one when scoping denies" do
      out_of_scope = FakeScoper.new(Reeve::ScopeResult.deny(rule: Reeve::Decision::OUT_OF_SCOPE_RECORD))
      expect { invoke(scoper: out_of_scope) }.to raise_error(Reeve::DeniedError)

      expect(recorder.entries.size).to eq(1)
    end
  end

  # Invariant 2: every terminal deny carries a rule.
  describe "denials" do
    it "denies with no_principal when the resolver returns nil" do
      Reeve.configure { |c| c.principal_resolver = ->(_ctx) {} }

      expect { invoke }.to raise_error(Reeve::DeniedError) { |error|
        expect(error.rule).to eq("no_principal")
      }
      expect(recorder.entry).to include(outcome: "deny", rule: "no_principal", principal_id: nil)
    end

    it "denies with no_principal when the resolver raises — failing closed, not open" do
      Reeve.configure { |c| c.principal_resolver = ->(_ctx) { raise "session gone" } }

      expect { invoke }.to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("no_principal") }
    end

    it "denies with no_principal when no resolver is configured at all" do
      Reeve.reset_configuration!

      expect { invoke }.to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("no_principal") }
    end

    it "denies with no_guard_declared for an unguarded tool" do
      expect { invoke(registry: FakeRegistry.new) }
        .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("no_guard_declared") }
    end

    it "denies with policy_error when the policy raises" do
      expect { invoke(authorizer: RaisingAuthorizer.new) }
        .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("policy_error") }
    end

    it "denies with policy_error when the registry itself raises" do
      expect { invoke(registry: RaisingRegistry.new) }
        .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("policy_error") }
    end

    it "denies with policy_error when the scoper raises" do
      exploding = Class.new { def scope(**) = raise("scoper exploded") }.new

      expect { invoke(scoper: exploding) }
        .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("policy_error") }
    end

    it "propagates the rule the scoper denied with" do
      out_of_scope = FakeScoper.new(Reeve::ScopeResult.deny(rule: Reeve::Decision::OUT_OF_SCOPE_RECORD))

      expect { invoke(scoper: out_of_scope) }
        .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("out_of_scope_record") }
    end

    it "never records a nil rule" do
      [
        -> { invoke(registry: FakeRegistry.new) },
        -> { invoke(authorizer: RaisingAuthorizer.new) },
        -> { invoke { raise "boom" } }
      ].each do |scenario|
        recorder.entries.clear
        begin
          scenario.call
        rescue StandardError
          nil
        end
        expect(recorder.entry[:rule]).not_to be_nil
      end
    end
  end

  # Invariant 3: no path returns records without passing through scoping.
  describe "the scoping step" do
    it "does not run the tool when the policy denied" do
      ran = false
      denying = FakeAuthorizer.new(Reeve::Decision.deny(rule: "InvoicePolicy#index?"))

      expect { invoke(authorizer: denying) { ran = true } }.to raise_error(Reeve::DeniedError)
      expect(ran).to be(false)
    end

    it "does not scope when the tool never ran" do
      expect { invoke(registry: FakeRegistry.new) }.to raise_error(Reeve::DeniedError)

      expect(scoper.calls).to be_empty
    end

    it "returns the scoper's records, not the tool's" do
      narrowing = FakeScoper.new(Reeve::ScopeResult.allow(records: %w[only-mine], record_ids: [1]))

      expect(invoke(scoper: narrowing) { %w[everything else] }).to eq(%w[only-mine])
    end

    it "records a derived result as derived" do
      derived = FakeScoper.new(Reeve::ScopeResult.allow(records: 12, derived: true))
      invoke(scoper: derived) { 12 }

      expect(recorder.entry).to include(derived: true, record_ids: [], record_type: nil)
    end
  end

  # Invariant 4: nothing leaks into the next invocation on this thread.
  describe "principal hygiene" do
    it "clears the principal after a successful call" do
      ctx = context
      invoke(ctx)

      expect(ctx.principal).to be_nil
    end

    it "clears the principal when the tool raises" do
      ctx = context
      expect { invoke(ctx) { raise "boom" } }.to raise_error(RuntimeError)

      expect(ctx.principal).to be_nil
    end

    it "clears the principal when the call is denied" do
      ctx = context
      expect { invoke(ctx, registry: FakeRegistry.new) }.to raise_error(Reeve::DeniedError)

      expect(ctx.principal).to be_nil
    end

    it "still records who the principal was" do
      invoke

      expect(recorder.entry[:principal_id]).to eq("42")
      expect(recorder.entry[:principal_type]).to eq(principal.class.name)
    end
  end

  describe "a tool body that raises" do
    it "re-raises the tool's own error rather than dressing it as a denial" do
      expect { invoke { raise ArgumentError, "bad query" } }
        .to raise_error(ArgumentError, "bad query")
    end

    # R5: the invocations most worth recording are the ones that blew up.
    it "records the failure with the tool_error rule and no records" do
      begin
        invoke { raise ArgumentError, "bad query" }
      rescue ArgumentError
        nil
      end

      expect(recorder.entry).to include(
        outcome: "deny", rule: "tool_error", record_ids: [], record_count: 0
      )
      expect(recorder.entry[:rule]).to eq(Reeve::Decision::TOOL_ERROR)
    end

    it "names the error class in the entry without leaking the message into the rule" do
      begin
        invoke { raise ArgumentError, "bad query" }
      rescue ArgumentError
        nil
      end

      expect(recorder.entry[:rule]).to eq("tool_error")
    end
  end

  describe "unguarded_tools :allow_with_warning" do
    before { Reeve.configure { |c| c.unguarded_tools = :allow_with_warning } }

    it "runs the tool and returns its result" do
      expect(invoke(registry: FakeRegistry.new) { %w[legacy] }).to eq(%w[legacy])
    end

    it "records the entry as unguarded so the gap is visible in the ledger" do
      invoke(registry: FakeRegistry.new) { %w[legacy] }

      expect(recorder.entry).to include(
        outcome: "allow", rule: Reeve::Decision::UNGUARDED_TOOL, guard: "none"
      )
    end

    # Review finding: this path recorded record_count: 0 for a call that returned
    # everything, which is not an incomplete entry but a false one — and it is the one
    # path where the result was never narrowed at all.
    it "records what the unscoped call actually returned" do
      records = [double("Row", id: 1), double("Row", id: 2), double("Row", id: 3)]

      invoke(registry: FakeRegistry.new) { records }

      expect(recorder.entry).to include(
        outcome: "allow", guard: "none", record_count: 3, record_ids: %w[1 2 3]
      )
    end

    it "truncates those identifiers like any other entry" do
      Reeve.configure { |c| c.max_recorded_ids = 2 }
      records = (1..5).map { |i| double("Row", id: i) }

      invoke(registry: FakeRegistry.new) { records }

      expect(recorder.entry[:record_ids].size).to eq(2)
      expect(recorder.entry[:record_count]).to eq(5)
      expect(recorder.entry[:truncated]).to be(true)
    end

    it "warns through the configured logger" do
      logger = CapturingLogger.new
      Reeve.configure { |c| c.logger = logger }

      invoke(registry: FakeRegistry.new) { %w[legacy] }

      expect(logger.warnings.join).to include("invoice_search")
    end

    it "does not weaken a tool that does declare a guard" do
      denying = FakeAuthorizer.new(Reeve::Decision.deny(rule: "InvoicePolicy#index?"))

      expect { invoke(authorizer: denying) }.to raise_error(Reeve::DeniedError)
    end
  end

  describe "ledger write failure" do
    let(:failing) { RaisingRecorder.new }

    it "fails the invocation by default" do
      expect { invoke(recorder: failing) }.to raise_error(Reeve::AuditWriteError)
    end

    it "names the invocation it could not record" do
      ctx = context

      expect { invoke(ctx, recorder: failing) }
        .to raise_error(Reeve::AuditWriteError) { |e| expect(e.invocation_id).to eq(ctx.invocation_id) }
    end

    it "does not retry the write" do
      expect { invoke(recorder: failing) }.to raise_error(Reeve::AuditWriteError)

      expect(failing.attempts).to eq(1)
    end

    it "continues and warns in the opt-in :warn mode" do
      logger = CapturingLogger.new
      Reeve.configure do |c|
        c.audit_failure_mode = :warn
        c.logger = logger
      end

      expect(invoke(recorder: failing)).to eq(%w[inv-1])
      expect(logger.warnings.join).to match(/ledger unavailable|could not record/)
    end

    # A call that cannot be recorded is a failed call, in flight or not (Constitution II).
    # The tool's own error is carried on the audit error rather than traded against it.
    it "fails with an audit error carrying the tool's error when both fail" do
      expect { invoke(recorder: failing) { raise ArgumentError, "bad query" } }
        .to raise_error(Reeve::AuditWriteError) { |error|
          expect(error.during).to be_a(ArgumentError)
          expect(error.message).to include("bad query")
        }
    end

    it "lets the tool's error through untouched in the opt-in :warn mode" do
      logger = CapturingLogger.new
      Reeve.configure do |c|
        c.audit_failure_mode = :warn
        c.logger = logger
      end

      expect { invoke(recorder: failing) { raise ArgumentError, "bad query" } }
        .to raise_error(ArgumentError, "bad query")
      expect(logger.warnings.join).to match(/could not record/)
    end
  end

  describe "collaborator defaults" do
    # A kernel with no modules wired in must deny, not pass through.
    it "denies every call when nothing is injected" do
      expect { described_class.call(context, recorder: recorder) { %w[records] } }
        .to raise_error(Reeve::DeniedError) { |e| expect(e.rule).to eq("no_guard_declared") }
    end

    # With no ledger at all the denial cannot be recorded, and an unrecordable call fails
    # as an audit failure — carrying the denial, so the developer sees both.
    it "reports the missing ledger, not just the denial, when neither is configured" do
      expect { described_class.call(context) { %w[records] } }
        .to raise_error(Reeve::AuditWriteError) { |error|
          expect(error.during).to be_a(Reeve::DeniedError)
          expect(error.message).to match(/no audit recorder is configured/)
        }
    end

    it "fails closed on the ledger too, since a call it cannot record is a call it cannot make" do
      Reeve.configure { |c| c.unguarded_tools = :allow_with_warning }

      expect { described_class.call(context) { %w[records] } }
        .to raise_error(Reeve::AuditWriteError)
    end

    it "takes the recorder from configuration when none is injected" do
      Reeve.configure { |c| c.audit_recorder = recorder }

      described_class.call(context, registry: registry, authorizer: allowing, scoper: scoper) { %w[x] }

      expect(recorder.entries.size).to eq(1)
    end
  end
end
