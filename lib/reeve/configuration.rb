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
      compliance_principals compliance_tools inventory ledger_key retired_ledger_keys
    ].freeze

    # Shown by #to_h and #inspect as fingerprints. A configuration object gets printed —
    # in a console, a bug report, a failing spec — and a secret must not travel with it.
    SECRET_SETTINGS = %i[ledger_key retired_ledger_keys].freeze

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
      @compliance_tools = nil
      @inventory = nil
      @ledger_key = nil
      @retired_ledger_keys = []
    end

    # The key that signs the audit ledger's chain (specs/002). Held in configuration, never
    # in the database: that separation is the whole of the tamper-evidence guarantee.
    # Validated here so a short key fails on the initializer line that set it.
    #
    #   config.ledger_key = Rails.application.key_generator.generate_key("reeve audit ledger", 32)
    def ledger_key=(secret)
      unless secret.nil?
        LedgerKey.validate!(secret, :ledger_key)
        if @retired_ledger_keys.include?(secret)
          raise ArgumentError, "ledger_key is also listed in retired_ledger_keys; a key " \
                               "either signs or is retired, not both"
        end
      end

      @ledger_key = secret
    end

    # Keys that signed older entries, kept so those entries still verify. Never used to
    # sign. Removing one leaves the entries it signed unverifiable — reported as such,
    # never as tampered.
    def retired_ledger_keys=(secrets)
      unless secrets.is_a?(Array)
        raise ArgumentError, "retired_ledger_keys must be an Array of keys, got a #{secrets.class}"
      end

      secrets.each { |secret| LedgerKey.validate!(secret, :retired_ledger_keys) }
      if !@ledger_key.nil? && secrets.include?(@ledger_key)
        raise ArgumentError, "retired_ledger_keys includes the current ledger_key; a key " \
                             "either signs or is retired, not both"
      end

      @retired_ledger_keys = secrets.dup.freeze
    end

    # The fingerprint stored on every row this configuration signs, or nil with no key.
    def ledger_key_id
      @ledger_key && LedgerKey.fingerprint(@ledger_key)
    end

    # The host's whole tool inventory (Reeve::Inventory). Optional. Setting it is what lets
    # the compliance suite say whether it covered the endpoint or only the tools reeve
    # happened to be told about.
    def inventory=(inventory)
      unless inventory.nil? || inventory.is_a?(Inventory)
        raise ArgumentError, "inventory must be a Reeve::Inventory, got #{inventory.inspect}"
      end

      @inventory = inventory
    end

    # This configuration with the principal fixed for one invocation.
    #
    # An explicitly supplied principal is just a resolver that returns it. Routing it
    # through the same resolution step rather than around it keeps one answer to "where
    # did this principal come from" — the envelope still resolves, records and denies
    # identically, and a nil passed in still denies with `no_principal`.
    def with_principal(principal)
      return self if principal == :unset

      dup.tap { |scoped| scoped.principal_resolver = ->(_context) { principal } }
    end

    # Two fixture principals with disjoint records — the only host setup the compliance
    # suite needs (contracts/testing-kit.md). A callable rather than a value, because in a
    # Rails test suite the fixtures do not exist yet when the helper is loaded.
    # Which tools the compliance suite certifies. Defaults to every tool reeve knows
    # about, which is the answer a finished application wants.
    #
    # A host part-way through a retrofit needs the other answer. Once the suite reports
    # unguarded tools — which is the whole point of it — an application with thirty tools
    # and three guarded ones has a red build it cannot honestly turn green, and a red
    # build that is expected to be red stops being read. Narrowing the list says "these
    # are the ones I have certified", which is a claim that can go green and then stay
    # green as the list grows.
    #
    #   config.compliance_tools = -> { [InvoiceSearchTool, InvoiceShowTool] }
    def compliance_tools=(tools)
      unless tools.nil? || tools.respond_to?(:call) || tools.is_a?(Array)
        raise ArgumentError,
              "compliance_tools must be an Array or a callable returning one, " \
              "got #{tools.inspect}"
      end

      @compliance_tools = tools
    end

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
      SETTINGS.to_h { |setting| [setting, shown(setting)] }
    end

    def inspect
      "#<#{self.class.name} #{to_h.map do |setting, value|
        "#{setting}=#{value.inspect}"
      end.join(', ')}>"
    end

    private

    def shown(setting)
      value = public_send(setting)
      return value unless SECRET_SETTINGS.include?(setting)

      if value.is_a?(Array)
        value.map do |secret|
          LedgerKey.fingerprint(secret)
        end
      else
        value && LedgerKey.fingerprint(value)
      end
    end

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
