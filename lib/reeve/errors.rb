# frozen_string_literal: true

module Reeve
  # Base class for everything reeve raises. Hosts can rescue this one class.
  class Error < StandardError; end

  # Raised when reeve is asked to run with a configuration it cannot honour.
  class ConfigurationError < Error; end

  # Raised when a guarded invocation is denied.
  #
  # The message names the tool, the principal and the rule, because the first question
  # a developer asks is "which rule stopped this, and for whom?" (Constitution VI).
  # It deliberately never names a record: see .out_of_scope.
  class DeniedError < Error
    attr_reader :tool_name, :principal_id, :rule, :detail

    def self.from(decision, tool_name:, principal_id:)
      unless decision.denied?
        raise ArgumentError, "cannot build a DeniedError from an allow decision (#{decision})"
      end

      new(
        tool_name: tool_name,
        principal_id: principal_id,
        rule: decision.rule,
        detail: decision.detail
      )
    end

    # FR-006. Fetching a record outside the principal's scope must be indistinguishable
    # from fetching one that does not exist, so this builder accepts no record at all —
    # there is nothing to leak, by construction rather than by discipline.
    def self.out_of_scope(tool_name:, principal_id:)
      new(
        tool_name: tool_name,
        principal_id: principal_id,
        rule: Decision::OUT_OF_SCOPE_RECORD,
        detail: "the requested record is not within this principal's scope"
      )
    end

    def initialize(tool_name:, principal_id:, rule:, detail: nil)
      @tool_name    = tool_name&.to_s
      @principal_id = principal_id&.to_s
      @rule         = rule.to_s
      @detail       = detail&.to_s
      super(build_message)
    end

    private

    def build_message
      principal = principal_id.nil? ? "no principal" : "principal #{principal_id}"
      base = "reeve denied #{tool_name} for #{principal}: #{rule}"
      detail.nil? ? base : "#{base} (#{detail})"
    end
  end

  # Raised when the ledger write fails and audit_failure_mode is :fail (FR-012).
  #
  # It carries a rule like any other denial, because the failure is not recorded anywhere
  # else: the ledger is the thing that failed, so there is no row to read afterwards. The
  # exception is the only artifact, and a host matching on rules can match on this one.
  class AuditWriteError < Error
    attr_reader :invocation_id, :original_error, :rule

    def initialize(invocation_id:, cause: nil)
      @invocation_id  = invocation_id&.to_s
      @original_error = cause
      @rule           = Decision::AUDIT_WRITE_FAILED
      message = "reeve could not record invocation #{@invocation_id}"
      message = "#{message}: #{cause.message}" if cause
      super(message)
    end
  end
end
