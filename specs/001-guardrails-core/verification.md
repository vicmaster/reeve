# Verification: which spec proves which criterion

**Date**: 2026-08-11 | **Feature**: 001-guardrails-core | **Task**: T066

Every success criterion in spec.md, mapped to the spec that proves it. Where a criterion
is only partly proven, that is stated here rather than left for a reader to discover.
`spec/reeve/verification_spec.rb` asserts that every file named below exists, so this
table cannot rot silently as files move.

## Success criteria

| ID | Criterion | Proven by | Status |
|----|-----------|-----------|--------|
| SC-001 | 100% of guarded invocations return only the invoking principal's records, over every tool and both principals | `spec/reeve/authorization/acceptance_spec.rb`, `spec/dummy/quickstart.rb` (three tool shapes, two principals) | ✅ |
| SC-002 | 100% of invocations — allowed and denied — appear in the ledger; none complete unrecorded in default mode | `spec/reeve/invocation_spec.rb` ("exactly one ledger entry per invocation", six paths), `spec/reeve/integration_spec.rb` | ✅ |
| SC-003 | A reviewer answers "which records did this agent expose for this person last week, under what rule?" in one query | `spec/reeve/audit/query_spec.rb`, `spec/reeve/integration_spec.rb` ("is queryable along the axes an incident is investigated by") | ✅ |
| SC-004 | Install, migrate and guard a first tool in under 15 minutes from documentation alone | `spec/reeve/quickstart_spec.rb` — the documented steps execute in order against a booted Rails app | ⚠️ Executability proven; the 15-minute figure is a human-factors claim no spec can make |
| SC-005 | Guarding an existing tool takes exactly one added declaration and no change to the tool's own logic | `spec/dummy/app/tools.rb` (one `guard_with` line per tool, bodies unchanged), `spec/reeve/integrations/fast_mcp_spec.rb` | ✅ |
| SC-006 | Every edge case produces a denial, never a silent pass — a test per case | `spec/reeve/edge_cases_spec.rb` — one example per bullet, in spec.md's order | ⚠️ One case is a documented limitation rather than a denial: see "Existence disclosure" below |
| SC-007 | The kit detects a deliberate cross-principal leak and a deliberate audit bypass, failing with the offending tool named | `spec/reeve/testing/checks_spec.rb`, `spec/reeve/testing/support/fixtures.rb`, `spec/dummy/quickstart.rb` (final step) | ✅ |
| SC-008 | The library loads with no MCP server library and no policy library installed | `spec/load_safety_spec.rb`, `spec/reeve/plain_interface_spec.rb` — both in a subprocess with `--disable-gems` | ✅ |
| SC-009 | Every guarantee is assertable from either Rails test framework and from plain Ruby, with identical outcomes | `spec/reeve/testing/parity_spec.rb` (one table driving all three front-ends), `spec/dummy/test/compliance_test.rb` (stock Minitest, RSpec provably absent) | ✅ |

## Functional requirements with a dedicated spec

| FR | Proven by |
|----|-----------|
| FR-001 principal required | `spec/reeve/invocation_spec.rb`, `spec/reeve/edge_cases_spec.rb` |
| FR-002 / FR-004 deny by default | `spec/reeve/guard_spec.rb`, `spec/reeve/invocation_spec.rb` |
| FR-003 scope filtering | `spec/reeve/authorization/scoper_spec.rb` (every row of the return-value table) |
| FR-005 Pundit and plain policies | `spec/reeve/authorization/adapters_spec.rb` |
| FR-006 denial names tool/principal/rule | `spec/reeve/errors_spec.rb`, `spec/reeve/edge_cases_spec.rb` |
| FR-007 evaluated at invocation time | `spec/reeve/edge_cases_spec.rb` ("permissions change mid-session") |
| FR-008 / FR-009 one entry, fully populated | `spec/reeve/audit/recorder_spec.rb`, `spec/reeve/audit/entry_spec.rb` |
| FR-010 append-only | `spec/reeve/audit/entry_spec.rb` (readonly, destroy aborts) |
| FR-011 redaction | `spec/reeve/audit/redactor_spec.rb`, `spec/reeve/integration_spec.rb` (per-tool `redact`) |
| FR-012 ledger failure fails the call | `spec/reeve/audit/failure_mode_spec.rb`, `spec/reeve/invocation_spec.rb` |
| FR-013 five query axes | `spec/reeve/audit/query_spec.rb` |
| FR-014 truncation | `spec/reeve/audit/recorder_spec.rb`, `spec/reeve/edge_cases_spec.rb` |
| FR-015 generator + versioned contract | `spec/reeve/generators/install_generator_spec.rb`, `spec/reeve/audit/contract_version_spec.rb` |
| FR-016 … FR-020, FR-026 testing kit | `spec/reeve/testing/*` |
| FR-021 / FR-023 install generator | `spec/reeve/generators/install_generator_spec.rb` |
| FR-022 / FR-024 server library optional | `spec/reeve/integrations/fast_mcp_spec.rb`, `spec/reeve/plain_interface_spec.rb` |
| FR-025 runnable examples | `spec/readme_spec.rb` |

## Known gaps, stated rather than buried

**Existence disclosure on an unscoped by-id fetch.** A tool calling `Invoice.find_by(id:)`
denies for a record that exists but belongs to someone else, and returns `nil` for one that
does not exist — so the two are distinguishable, which spec.md's edge case asks them not to
be. The envelope cannot close it: when it sees `nil` it cannot tell a lookup from an empty
collection. Fetching through `scoped` removes the difference, both behaviours are pinned in
`spec/reeve/edge_cases_spec.rb`, and the remedy is documented in `contracts/tool-dsl.md`
and the README. Closing it properly would need the tool to declare its shape — a v2
question, deliberately not invented here.

**The 15-minute claim in SC-004** is not measurable by a test suite. What is proven is that
every documented step executes and produces what the document says it produces.

**`AuditCoverage` checks one invocation, not every invocation** (FR-017's wording). Raised
by the testing-kit implementation and left as-is: proving "every" requires a static
analysis the kit does not attempt.

**Multi-database and non-sqlite behaviour** rests on ActiveRecord's portability, not on a
test. CI runs sqlite only.

**Timing side channels** are not tested. Query count stands in as a deterministic proxy in
`spec/reeve/edge_cases_spec.rb`; wall-clock timing assertions would be flaky on shared CI
and are not attempted.
