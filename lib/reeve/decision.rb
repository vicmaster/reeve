# frozen_string_literal: true

module Reeve
  # The result of a policy evaluation: an outcome, and the rule that produced it.
  #
  # A decision without a rule is not a decision — Constitution II requires every ledger
  # entry to name what decided, so the rule is validated here rather than at write time.
  # Immutable and comparable by value.
  class Decision
    NO_GUARD_DECLARED       = "no_guard_declared"
    NO_PRINCIPAL            = "no_principal"
    POLICY_ERROR            = "policy_error"
    UNKNOWN_RECORD_TYPE     = "unknown_record_type"
    UNSCOPED_DERIVED_RESULT = "unscoped_derived_result"
    OUT_OF_SCOPE_RECORD     = "out_of_scope_record"
    AUDIT_WRITE_FAILED      = "audit_write_failed"
    # An allowed invocation whose tool body raised. No records reached the agent, so the
    # ledger records it as a deny — the trace of a call that blew up is the one most
    # worth having (R5).
    TOOL_ERROR              = "tool_error"

    # The one reserved *allow* rule: a tool with no guard, permitted because the host
    # opted into :allow_with_warning. Kept out of RESERVED_RULES, which names deny paths.
    UNGUARDED_TOOL          = "unguarded_tool"

    # Stable strings. The testing kit and host applications match on them, so a rename
    # here is a breaking change.
    RESERVED_RULES = [
      NO_GUARD_DECLARED,
      NO_PRINCIPAL,
      POLICY_ERROR,
      UNKNOWN_RECORD_TYPE,
      UNSCOPED_DERIVED_RESULT,
      OUT_OF_SCOPE_RECORD,
      AUDIT_WRITE_FAILED,
      TOOL_ERROR
    ].freeze

    OUTCOMES = %i[allow deny].freeze

    attr_reader :outcome, :rule, :detail

    def self.allow(rule:, detail: nil)
      new(outcome: :allow, rule: rule, detail: detail)
    end

    def self.deny(rule:, detail: nil)
      new(outcome: :deny, rule: rule, detail: detail)
    end

    def initialize(outcome:, rule:, detail: nil)
      @outcome = validate_outcome(outcome)
      @rule    = validate_rule(rule)
      @detail  = detail&.to_s
      freeze
    end

    def allowed?
      outcome == :allow
    end

    def denied?
      outcome == :deny
    end

    # True when the rule came from reeve itself rather than from a host policy.
    def reserved_rule?
      RESERVED_RULES.include?(rule)
    end

    def to_h
      { outcome: outcome.to_s, rule: rule, detail: detail }
    end

    def ==(other)
      other.is_a?(Decision) &&
        other.outcome == outcome &&
        other.rule == rule &&
        other.detail == detail
    end
    alias eql? ==

    def hash
      [self.class, outcome, rule, detail].hash
    end

    def to_s
      "#{outcome}(#{rule})"
    end

    def inspect
      "#<Reeve::Decision #{outcome} rule=#{rule.inspect} detail=#{detail.inspect}>"
    end

    private

    def validate_outcome(outcome)
      symbol = outcome.respond_to?(:to_sym) ? outcome.to_sym : outcome
      return symbol if OUTCOMES.include?(symbol)

      raise ArgumentError, "outcome must be :allow or :deny, got #{outcome.inspect}"
    end

    def validate_rule(rule)
      string = rule&.to_s
      return string.freeze unless string.nil? || string.strip.empty?

      raise ArgumentError, "rule is required and may not be blank (got #{rule.inspect})"
    end
  end
end
