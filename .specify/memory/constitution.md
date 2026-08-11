<!--
Sync Impact Report
- Version change: (template, unversioned) → 1.0.0
- Ratification: initial adoption 2026-08-11
- Modified principles: none (all six newly defined)
- Added sections:
  - Core Principles I–VI (Deny by Default; Every Call Leaves a Trace;
    Provable by Test; Extension Layer, Never a Competitor; Clean-Room Provenance;
    Boring DX)
  - Additional Constraints (Technology & Compatibility)
  - Development Workflow & Quality Gates
  - Governance
- Removed sections: none
- Template alignment:
  - ✅ .specify/templates/plan-template.md — generic "Constitution Check" gate;
    no edits required, gates resolve against this file at plan time
  - ✅ .specify/templates/spec-template.md — no constitution-driven mandatory
    sections added or removed
  - ✅ .specify/templates/tasks-template.md — task categories already cover
    testing/documentation; audit + authorization tasks are feature-level
  - ✅ .claude/commands/speckit.*.md — no outdated agent-specific references
- Deferred TODOs: none

Amendment note (2026-08-11): Principle V previously named a specific proprietary system.
Generalized to "any employer or client codebase" before the repository was published —
the principle is unchanged and states better without the name.

Amendment 1.0.1 (2026-08-11) — PATCH, naming and platform floor only:
- Project renamed `mcp-guardrails` → `reeve`. Rationale: "MCP" and "guardrails" are
  saturated terms, and `MCP::Guardrails` would have reopened the official `mcp` gem's
  top-level namespace. `reeve` — an official acting with delegated authority on behalf
  of another — names the principal/agent relationship the gem governs.
- Platform floor lowered from Ruby 3.2 / Rails 7.1 to Ruby 3.0 / Rails 7.0, to reach more
  of the Rails install base. README states that maintained Rails is assumed for anything
  security-relevant.
- No principle added, removed, or redefined; governance unchanged.
-->

# reeve Constitution

reeve is a Ruby gem that makes it safe for a Rails application to expose MCP
tools to AI agents: per-record authorization, an append-only audit trail, and a testing
kit that proves both hold. Authentication says who is at the door; this gem decides what
they may touch and remembers what they touched.

## Core Principles

### I. Deny by Default (NON-NEGOTIABLE)

Every tool invocation runs as an explicit *principal* — the human on whose behalf the
agent acts. A tool with no `guard_with` declaration, a call with no resolvable principal,
or a policy that raises MUST fail closed and return no records. Record access is filtered
through the principal's policy scope; a tool MUST NOT return a record the principal could
not see through the host application's own authorization layer. Silent widening of scope
is a defect of the highest severity, and any such report is treated as a security bug.

*Rationale*: An agent is an amplifier. A permissive default that a human would notice in
one request becomes thousands of unnoticed exposures under an agent.

### II. Every Call Leaves a Trace

Every guarded invocation MUST append one ledger entry recording, at minimum: agent,
principal, tool, arguments, identifiers of records returned, the allow/deny outcome, and
the specific rule that produced it. The ledger is append-only: the library exposes no
update or delete API for entries, and both allowed and denied calls are recorded. Audit
writes MUST NOT be silently swallowed — a failure to record is a failure of the call,
unless the host has explicitly opted into a degraded mode.

*Rationale*: The question after an incident is "why did the AI expose that?" That must be
answerable with a query, not an inference from application logs.

### III. Provable by Test (NON-NEGOTIABLE)

Guarantees ship with the assertions that prove them. Every authorization or audit
behavior MUST be expressible as a check a host application can run in its own CI via the
testing kit (RSpec matchers plus a shared compliance suite). Within this repository,
behavior is developed test-first: a failing test that pins the guarantee precedes the
implementation, and no authorization or audit change merges without a test that fails
before it and passes after.

*Rationale*: A guardrail nobody can assert on is a promise. The testing kit is the
product, not an accessory to it.

### IV. Extension Layer, Never a Competitor

The gem rides the existing Ruby MCP stack (official `mcp` SDK, fast-mcp, ActionMCP) and
competes with none of it. The core MUST remain independent of any single server library;
integrations live inside this gem as conditionally-loaded adapters
(`require "reeve/fast_mcp"`), never as hard dependencies and never as separate
gems until an adapter grows genuine independent surface. Any proposed scope MUST be
positioning-checked against existing gems before it is built; duplicating a healthy
upstream feature is out of scope by default.

