# Tasks: reeve v1 — Authorization, Audit, Testing Kit

**Input**: Design documents from `/specs/001-guardrails-core/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: REQUIRED. Constitution Principle III makes this repo test-first — a failing test
that pins the guarantee precedes each implementation task.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 authorization · US2 audit · US3 testing kit · US4 adoption
- **[W#]**: the Phase-2 worktree this task belongs to in the parallel batch

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: A gem skeleton that loads and a CI that runs.

- [ ] T001 Create gem skeleton: `reeve.gemspec` (empty runtime dependency list),
      `lib/reeve.rb`, `lib/reeve/version.rb`, `Gemfile`, `Rakefile`,
      per plan.md structure
- [ ] T002 [P] Add development dependencies in the Gemfile: rspec, minitest, rubocop,
      activerecord, activesupport, sqlite3, pundit, fast-mcp — all development-only, none in
      the gemspec
- [ ] T003 [P] Configure RuboCop (`.rubocop.yml`) and the RSpec harness
      (`spec/spec_helper.rb`) with no Rails required by default
- [ ] T004 [P] Add GitHub Actions CI matrix over Ruby 3.0/3.2/3.4 running specs + RuboCop
- [ ] T005 Add a load-safety spec asserting `require "reeve"` succeeds with no
      ActiveRecord, no Pundit, and no fast-mcp loaded (SC-008) — must fail before T001 lands
- [ ] T006 [P] Claim `reeve` on rubygems.org with a 0.0.1 skeleton release. Verified
      UNCLAIMED 2026-08-11 — it is a short common word with no MCP association, so the
      squat risk is real and this should happen first. Requires Victor's credentials —
      confirm before running

**Checkpoint**: gem loads bare, CI green.

---

## Phase 2: Kernel (Blocking Prerequisites) 🔒

**Purpose**: The contracts all three modules build against. **Sequential and frozen before
the parallel batch** — plan.md treats a kernel change during the batch as stop-the-line.

- [ ] T007 Write specs for `Decision`: allow/deny construction, `rule` required and never
      nil, reserved rule identifiers from data-model.md
- [ ] T008 Implement `lib/reeve/decision.rb` per data-model.md
- [ ] T009 [P] Write specs for `Configuration`: defaults, per-setting validation table in
      contracts/configuration.md, unknown setting raises, re-`configure` overrides
- [ ] T010 Implement `lib/reeve/configuration.rb` + `Reeve.configure`
- [ ] T011 [P] Write specs for `Context`: required/defaulted fields, unknown agent defaults
      to `"unknown"`, nil principal permitted at construction (denial happens in the envelope)
- [ ] T012 Implement `lib/reeve/context.rb`
- [ ] T013 [P] Implement `lib/reeve/errors.rb` — `DeniedError` exposing
      `#tool_name`, `#principal_id`, `#rule`, `#detail`, message naming all four, plus a
      spec asserting the message never reveals record existence (FR-006)
- [ ] T014 Write envelope specs from the data-model.md state diagram: every path terminates
      in exactly one audit write attempt, every deny carries a rule, no path returns records
      without scoping, principal state cleared in `ensure` even when the tool raises
- [ ] T015 Implement `lib/reeve/invocation.rb` — the single funnel: resolve
      principal → look up guard → authorize → execute → scope → record → return/raise.
      Depends on T008, T010, T012, T013. Collaborators (registry, scoper, recorder) are
      injected and null-object-defaulted so the kernel is testable before the modules exist
- [ ] T016 Freeze the kernel: tag the commit and note it in plan.md. Any later change to
      T008/T010/T012/T015 signatures halts the parallel batch

**Checkpoint**: kernel green and frozen. The Phase-2 parallel batch may start.

---

## Phase 3: User Story 1 — Scope every tool call to the acting human (P1) 🎯 MVP · [W1]

**Goal**: A guarded tool returns only records the invoking principal may see; everything
unclear denies.

