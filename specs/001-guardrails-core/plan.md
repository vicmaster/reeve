# Implementation Plan: mcp-guardrails v1 — Authorization, Audit, Testing Kit

**Branch**: `001-guardrails-core` | **Date**: 2026-08-11 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-guardrails-core/spec.md`

## Summary

Ship one Ruby gem, `mcp-guardrails`, that wraps MCP tool execution in a single envelope
enforcing three guarantees: the call runs as an explicit principal and returns only records
that principal may see (deny by default), every call — allowed or denied — appends one
immutable ledger row, and both properties are assertable from the host application's own
test suite. The core depends on no MCP server library and no authorization library;
fast-mcp support ships as a conditionally-loaded adapter, and a plain interface covers
everyone else.

## Technical Context

**Language/Version**: Ruby 3.2+ (gem targets maintained Rubies; CI matrix 3.2 / 3.3 / 3.4)
**Primary Dependencies**: none required at runtime. Optional/soft: ActiveRecord + ActiveSupport
(≥ 7.1, for the ledger and generators), Pundit (policy bridge), fast-mcp (adapter),
RSpec **and** Minitest (testing-kit front-ends). All detected at load, none in
`spec.add_dependency`. The kit's checks are plain Ruby and load neither framework.
**Storage**: host-owned ActiveRecord table `mcp_guardrails_audit_entries`, created by the
install generator; append-only. JSON/JSONB columns for arguments and record identifiers.
**Testing**: RSpec + a dummy Rails app under `spec/dummy` with SQLite for the AR-backed and
generator specs; core unit specs run without Rails.
**Target Platform**: Rails 7.1+ applications exposing MCP tools; also usable as a plain
Ruby library with no Rails present.
**Project Type**: single library (rubygem)
**Performance Goals**: guardrails overhead ≤ 5 ms per invocation excluding the policy's own
queries and the ledger insert; no N+1 introduced by scoping (relation merge, not per-record
reload, for the relation case).
**Constraints**: fail closed on every error path; one ledger row per invocation with no
second code path; core loads with zero optional dependencies present.
**Scale/Scope**: v1 = 3 modules + 1 adapter + 1 generator. Est. ~1500–2500 LOC library,
comparable test volume.

## Constitution Check

*GATE: evaluated before design (below) and re-evaluated after Phase 1 artifacts.*

| Principle | Gate | Status |
|-----------|------|--------|
| I. Deny by Default | Exactly one execution envelope; every error path returns a Deny with a named rule; no tool path bypasses it | ✅ PASS — R1 gives a single funnel; `Decision` requires a rule string |
| II. Every Call Leaves a Trace | One ledger row per invocation, allow and deny; no update/delete API; write failure fails the call by default | ✅ PASS — R5; async writes explicitly excluded from v1 |
| III. Provable by Test | Every authorization/audit behavior expressible via the testing kit; test-first in this repo | ✅ PASS — R8; testing kit is a deliverable module, not an afterthought |
| IV. Extension Layer | No required dependency on any MCP server or policy library; adapters conditionally loaded, in-gem | ✅ PASS — empty runtime dependency list; adapters gated on `defined?` |
| V. Clean-Room Provenance | No code, names, schemas, or docs from any proprietary system | ✅ PASS — table/column/class names below are original; policy-object and ledger patterns are public prior art |
| VI. Boring DX | Three-step adoption; small additive API; errors name principal/tool/rule; runnable examples | ✅ PASS — see quickstart.md; public surface is 1 config block, 3 tool macros, 3 matchers |

**Post-design re-check (after data-model.md, contracts/, quickstart.md)**: ✅ PASS — no new
violations introduced. Complexity Tracking is empty.

One item to watch, not a violation: R4's three result shapes are the largest single source
of accidental complexity in this design. If the Phase 1 design panel finds a way to collapse
"record collection" and "derived value" into one declarative mechanism, take it —
Principle VI favors the smaller surface.

## Project Structure

### Documentation (this feature)

```text
specs/001-guardrails-core/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Technical decisions R1–R10
├── data-model.md        # Entities, ledger schema, state transitions
├── quickstart.md        # The three-step adoption path, end to end
├── contracts/
│   ├── configuration.md     # Public config surface
│   ├── tool-dsl.md          # guard_with / derives_from / redact
│   ├── policy-adapter.md    # The two-method protocol
│   ├── audit-entry.md       # Versioned ledger entry contract
│   └── testing-kit.md       # Matchers + shared compliance suite
└── checklists/
    └── requirements.md  # Spec quality checklist (complete)
