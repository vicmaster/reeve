# Changelog

All notable changes are recorded here. This project follows [Semantic
Versioning](https://semver.org), with one rule specific to what it does — see
[Versioning policy](#versioning-policy).

## [Unreleased]

### Added

- **`bin/rails generate reeve:upgrade`** — brings an existing ledger up to the current
  audit-entry contract. It asks the table which columns it has and emits only the steps
  that are missing, so it is a no-op on a current ledger and safe to run twice before
  migrating. Replaces the hand-written `add_column` the 0.2.0 notes had to give.
  ([#11](https://github.com/vicmaster/reeve/issues/11))
- `contracts/audit-entry.md` states the rule the upgrade path depends on: **changes to the
  table must be additive**, and a new column must be nullable or carry a default that is
  true of the rows already written. An append-only ledger has no honest value to backfill
  into a historical row. A change that cannot be expressed additively is a new table, not
  a new version of this one.

### Fixed

- `Checks::ContractVersion` names `reeve:upgrade` when the table is missing a column. It
  said `reeve:install`, which is wrong for exactly the case it fires in: the table exists,
  so Rails resolves that migration by name and either emits nothing or offers to overwrite
  one that has already run — which does not touch the database and destroys the record of
  what was applied. The install generator now says the same thing on its way out.

## [0.2.0] - 2026-08-12

Everything here came out of running 0.1.0 against a real Rails 8.1 application rather than
against its own test suite. The Pundit fix is the one that blocks adoption.

**Audit-entry contract version: `1` → `2`.** Two changes, one bump.

`metadata` was written NULL on every row through version 1 and now carries what the caller
passed. Anything mapping version 1 rows could reasonably have read that column as always
empty, and this project's own versioning rule calls a change in what a value means MAJOR —
hence 0.2.0 rather than a patch.

New non-null `contract_version` column, stamped on every row. Version 1 rows could not
name their own shape, which is exactly what made the `metadata` change ambiguous to a
reader: on a version 1 row a NULL `metadata` means "never recorded", on a version 2 row it
means "the caller passed none". Stamping the row settles that at read time instead of
requiring a reader to know when the writing gem was deployed, and it makes every future
bump legible on the row. It also gives `Checks::ContractVersion` real teeth — a stale
table now fails on the missing column even when a bump was purely semantic.

**Upgrading from 0.1.0:**

- Re-run `bin/rails generate reeve:install` and migrate, or add the column by hand:
  `add_column :reeve_audit_entries, :contract_version, :integer, null: false, default: 1`
  — `default: 1` is correct for existing rows, since that is the contract they were
  written under. Drop the default afterwards if you prefer; the recorder always sets it.
- A host pinning `Reeve::Checks::ContractVersion.new(expected: 1)` moves it to `2`.
- **A custom `audit_recorder` that writes to `Reeve::Audit::Entry` must now set
  `contract_version`.** The model rejects a row without it.

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
  This is the change behind the contract-version bump above.
- `contracts/audit-entry.md` no longer claims the contract version is "recorded in the
  initializer". It never was — which is what prompted the `contract_version` column above,
  so that from contract 2 the claim is simply true.
- The envelope-overhead spec compares the fastest call on each side rather than the mean
  of two separately-timed windows. A single GC pause or scheduler preemption landing in
  one window and not the other lands whole in the difference — 300ms over fifty runs is
  6ms per call against a 5ms budget, from a busy machine rather than a regression. It
  loses no sensitivity: a regression is paid on every call, so it slows the fastest trial
  too. Verified both ways — an injected one-off stall moves the measurement from 6.65ms to
  0.23ms, and 6ms added to every call still fails at 7.13ms.
- The spec suite declares UTF-8 (`spec/spec_helper.rb`). The README-spec encoding bug was
  one instance of five: eleven examples across `readme_spec`, `contract_version_spec`,
  `migration_spec`, `install_generator_spec`, `framework_neutrality_spec`,
  `isolation_spec` and `verification_spec` died on `invalid byte sequence` whenever a file
  was run on its own, and passed in a full run only because some other file happened to
  set the encoding first. Every spec file now passes in isolation, and the suite passes
  under `LC_ALL=C`.
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
