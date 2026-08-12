# Changelog

All notable changes are recorded here. This project follows [Semantic
Versioning](https://semver.org), with one rule specific to what it does — see
[Versioning policy](#versioning-policy).

## [Unreleased]

### Added

- README: **Wrapping your own JSON-RPC server** — the integration path for a Rails app
  that already exposes `/mcp` from its own controller and tool registry. Covers mapping
  JSON-RPC tool names to `Reeve.invoke`, passing request headers as `metadata`, resolving
  the principal from `Current.user` or a bearer token while keeping the host's existing
  authentication, adopting one tool at a time through `:allow_with_warning`, and pointing
  the compliance checks at the host's own dispatcher. The recipe is executed by
  `spec/reeve/integrations/custom_dispatcher_spec.rb` rather than only written down.
  ([#5](https://github.com/vicmaster/reeve/issues/5))

### Fixed

- `metadata` passed to `Reeve.invoke` is written to the ledger. The column, the recorder
  mapping and the contract check all existed, but `Context#to_h` did not carry the value,
  so `metadata` was NULL on every call ever recorded — including the header hash the
  fast-mcp adapter collects. It is redacted on the way in, by the same redactor and the
  same declared names as the arguments, so `Authorization` does not land in the ledger.

- A Pundit policy that inherits its `Scope` from a base policy (`class LeadPolicy <
  LeadBasePolicy`) is now recognised. Policy detection looked only at the policy's own
  namespace, so the ordinary Pundit inheritance pattern was refused at declaration time
  with `ConfigurationError`. Detection now walks the policy's ancestry, stopping before
  `Object` so a top-level `Scope` constant still cannot make an unrelated class look
  Pundit-shaped. ([#3](https://github.com/vicmaster/reeve/issues/3))
- `lib/reeve.rb` no longer describes the kernel as unreleased work in progress. The note
  belonged to the 0.0.1 name-claim release and contradicted 0.1.0 for anyone reading the
  installed gem. ([#4](https://github.com/vicmaster/reeve/issues/4))
- The README compliance specs read the file as UTF-8. Under a POSIX locale they read it
  as US-ASCII and every example failed on the first em dash, so the guarantees they
  exist to enforce were never actually checked.

## [0.1.0] - 2026-08-11

First working release. The published 0.0.1 was a placeholder holding the gem name.

### Added

**Authorization**

- `guard_with SomePolicy` declares the policy governing a tool. A tool without one is
  denied (`no_guard_declared`) unless the host opts into `unguarded_tools =
  :allow_with_warning`, which runs the tool unscoped and records `guard: "none"`.
- `redact :argument_name` keeps an argument's value out of the ledger while keeping its
  name.
- `scoped(Model)` returns the policy-scoped relation inside a tool body. It is how a
  guarded tool returns anything that is not a record: a count or a summary computed from
  `scoped(...)` is safe because the tool never held unscoped data. A derived value
  returned without it is denied (`unscoped_derived_result`).
- Policy adapters for plain objects and for Pundit, behind one two-method protocol
  (`authorize`, `scope`). `:auto` picks one and reports which through
  `Reeve.config.resolved_policy_adapter`. Neither Pundit nor any authorization library is
  a runtime dependency.
- Per-record scoping for relations, arrays, single records, mixed types and derived
  values. A single record outside the principal's scope is refused without naming it.

**Audit**

- One append-only `reeve_audit_entries` row per invocation, allowed or denied, recording
  the agent, the principal, the tool, post-redaction arguments, returned identifiers, the
  outcome, the rule that decided, and why it decided (`detail`).
- The write happens in its own transaction, so a tool that raises and rolls back its own
  work still leaves a trace — the invocations most worth recording are the ones that
  failed.
- A failed ledger write fails the invocation. `audit_failure_mode = :warn` degrades that
  deliberately and must be opted into.
- `Reeve::Audit::Query` queries the ledger by principal, agent, tool, outcome and time
  range.
- Entries are read-only after insert and refuse to be destroyed; the generated migration
  documents the `GRANT INSERT, SELECT` that enforces what a library cannot.

**Testing kit**

- Seven framework-neutral checks (`CrossPrincipalLeak`, `AuditCoverage`, `GuardDeclared`,
  `RulePresent`, `RedactionHolds`, `PrincipalRequired`, `ContractVersion`) plus
  `Checks.run_all`, all plain Ruby that loads no test framework.
- RSpec front-end (`require "reeve/rspec"`): `deny_access_for`, `audit_every_call`,
  `pass_reeve_check`, and the `"a reeve-compliant server"` shared example group.
- Minitest front-end (`require "reeve/minitest"`): the same guarantees from a stock
  `rails new` application, with no RSpec installed.
- Failure messages are built by the checks, so all three front-ends emit identical text.

**Adoption**

- `rails generate reeve:install` writes the initializer and the ledger migration.
  `principal_resolver` ships as a TODO, because it is the one thing only the host can
  answer, and reeve denies every call until it is filled in.
- fast-mcp adapter (`require "reeve/fast_mcp"`): the DSL on every tool and the envelope
  around every call, with the principal resolved from the request's headers. Needs Ruby
  3.1+, because fast-mcp does.
- `Reeve.invoke` gives the same guarantees with no Rails, no ActiveRecord and no MCP
  server library.

### Known limitations

Stated here because finding them yourself later is worse than reading them now.

- **A transaction the host wraps around an invocation takes the ledger row with it.** The
  recorder writes in a savepoint, which protects the trace from a transaction the *tool*
  opens and rolls back, but not from one already open around the whole call — a controller
  that wraps each request, or a test suite using transactional fixtures. Reeve detects this
  and warns, naming the invocation. Real isolation needs a second connection and is not
  portable: on SQLite the enclosing transaction holds the write lock and a second
  connection times out. Hosts needing durability there supply their own `audit_recorder`.
- **An unscoped fetch by id still discloses existence.** `Invoice.find_by(id:)` denies for
  a record that exists but belongs to someone else, and returns `nil` for one that does not
  exist. Fetching through `scoped(...)` makes both answers `nil`.
- **A scope-less type must be tied to its policy.** A plain object with an `id` is a
  record, but a type with no relation cannot be checked against a policy scope — only
  against `authorize`, which is often permissive. Such a type is trusted when a policy is
  named for it or a `scoped(...)` call establishes provenance, and denied otherwise.
- **A call that cannot be recorded fails, even when it was already failing.** An
  unrecordable denial raises `AuditWriteError` carrying the denial as `#during`, rather
  than the denial itself. With no recorder configured at all, that is the first thing you
  will see, and it names the missing ledger.
- **`AuditCoverage` proves one invocation is recorded**, not every invocation.
- **The fast-mcp adapter needs Ruby 3.1+**, because fast-mcp depends on dry-schema. The
  core supports 3.0.
- CI runs SQLite only; MySQL and PostgreSQL rest on ActiveRecord's portability.

### Notes

- Ruby 3.0+, Rails 7.0+, zero runtime dependencies.
- Publishing requires MFA on the owner's account (`rubygems_mfa_required`).

## [0.0.1] - 2026-08-11

- Placeholder release reserving the gem name. No functionality.

## Versioning policy

Semantic versioning, with one project-specific rule that follows from what this library
is for:

- **A change that narrows what a tool returns is a security fix and may ship in a patch.**
  If reeve was letting a record through that a policy did not permit, closing that is not
  a breaking change, however much it changes behaviour for someone relying on it.
- **A change that widens access is breaking by definition** — major version, plus a
  migration note saying exactly what became visible that was not visible before.
- Adding a nullable ledger column is minor and leaves the audit-entry contract version
  alone. Removing or renaming a column, or changing what a value means, is major and bumps
  it.
- The audit-entry contract version is `1`.