**Independent Test**: two principals, disjoint records, one guarded tool and one unguarded
tool — each principal sees only their own, the unguarded tool returns nothing.

### Tests first

- [ ] T017 [P] [US1] [W1] Registry specs: declaration at class-definition time, inheritance,
      redeclaration warns, enumerable, resettable
- [ ] T018 [P] [US1] [W1] Guard DSL specs per contracts/tool-dsl.md: `guard_with`,
      `redact`, `scoped`, action override, missing-declaration behavior under both
      `unguarded_tools` settings
- [ ] T019 [P] [US1] [W1] Scoper specs covering every row of the return-value table:
      relation, array of records, single out-of-scope record (denies, no existence leak),
      mixed types, unpoliced type, non-record return without `scoped(...)`, nil/empty (allow, count 0)
- [ ] T020 [P] [US1] [W1] Plain policy adapter specs; declaration-time error when the policy
      object lacks `authorize`/`scope`
- [ ] T021 [P] [US1] [W1] Pundit adapter specs, skipped when Pundit is absent; `:auto`
      resolution reported via `resolved_policy_adapter`
- [ ] T022 [P] [US1] [W1] Acceptance specs for spec.md US1 scenarios 1–6, including
      fail-closed on a raising policy and denial with no resolvable principal

### Implementation

- [ ] T023 [US1] [W1] `lib/reeve/authorization/registry.rb`
- [ ] T024 [US1] [W1] `lib/reeve/authorization/guard.rb` — `guard_with`, `redact`, and the `scoped(Model)` instance helper
- [ ] T025 [US1] [W1] `lib/reeve/authorization/adapters/plain.rb`
- [ ] T026 [US1] [W1] `lib/reeve/authorization/adapters/pundit.rb`, loaded only
      when `defined?(Pundit)`
- [ ] T027 [US1] [W1] `lib/reeve/authorization/scoper.rb` — result-shape dispatch plus `scoped()` usage tracking; a non-record return with no `scoped` call denies (R4)
- [ ] T028 [US1] [W1] Wire registry + scoper + adapter into the envelope's injection points
      (no kernel signature change)
- [ ] T029 [US1] [W1] Concurrency spec: same agent, two principals, interleaved invocations
      across threads — no principal leakage

**Checkpoint**: US1 delivers value alone — scoping works, audit not yet required.

---

## Phase 4: User Story 2 — Answer "why did the AI expose that?" (P2) · [W2]

**Goal**: one immutable ledger row per invocation, queryable along five axes.

**Independent Test**: mixed allowed/denied calls produce one entry each with all required
fields; no library path mutates an entry.

### Tests first

- [ ] T030 [P] [US2] [W2] Entry model specs: readonly after persist, destroy aborts, all
      columns from data-model.md present and typed, `invocation_id` uniqueness
- [ ] T031 [P] [US2] [W2] Recorder specs: exactly one row per invocation for allow and deny,
      `rule` never null, `occurred_at` is invocation time not write time, `guard: "none"`
      under `:allow_with_warning`
- [ ] T032 [P] [US2] [W2] Redactor specs: global + per-tool names, recursive into nested
      hashes, names survive and values do not, no unredacted copy written anywhere (FR-011)
- [ ] T033 [P] [US2] [W2] Truncation specs: over `max_recorded_ids`, `record_count` stays
      true and `truncated` is set (FR-014)
- [ ] T034 [P] [US2] [W2] Failure-mode specs: default `:fail` fails the invocation with rule
      `audit_write_failed`; `:warn` logs and continues (FR-012)
- [ ] T035 [P] [US2] [W2] Query specs for all five axes and their composition (FR-013, SC-003)
- [ ] T036 [P] [US2] [W2] Migration spec: table and every index from data-model.md created,
      migration applies and rolls back cleanly

### Implementation

