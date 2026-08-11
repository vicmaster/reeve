# frozen_string_literal: true

# Reeve — per-record authorization and an append-only audit ledger for MCP tools.
module Reeve
  # Process-wide settings. See contracts/configuration.md.
  #
  # Every setting validates at assignment rather than at use: a typo in an initializer
  # should fail on the line that caused it, not three weeks later inside a denial path.
  # The one deliberate exception is +principal_resolver+, which may be nil — the library
  # stays loadable in contexts that never invoke a tool, and denies every call until the
  # host sets one (SC-008).
  class Configuration
    UNGUARDED_TOOL_MODES = %i[deny allow_with_warning].freeze
    AUDIT_FAILURE_MODES  = %i[fail warn].freeze
    POLICY_ADAPTERS      = %i[auto pundit plain].freeze

    DEFAULT_REDACTED_ARGUMENTS = %i[
      password password_confirmation passwd secret token access_token refresh_token
      api_key private_key authorization ssn credit_card card_number cvv pin
    ].freeze

    DEFAULT_MAX_RECORDED_IDS = 1000

    SETTINGS = %i[
      principal_resolver unguarded_tools audit_failure_mode redact_arguments
      max_recorded_ids policy_adapter default_action audit_recorder logger
      compliance_principals
    ].freeze

    attr_reader(*SETTINGS)

    def initialize
      @principal_resolver = nil
      @unguarded_tools    = :deny
      @audit_failure_mode = :fail
      @redact_arguments   = DEFAULT_REDACTED_ARGUMENTS.dup
      @max_recorded_ids   = DEFAULT_MAX_RECORDED_IDS
      @policy_adapter     = :auto
      @default_action     = :index
      @audit_recorder     = nil
      @logger             = nil
      @compliance_principals = nil
    end

    # Two fixture principals with disjoint records — the only host setup the compliance
    # suite needs (contracts/testing-kit.md). A callable rather than a value, because in a
    # Rails test suite the fixtures do not exist yet when the helper is loaded.
    def compliance_principals=(principals)
      unless principals.nil? || principals.respond_to?(:call) || principals.is_a?(Array)
        raise ArgumentError,
              "compliance_principals must be an Array or a callable returning one, " \
              "got #{principals.inspect}"
      end

      @compliance_principals = principals
    end

    def unguarded_tools=(mode)
      @unguarded_tools = require_one_of!(:unguarded_tools, mode, UNGUARDED_TOOL_MODES)
    end

    def audit_failure_mode=(mode)
      @audit_failure_mode = require_one_of!(:audit_failure_mode, mode, AUDIT_FAILURE_MODES)
    end

    def max_recorded_ids=(limit)
      unless limit.is_a?(Integer) && limit.positive?
        raise ArgumentError, "max_recorded_ids must be a positive Integer, got #{limit.inspect}"
      end

      @max_recorded_ids = limit
    end

    def principal_resolver=(resolver)
      unless resolver.nil? || resolver.respond_to?(:call)
        raise ArgumentError,
              "principal_resolver must respond to #call (it receives a Reeve::Context), " \
              "got #{resolver.inspect}"
      end

      @principal_resolver = resolver
    end

    def policy_adapter=(adapter)
      @policy_adapter =
        if adapter.is_a?(Symbol) || adapter.is_a?(String)
          require_one_of!(:policy_adapter, adapter, POLICY_ADAPTERS)
        else
          require_protocol!(:policy_adapter, adapter, %i[authorize scope])
        end
    end

    def redact_arguments=(names)
      unless names.is_a?(Array)
        raise ArgumentError, "redact_arguments must be an Array of names, got #{names.inspect}"
      end

      @redact_arguments = names.map(&:to_sym)
    end

    def default_action=(action)
      if action.nil? || action.to_s.strip.empty?
        raise ArgumentError,
              "default_action must be a non-blank policy action, got #{action.inspect}"
      end

      @default_action = action.to_sym
    end

    def audit_recorder=(recorder)
      @audit_recorder =
        recorder.nil? ? nil : require_protocol!(:audit_recorder, recorder, [:record])
    end

    def logger=(logger)
      @logger = logger.nil? ? nil : require_protocol!(:logger, logger, [:warn])
    end

    def to_h
      SETTINGS.to_h { |setting| [setting, public_send(setting)] }
    end

    private

    def require_one_of!(setting, value, allowed)
      symbol = value.is_a?(Symbol) ? value : nil
      return symbol if allowed.include?(symbol)

      raise ArgumentError,
            "#{setting} must be one of #{allowed.map(&:inspect).join(', ')}, got #{value.inspect}"
    end

    def require_protocol!(setting, object, methods)
      missing = methods.reject { |method| object.respond_to?(method) }
      return object if missing.empty?

      raise ArgumentError,
            "#{setting} must respond to #{missing.map { |m| "##{m}" }.join(', ')} " \
            "(got #{object.inspect})"
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield(config)
      config
    end

    # Public so host test suites can isolate examples from one another.
    def reset_configuration!
      @config = Configuration.new
    end
  end
end
