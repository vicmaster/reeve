# frozen_string_literal: true

require_relative "../reeve"

begin
  require "active_record"
rescue LoadError => e
  raise Reeve::ConfigurationError,
        "reeve/audit needs activerecord, which could not be loaded (#{e.message}). " \
        "Add activerecord to your Gemfile, or configure a non-ActiveRecord " \
        "Reeve.config.audit_recorder instead."
end

module Reeve
  # The append-only ledger: one row per guarded invocation, allowed or denied
  # (Constitution II, FR-008).
  #
  # This file is the opt-in boundary. `require "reeve"` must keep working in a bare Ruby
  # process with no ActiveRecord (SC-008), so nothing here is loaded by the core — a host
  # (or the generated initializer) requires "reeve/audit" when it wants the table-backed
  # recorder.
  module Audit
    # The version of the audit-entry shape, as documented in
    # specs/001-guardrails-core/contracts/audit-entry.md (FR-015). Adding a nullable
    # column is a MINOR change and leaves this alone; removing or renaming a column, or
    # changing what a value means, is MAJOR and bumps it.
    CONTRACT_VERSION = 1

    TABLE_NAME = "reeve_audit_entries"

    class << self
      # Where per-tool redaction declarations come from: the authorization registry, if
      # the authorization module is loaded. Duck-typed and optional on purpose — the
      # ledger is useful on its own, and a host running audit without guards should get
      # the global redaction list rather than a NameError.
      def guard_registry
        return nil unless defined?(Reeve::Authorization::Registry)

        Reeve::Authorization::Registry
      end

      # contracts/configuration.md documents `audit_recorder` as defaulting to nil, "which
      # resolves to Reeve::Audit::Recorder at invocation time — the default cannot be the
      # constant itself, since the core loads without ActiveRecord". This is that
      # resolution, performed at the first moment the constant is known to exist: the
      # require of this file. A host that named its own recorder keeps it.
      def install!(config = Reeve.config)
        config.audit_recorder ||= Recorder
        config
      end
    end
  end
end

require_relative "audit/redactor"
require_relative "audit/entry"
require_relative "audit/recorder"

Reeve::Audit.install!