- [ ] T037 [US2] [W2] `lib/reeve/audit/entry.rb` — AR model with immutability rules
- [ ] T038 [US2] [W2] `lib/reeve/audit/redactor.rb`
- [ ] T039 [US2] [W2] `lib/reeve/audit/recorder.rb` — one write path, synchronous, in an
      `ensure` block **in its own transaction**, so the trace survives a rollback of the
      tool's own work (R5 corrected). Include a spec that raises inside the tool body and
      asserts the ledger row is still there
- [ ] T040 [US2] [W2] `lib/reeve/audit/query.rb`
- [ ] T041 [US2] [W2] Migration template
      `lib/generators/reeve/install/templates/create_audit_entries.rb.tt`
- [ ] T042 [US2] [W2] Record the audit-entry contract version (`1`) in code and assert it
      matches contracts/audit-entry.md (FR-015)
- [ ] T043 [US2] [W2] Document the INSERT+SELECT grant recommendation and the explicit
      non-guarantees from contracts/audit-entry.md

**Checkpoint**: every guarded call is recorded and queryable.

---

## Phase 5: User Story 3 — Prove the guarantees in CI (P3) · [W3]

**Goal**: matchers and a shared suite that fail the build on a leak or an audit bypass.

**Independent Test**: run the kit against one correct tool and two deliberately broken
fixtures; green on the first, red with the right message on each of the others.

### Tests first

- [ ] T044 [P] [US3] [W3] Build the broken fixtures: a cross-principal leaker and an
      envelope-bypassing tool, plus a correct control tool
- [ ] T045 [P] [US3] [W3] Check specs — one per check in the contracts/testing-kit.md table.
      Each returns a `Result` with `passed?`, the exact failure message, and structured
      details; each fails for the right reason on a purpose-built violation (FR-016, FR-017,
      FR-019). Checks load no test framework
- [ ] T046 [P] [US3] [W3] `Checks.run_all` / `Report` specs: every registered guarded tool
      checked, aggregate pass/fail, human-readable report body (FR-018)
- [ ] T047 [P] [US3] [W3] Cross-front-end parity spec: one shared example table drives the
      same fixtures through RSpec, Minitest, and direct plain-Ruby calls; outcomes and
      messages must be identical (SC-009, FR-026)
- [ ] T048 [P] [US3] [W3] Isolation spec: the kit runs with no MCP client, no network, no
      server process — and the checks run with neither RSpec nor Minitest loaded (FR-020)

### Implementation

- [ ] T049 [US3] [W3] `lib/reeve/testing/checks/*.rb` + `Result`/`Report` — the
      seven checks from the contract. All logic and all failure-message construction lives
      here; front-ends add none
- [ ] T050 [US3] [W3] RSpec front-end: `testing/matchers/deny_access_for.rb`,
      `testing/matchers/audit_every_call.rb`, `testing/compliance_suite.rb` shared example
      group, and the `lib/reeve/rspec.rb` entry point
- [ ] T051 [US3] [W3] Minitest front-end: `testing/assertions.rb` +
      `testing/compliance_assertions.rb` and the `lib/reeve/minitest.rb` entry
      point. Acceptance bar: a stock `rails new` app with no RSpec proves every guarantee
- [ ] T052 [US3] [W3] Assert both RSpec and Minitest stay out of the gemspec; document the
      plain-Ruby path (rake task / CI script / boot assertion) with a runnable example

**Checkpoint**: the three modules are complete and independently green. Merge W1→W2→W3 with
`/code-review` before each (Constitution: Review gate).

---

## Phase 6: User Story 4 — Adopt it in minutes (P4) · sequential, post-merge

**Goal**: install generator, fast-mcp adapter, and a dummy app that proves the quickstart.

### Tests first

- [ ] T053 [P] [US4] Generator specs: creates initializer and migration, writes
      `unguarded_tools` explicitly with both options shown, leaves `principal_resolver` as
      a TODO, migration applies cleanly (FR-021, FR-023)
