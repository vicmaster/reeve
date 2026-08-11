# frozen_string_literal: true

module Reeve
  # The single funnel every guarded tool call passes through:
  #
  #   resolve principal → look up guard → authorize → execute → scope → record → return
  #
  # One envelope rather than middleware or a patched dispatcher, so there is exactly one
  # place where "did this get authorized and recorded?" can be answered — and exactly one
  # place to audit when the answer must be yes.
  #
  # Collaborators are injected and default to null objects that fail closed: a kernel with
  # no authorization module wired in denies everything, and one with no ledger refuses the
  # call rather than performing it silently.
  class Invocation
    # A tool with no guard: there is nothing to consult, so there is nothing to allow.
    class NullRegistry
      def guard_for(_tool_name)
        nil
      end
    end

    # No policy adapter wired in: nothing can be evaluated, so nothing is permitted.
    class NullAuthorizer
      def authorize(context:, guard:)
        Decision.deny(rule: Decision::POLICY_ERROR, detail: "no policy adapter is configured")
      end
    end

    # No scoper wired in: a result that cannot be narrowed cannot be returned.
    class NullScoper
      def scope(context:, guard:, result:)
        ScopeResult.deny(
          rule: Decision::UNSCOPED_DERIVED_RESULT,
          detail: "no scoper is configured, so the result could not be narrowed"
        )
      end
    end

    # Constitution II: a failure to record is a failure of the call. With no ledger
    # configured there is nothing to fail into, so this refuses rather than no-ops.
    class NullRecorder
      def record(_attributes)
        raise Error, "no audit recorder is configured (run `rails g reeve:install`)"
      end
    end

    def self.call(context, **collaborators, &tool)
      new(context, **collaborators).call(&tool)
    end

    def initialize(context, registry: nil, authorizer: nil, scoper: nil, recorder: nil,
                   config: nil)
      @context    = context
      @config     = config || Reeve.config
      @registry   = registry   || NullRegistry.new
      @authorizer = authorizer || NullAuthorizer.new
      @scoper     = scoper     || NullScoper.new
      @recorder   = recorder   || @config.audit_recorder || NullRecorder.new
    end

    def call(&tool)
      started = monotonic_now
      @guard_label = "policy"
      @scope_result = nil

      @decision = authorize_and_run(&tool)
      raise denial_error(@decision) if @decision.denied?

      @scope_result.records
    ensure
      # Whatever is already on its way out of this method — a tool error or a denial.
      @in_flight_error = $ERROR_INFO
      @duration_ms = ((monotonic_now - started) * 1000).round
      write_entry
      context.clear_principal!
    end

    private

    attr_reader :context, :config, :registry, :authorizer, :scoper, :recorder

    def authorize_and_run(&tool)
      principal = resolve_principal
      if principal.nil?
        return Decision.deny(rule: Decision::NO_PRINCIPAL,
                             detail: principal_denial_detail)
      end

      context.principal = principal

      guard = look_up_guard
      return guard if guard.is_a?(Decision) # registry blew up

      if guard.nil?
        if deny_unguarded?
          return Decision.deny(rule: Decision::NO_GUARD_DECLARED,
                               detail: unguarded_detail)
        end

        return run_unguarded(&tool)
      end

      decision = authorize(guard)
      return decision if decision.denied?

      run_guarded(guard, decision, &tool)
    end

    def resolve_principal
      resolver = config.principal_resolver
      return nil if resolver.nil?

      resolver.call(context)
    rescue StandardError => e
      # A resolver that raises is a resolver that did not identify anyone (FR-001).
      @principal_error = e
      nil
    end

    def principal_denial_detail
      return "principal_resolver raised #{@principal_error.class}" if @principal_error
      return "no principal_resolver is configured" if config.principal_resolver.nil?

      "principal_resolver returned nil"
    end

    def look_up_guard
      registry.guard_for(context.tool_name)
    rescue StandardError => e
      Decision.deny(rule: Decision::POLICY_ERROR,
                    detail: "guard lookup raised #{e.class}: #{e.message}")
    end

    def deny_unguarded?
      config.unguarded_tools != :allow_with_warning
    end

    def unguarded_detail
      "#{context.tool_name} has no guard_with declaration"
    end

    def authorize(guard)
      decision = authorizer.authorize(context: context, guard: guard)
      return decision if decision.is_a?(Decision)

      Decision.deny(
        rule: Decision::POLICY_ERROR,
        detail: "authorizer returned #{decision.class}, expected a Reeve::Decision"
      )
    rescue StandardError => e
      Decision.deny(rule: Decision::POLICY_ERROR, detail: "policy raised #{e.class}: #{e.message}")
    end

    def run_guarded(guard, decision, &tool)
      result = execute(&tool)

      @scope_result = narrow(guard, result)
      @scope_result.denied? ? @scope_result.decision : decision
    end

    # The degraded mode a host opts into while retrofitting guards onto existing tools
    # (FR-023). The call is unscoped — that is the whole point of the warning.
    def run_unguarded(&tool)
      warn_about_unguarded_tool
      @guard_label = "none"
      result = execute(&tool)
      @scope_result = ScopeResult.allow(records: result, rule: Decision::UNGUARDED_TOOL)
      Decision.allow(rule: Decision::UNGUARDED_TOOL, detail: unguarded_detail)
    end

    def execute(&tool)
      tool.call
    rescue StandardError => e
      # The tool's own failure propagates untouched, but not before the ensure block
      # records it: the invocations most worth having a trace of are the ones that broke.
      @decision = Decision.deny(rule: Decision::TOOL_ERROR, detail: "#{e.class}: #{e.message}")
      @scope_result = ScopeResult.deny(rule: Decision::TOOL_ERROR)
      raise
    end

    def narrow(guard, result)
      scoped = scoper.scope(context: context, guard: guard, result: result)
      return scoped if scoped.is_a?(ScopeResult)

      ScopeResult.deny(
        rule: Decision::POLICY_ERROR,
        detail: "scoper returned #{scoped.class}, expected a Reeve::ScopeResult"
      )
    rescue StandardError => e
      ScopeResult.deny(rule: Decision::POLICY_ERROR,
                       detail: "scoping raised #{e.class}: #{e.message}")
    end

    def denial_error(decision)
      if decision.rule == Decision::OUT_OF_SCOPE_RECORD
        DeniedError.out_of_scope(tool_name: context.tool_name, principal_id: context.principal_id)
      else
        DeniedError.from(decision, tool_name: context.tool_name, principal_id: context.principal_id)
      end
    end

    def write_entry
      return if @entry_written

      @entry_written = true
      recorder.record(entry_attributes)
    rescue StandardError => e
      handle_write_failure(e)
    end

    def entry_attributes
      decision = @decision || Decision.deny(rule: Decision::POLICY_ERROR,
                                            detail: "envelope aborted")
      scope = @scope_result || ScopeResult.deny(rule: decision.rule, detail: decision.detail)

      context.to_h.merge(scope.to_h).merge(
        outcome: decision.outcome.to_s,
        rule: decision.rule,
        detail: decision.detail,
        guard: @guard_label,
        duration_ms: @duration_ms
      )
    end

    def handle_write_failure(error)
      # Never mask an exception already on its way out — the developer needs that one.
      if config.audit_failure_mode == :warn || @in_flight_error
        log("reeve could not record invocation #{context.invocation_id}: #{error.message}")
        return
      end

      raise AuditWriteError.new(invocation_id: context.invocation_id, cause: error)
    end

    def warn_about_unguarded_tool
      log("reeve: #{context.tool_name} has no guard_with declaration and ran unguarded " \
          "(unguarded_tools is :allow_with_warning)")
    end

    def log(message)
      config.logger&.warn(message)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