*Rationale*: The addressable market is the union of those ecosystems' users. Re-solving
protocol plumbing forfeits that and picks fights with maintainers who are natural
amplifiers.

### V. Clean-Room Provenance (NON-NEGOTIABLE)

This gem is written clean-room with respect to any employer or client codebase. No code,
class or method names, database schemas, migration structures, configuration shapes, or
copied documentation from such a system may enter this repository. General,
publicly-known patterns — policy objects, scopes, ledger tables — are permitted and MUST
be independently expressed.

*Rationale*: The gem's value is that it can be published and adopted freely. A single
provenance question would end that permanently.

### VI. Boring DX

Adoption is three steps and no surprises: `bundle add reeve` →
`rails g reeve:install` (initializer plus audit migration) → `guard_with
SomePolicy` in a tool. Public API surface stays small and additive; new configuration
requires a demonstrated need, not an anticipated one. Errors name the principal, the
tool, and the rule that denied the call. Every public entry point ships with a runnable
example in the README or gem documentation.

*Rationale*: "Devise made Rails authentication boring; reeve makes agent access
boring." Boring is the feature — a guardrail that is fiddly to adopt does not get adopted.

## Additional Constraints (Technology & Compatibility)

- **Language/runtime**: Ruby gem targeting Ruby 3.0+ and Rails 7.0+;
  Rails-facing code (generators, migrations, ActiveRecord integration) MUST be optional
  at load time so the core can be exercised without a full Rails boot.
- **Dependencies**: The core has no required dependency on any MCP server gem, on Pundit,
  or on any specific authorization library. Pundit is a supported bridge, not a
  requirement; plain policy objects MUST work.
- **Packaging**: One gem. Adapters are conditionally-loaded files, gated on the host
  library being present, and each adapter's absence MUST NOT break the others.
- **Data**: The audit ledger is a host-owned table created by a generated migration. The
  gem MUST NOT require a specific database engine beyond what ActiveRecord supports.
- **Versioning**: Semantic versioning. Any change that narrows what a tool returns is a
  security fix and may ship in a patch; any change that widens access is breaking by
  definition and requires a major version plus a migration note.

## Development Workflow & Quality Gates

- **Spec-driven**: Work flows constitution → spec → plan → tasks → implementation. Code
  that has no corresponding task in an approved plan does not get written.
- **Story-by-story delivery** with commit checkpoints. Pushes are confirmed with the
  maintainer before they happen. Commits never include `Co-Authored-By` lines.
- **Review gate**: `/code-review` runs before any branch merges, including work produced
  by parallel agents in isolated worktrees. Agent-produced branches are reviewed to the
  same standard as a teammate's pull request — no auto-merge.
- **Cost discipline**: Estimated token cost is announced and approved BEFORE any
  multi-agent workflow is launched. No deep-research runs and no large fan-outs; research
  uses direct web search or a single agent at most.
- **Definition of done** for any feature touching authorization or audit: tests pass,
  the behavior is assertable through the testing kit, the audit entry shape is documented,
  and the README example still runs.

## Governance

This constitution supersedes ad-hoc practice within this repository. When a plan, task,
or review conflicts with it, the constitution wins and the conflicting artifact is
amended.

**Amendment procedure**: Amendments are proposed as an edit to this file with a rationale,
approved by the maintainer (Victor Velazquez), and applied together with any dependent
template or documentation updates in the same change.

**Versioning policy**: MAJOR for backward-incompatible removal or redefinition of a
principle or governance rule; MINOR for a new principle or materially expanded guidance;
PATCH for clarifications and wording. The Sync Impact Report at the top of this file is
updated on every amendment.

**Compliance review**: Every plan produced by `/speckit.plan` runs a Constitution Check
against these principles before and after design. Every review verifies Principles I, II,
III, and V explicitly; a violation of any NON-NEGOTIABLE principle blocks the merge.
Complexity that appears to violate Principle IV or VI must be justified in the plan's
Complexity Tracking section or removed.

**Version**: 1.0.1 | **Ratified**: 2026-08-11 | **Last Amended**: 2026-08-11