- [ ] T054 [P] [US4] fast-mcp adapter specs: DSL available on `FastMcp::Tool` subclasses,
      context built from server metadata, adapter absent ⇒ core unaffected (FR-022, FR-024)
- [ ] T055 [P] [US4] Plain-interface specs: `Reeve.invoke` gives identical
      guarantees with no Rails and no server library (FR-024, quickstart §"Without Rails")

### Implementation

- [ ] T056 [US4] Resolve research R2 OPEN: verify against the installed fast-mcp gem how a
      tool reaches per-request context; record the finding in research.md. Fall back to
      server-level context injection if in-tool access is unavailable
- [ ] T057 [US4] `lib/reeve/integrations/fast_mcp/context_builder.rb`
- [ ] T058 [US4] `lib/reeve/integrations/fast_mcp/tool_extension.rb` and the
      `lib/reeve/fast_mcp.rb` opt-in entry point
- [ ] T059 [US4] `lib/generators/reeve/install/install_generator.rb` + initializer
      template
- [ ] T060 [US4] Build `spec/dummy` — minimal Rails app, two principals, shared record set,
      three tools (relation-returning, single-record, aggregate via `scoped`)
- [ ] T061 [US4] End-to-end integration spec walking the quickstart exactly as written
      (SC-004, SC-005)

**Checkpoint**: the quickstart is executable, not aspirational.

---

## Phase 7: Polish & Release Readiness

- [ ] T062 [P] README with the positioning line, the three-step quickstart, and a demo GIF
      placeholder (PROJECT-BRIEF launch notes)
- [ ] T063 [P] Runnable example for every public entry point (FR-025, Constitution VI)
- [ ] T064 [P] Performance spec: envelope overhead ≤ 5 ms excluding policy queries and the
      ledger insert; assert scoping adds no N+1 (plan.md Performance Goals)
- [ ] T065 [P] Edge-case sweep — one spec per bullet in spec.md "Edge Cases", each asserting
      a denial or an explicit recorded outcome, never a silent pass (SC-006)
- [ ] T066 [P] Success-criteria audit: map SC-001 … SC-008 to the specs that prove them;
      any unmapped criterion is a gap to close before release
- [ ] T067 Clean-room provenance review before publishing (Constitution V): no proprietary
      names, schemas, or docs anywhere in the repo or its history
- [ ] T068 CHANGELOG, semantic-version policy note, and the 0.1.0 release — push only on
      Victor's explicit confirmation

---

## Dependencies

- **Phase 1 → Phase 2 → {Phase 3, 4, 5} → Phase 6 → Phase 7**
- Phases 3, 4, and 5 are mutually independent **only after T016 (kernel freeze)**. They own
  disjoint files; their sole shared touchpoint is `configuration.rb`, where each appends its
  own settings — a small, expected conflict site.
- Within each phase, the test tasks precede their implementation tasks (Constitution III).
- T006 and T068 both require Victor's confirmation before running.

## Parallel batch mapping (PROJECT-BRIEF Phase 2 trial)

| Worktree | Tasks | Owns |
|----------|-------|------|
| W1 authorization | T017–T029 | `lib/reeve/authorization/**` |
| W2 audit | T030–T043 | `lib/reeve/audit/**`, migration template |
| W3 testing kit | T044–T052 | `lib/reeve/testing/**`, `rspec.rb` |

Each merges independently behind `/code-review`. Success criteria for the trial are fixed in
PROJECT-BRIEF.md: green without merge hell, less wall-clock than sequential, the review gate
catches at least one real issue, quota per shipped feature comparable to normal sessions.

## Implementation strategy

**MVP = Phase 1 + Phase 2 + Phase 3.** That alone delivers the core safety guarantee and is
demonstrable. Audit and the testing kit are each a further independently valuable increment.
Stop after any checkpoint and still have something coherent.
