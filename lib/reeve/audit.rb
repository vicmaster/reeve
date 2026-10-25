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
  #
  #   require "reeve/audit"
  #
  #   Reeve::Audit::Query.for_principal(user)
  #                      .for_agent("claude-desktop")
  #                      .between(1.week.ago, Time.current)
  #                      .pluck(:tool_name, :record_type, :record_ids, :outcome, :rule)
  #
  # == What this module guarantees
  #
  # * exactly one row per invocation, allowed or denied — `invocation_id` is unique, and
  #   a replayed invocation is a no-op insert rather than a second row;
  # * `rule` is never null: every row explains itself;
  # * arguments are post-redaction, and no unredacted copy is written anywhere;
  # * `record_count` stays true even when `record_ids` was capped, and `truncated` says so;
  # * `occurred_at` is invocation time, not write time;
  # * no public method updates or deletes an entry.
  #
  # == What it does not
  #
  # * It does not stop a database superuser, a migration, or raw SQL from rewriting the
  #   table. Immutability is enforced at the library level; the generated migration
  #   documents the `GRANT INSERT, SELECT` that enforces the rest where it can actually be
  #   enforced, and the gem makes no stronger claim than that.
  # * No retention, rotation or archival yet — the table is host-owned and the host's
  #   existing policies apply. Deleting rows breaks the chain, by design.
  # * Tamper-evidence, not tamper-proofing. Every row is chained to the one before it
  #   (Reeve::Audit::Chain, contract 3), so a change made outside the library is reported
  #   by verification — after the fact; it prevents nothing. It does not detect a change
  #   made by someone holding the ledger key, the newest rows deleted by a role that can
  #   also rewind the chain record's head, the whole ledger deleted, or anything about
  #   rows written before contract 3. specs/001-guardrails-core/contracts/audit-entry.md,
  #   guarantee 9, is the authoritative statement.
  #
  # ("yet" rather than "in v1": the gem version and the audit-entry contract version are
  # different numbers that move independently, and writing v1 for one of them read as the
  # other.)
  module Audit
    # The version of the audit-entry shape, as documented in
    # specs/001-guardrails-core/contracts/audit-entry.md (FR-015). Adding a nullable
    # column is a MINOR change and leaves this alone — unless what its absence means, or
    # what an existing value covers, differs between rows written before and after it;
    # removing or renaming a column, or changing what a value means, is MAJOR and bumps it.
    #
    # 4 — entries name their key epoch (specs/003). One nullable column, `chain_epoch`, but
    # it is inside the digest, so `chain_digest` on a contract-4 row covers something a
    # contract-3 digest does not, and a NULL epoch means "before key epochs" on a contract-3
    # row where a chained contract-4 row always has one.
    #
    # 3 — entries are chained (specs/002). The three chain columns are nullable, so the
    # shape change is additive, but what a NULL digest means changed: on a contract-3 row
    # it is a row written unchained, which verification reports, where on an older row it
    # only means the row predates chaining.
    #
    # 2 — `metadata` carries the transport detail the caller passed. Through version 1 it
    # was written NULL on every row regardless of what was passed, so anything mapping
    # version 1 rows could reasonably have read the column as "always empty". The shape
    # did not change; what a value means did.
    CONTRACT_VERSION = 4

    TABLE_NAME = "reeve_audit_entries"

    class << self
      # Where per-tool redaction declarations come from: the authorization registry, if
      # the authorization module is loaded. Duck-typed and optional on purpose — the
      # ledger is useful on its own, and a host running audit without guards should get
      # the global redaction list rather than a NameError.
      def guard_registry
        return nil unless Reeve.respond_to?(:registry)

        Reeve.registry
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
require_relative "audit/isolated_recorder"
require_relative "audit/query"
require_relative "audit/chain/keyring"
require_relative "audit/chain/normalizer"
require_relative "audit/chain/canonical"
require_relative "audit/chain_record"
require_relative "audit/chain_epoch"
require_relative "audit/chain/verification"
require_relative "audit/chain/report"
require_relative "audit/chain/head"
require_relative "audit/chain/epochs"
require_relative "audit/chain/rotation"
require_relative "audit/chain/checkpoint"
require_relative "audit/chain/epoch_rules"
require_relative "audit/chain/checkpoint_check"
require_relative "audit/chain/anchoring"
require_relative "audit/chain/schema"
require_relative "audit/chain/walk"
require_relative "audit/chain/verifier"
require_relative "audit/chain"
require_relative "audit/file_anchor"

Reeve::Audit.install!