```

### Source Code (repository root)

```text
lib/
├── mcp-guardrails.rb                     # gem-name entry point, requires the below
└── mcp/
    └── guardrails/
        ├── version.rb
        ├── configuration.rb              # config object + defaults
        ├── errors.rb                     # DeniedError and friends
        ├── invocation.rb                 # the envelope (R1) — the one funnel
        ├── context.rb                    # per-invocation context; principal carrier
        ├── decision.rb                   # allow/deny + rule (never nil)
        ├── authorization/
        │   ├── guard.rb                  # the tool-side DSL: guard_with, derives_from, redact
        │   ├── registry.rb               # registered guarded tools (feeds the compliance suite)
        │   ├── scoper.rb                 # R4 result-shape dispatch
        │   └── adapters/
        │       ├── plain.rb              # any object answering authorize/scope
        │       └── pundit.rb             # loaded only if Pundit is defined
        ├── audit/
        │   ├── entry.rb                  # AR model, readonly-enforcing
        │   ├── recorder.rb               # builds + writes exactly one entry
        │   ├── redactor.rb               # R6
        │   └── query.rb                  # by principal / agent / tool / outcome / time
        ├── rspec.rb                      # opt-in require: RSpec front-end
        ├── minitest.rb                   # opt-in require: Minitest front-end
        ├── testing/
        │   ├── checks/                   # framework-neutral; ALL the logic lives here
        │   │   ├── cross_principal_leak.rb
        │   │   ├── audit_coverage.rb
        │   │   ├── guard_declared.rb
        │   │   ├── rule_present.rb
        │   │   ├── redaction_holds.rb
        │   │   ├── principal_required.rb
        │   │   ├── contract_version.rb
        │   │   └── result.rb             # Result + Report + run_all
        │   ├── matchers/                 # thin RSpec adapters over the checks
        │   │   ├── deny_access_for.rb
        │   │   └── audit_every_call.rb
        │   ├── compliance_suite.rb       # RSpec shared example group
        │   ├── assertions.rb             # thin Minitest adapters over the checks
        │   └── compliance_assertions.rb  # Minitest compliance module
        ├── fast_mcp.rb                   # opt-in require for the adapter
        └── integrations/
            └── fast_mcp/
                ├── tool_extension.rb     # mixes the DSL into FastMcp::Tool subclasses
                └── context_builder.rb    # server metadata -> Guardrails::Context

lib/generators/mcp_guardrails/
├── install/
│   ├── install_generator.rb
│   └── templates/
│       ├── initializer.rb.tt
│       └── create_audit_entries.rb.tt

spec/
├── unit/                 # core, no Rails required
├── integration/          # envelope end-to-end against the dummy app
├── generators/
├── adapters/fast_mcp/
├── compliance/           # the kit asserting against deliberately-leaky fixtures
└── dummy/                # minimal Rails app: two principals, shared records, 3 tools
```

**Structure Decision**: Single-gem library layout. `lib/mcp/guardrails/` mirrors the three
spec modules one-to-one (`authorization/`, `audit/`, `testing/`), with `invocation.rb`,
`context.rb`, `decision.rb`, `configuration.rb`, and `errors.rb` as the shared kernel all
three depend on. That kernel is deliberately small and is built **before** the three modules
fan out — it is the merge-conflict surface for the Phase 2 parallel batch, so it must be
frozen first. Adapters and the testing-kit front-ends sit behind explicit `require` paths
(`require "mcp/guardrails/fast_mcp"`, `"mcp/guardrails/rspec"`, `"mcp/guardrails/minitest"`)
so the default `require` pulls in nothing optional (Constitution IV). Within the kit, the
`checks/` layer holds all logic and loads no test framework; the RSpec and Minitest layers
are adapters over it, which is what keeps a guarantee from being provable in one framework
only (FR-026).

## Implementation Phasing

Aligned to PROJECT-BRIEF.md's graph-engineering trial. Phase numbers below are the brief's,
not spec-kit's.

- **Kernel first (sequential, not parallelizable)**: `configuration`, `context`, `decision`,
  `errors`, `invocation`, plus the gemspec/CI skeleton. Everything else depends on these
  contracts; parallelizing them would manufacture the merge hell the trial is measuring.
- **Phase 2 parallel batch (3 worktrees, one per module)**:
  1. `authorization/` — guard DSL, registry, scoper, policy adapters
  2. `audit/` — entry model, recorder, redactor, query, migration template
  3. `testing/` — matchers, compliance suite, leaky fixtures
  Each module owns disjoint files and depends only on the frozen kernel. Shared touchpoints
  are limited to `configuration.rb` (each module appends its own settings) — a known,
  small, expected conflict site.
- **Integration last (sequential)**: fast-mcp adapter, install generator, dummy app wiring,
  README. These consume all three modules and are the natural place to discover contract
  drift.
- **Review gate**: `/code-review` before each worktree merge (Constitution: Review gate).

## Risks

| Risk | Mitigation |
|------|------------|
| Kernel contracts wrong → all three parallel branches churn | Freeze kernel + `contracts/*.md` before the batch; treat a kernel change mid-batch as a stop-the-line event |
| fast-mcp in-tool request context undocumented (research R2 OPEN) | Adapter is last and isolated; the resolver contract is unaffected either way; fall back to server-level context injection |
| R4's three result shapes leak complexity into the public DSL | Flagged for the Phase 1 design panel; prefer any collapse it finds |
| Synchronous ledger write adds latency to every call | Measured against the 5 ms budget in an integration spec; async is a post-v1 decision that would require re-opening FR-012 |
| Immutability claims overstated | Documented honestly: library-level enforcement plus a DB-grant recommendation, no claim to stop raw SQL |

## Complexity Tracking

No constitution violations to justify. Table intentionally empty.
