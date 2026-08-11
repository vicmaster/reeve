# Research: mcp-guardrails v1

**Date**: 2026-08-11 | **Feature**: 001-guardrails-core

Decisions below resolve the technical unknowns blocking the plan. Items marked **OPEN**
are deliberately deferred to the Phase 1 design panel or to implementation-time
verification; none of them block task generation.

## R1. Where to attach in the MCP request lifecycle

**Decision**: Wrap tool execution rather than patching transports. Guardrails owns a
`Guardrails.invoke(tool, args, context) { ... }` envelope; every integration path
(fast-mcp adapter, plain interface) funnels into it. The envelope resolves the principal,
runs the policy, executes the tool body, scopes the result, writes the ledger entry, and
returns.

**Rationale**: The three server libraries differ in transport and registration but all
converge on "a tool object with a `call`". Wrapping the narrowest common point keeps the
core server-agnostic (Constitution IV) and gives exactly one place where deny-by-default
and audit are enforced (Constitution I, II) — no second path to forget.

**Alternatives rejected**: Rack middleware (only covers HTTP transport, not stdio; sees
JSON-RPC frames, not records). Monkey-patching each server library's dispatcher (brittle,
version-coupled, and invisible to the plain interface).

## R2. How the principal reaches the invocation

**Decision**: A host-configured resolver plus an explicit per-invocation context. The host
sets `config.principal_resolver = ->(context) { ... }`; the adapter populates `context`
from whatever the server library exposes (headers, session, connection metadata). The
plain interface accepts a principal directly. If the resolver returns nil or raises, the
call is denied without consulting the policy (FR-001, FR-004).

**Rationale**: Authentication is explicitly out of scope (spec Assumptions); the host
already knows who the human is. A resolver lambda avoids depending on any auth library
while keeping one obvious place to look.

**Concurrency**: The principal is carried on the invocation context object passed down the
call, not in a global. Where thread/fiber-local storage is needed for ergonomics
(`Guardrails.current_principal` inside a tool body), it MUST be set and unset by the
envelope with an `ensure`, so it cannot leak across calls (spec edge case).

**OPEN**: exactly which per-request metadata fast-mcp exposes inside a tool instance
(headers appear reachable; the README documents `filter_tools do |request, tools|` at the
server level but does not document in-tool request access). Verify against the installed
gem during the adapter task; the resolver contract does not change either way.

## R3. Bridging to policies

**Decision**: A thin `PolicyAdapter` protocol with two required methods —
`authorize(principal, action, record = nil) → Decision` and
`scope(principal, relation) → relation`. Ship two built-in adapters: a Pundit bridge
(`policy.resolve` for scopes, `#{action}?` predicates for actions) and a plain-object
adapter that calls the same two methods on any object the host supplies. Pundit is a
development-only dependency, detected at load, never required (Constitution IV).

**Rationale**: FR-005 demands both without coupling. Two methods is the smallest surface
that covers "may this principal act at all" and "which records may they see".

**Rule identity**: every `Decision` carries a `rule` string identifying what decided
(e.g. `"InvoicePolicy#index?"`, `"no_guard_declared"`, `"no_principal"`,
`"policy_error"`). FR-006 and FR-009 both depend on this being populated at every deny
site, so `Decision` construction requires it.

## R4. Scoping results that are not relations

**Decision**: Three result shapes, dispatched by type.
1. **Relation** — merged with the policy scope; the scoped relation is what executes.
2. **Record or collection of records** — filtered by re-checking each against the scope
   (`scope.where(id: ids)`), and the call denies if anything was filtered out on a
   single-record fetch (FR-006: no existence disclosure).
3. **Derived value** (count, sum, string, hash) — the tool must declare
   `derives_from :invoices` so the envelope can verify the computation ran against a
   scoped relation; undeclared derived returns from a guarded tool are denied.

Mixed-type collections scope each type by its own policy; an unpoliced type denies the
whole call (spec edge case).

**Alternatives rejected**: Scoping only relations and trusting everything else (fails
FR-003 for the aggregate case). Deep-inspecting arbitrary return values (unbounded and
still guessable).

## R5. Ledger storage and immutability

**Decision**: An ActiveRecord-backed table in the host's own database, created by the
install generator. Immutability is enforced at three levels: (a) the model raises on
`update`/`destroy` via `readonly?` and `before_destroy throw(:abort)`; (b) no public API
accepts an entry id for mutation (FR-010); (c) documentation tells hosts to grant
INSERT+SELECT only on the table for the app role, since a library cannot enforce this
against raw SQL and should not pretend to.

**Write path**: synchronous and inside the same transaction as the tool body by default,
so a ledger failure fails the call (FR-012). An explicit
`config.audit_failure_mode = :warn` opts into degraded mode. ActiveJob-based async writes
are deliberately NOT in v1 — they make FR-012 unenforceable.

**Rationale**: Host-owned table means the host's existing backup, retention, and export
policies apply for free (spec Assumptions), and the reviewer's query is plain SQL/AR.

## R6. Argument redaction

**Decision**: Declarative allow-through-with-redaction: the host declares sensitive
argument names globally (`config.redact_arguments = %i[ssn token password]`) and per tool
(`redact :ssn`). Redacted values are replaced with a marker; names always survive
(FR-011). Matching is on argument name, recursively into nested hashes.

**Alternatives rejected**: Value-pattern scanning (heuristic, both misses and false
positives on a compliance artifact). Storing nothing (destroys the ledger's usefulness).

## R7. Record-identifier volume

**Decision**: Store identifiers up to `config.max_recorded_ids` (default 1000); beyond
that, store the first N, the total count, and set `truncated = true` (FR-014). Never
silent.

## R8. Testing kit shape

**Decision**: RSpec matchers plus an includable shared example group.
- `expect(tool).to deny_access_for(other_principal)` — failure message names the leaked
  identifiers (FR-016, FR-019).
- `expect(server).to audit_every_call` — drives every registered tool through the
  envelope and asserts one entry each; failure names the unaudited tool (FR-017).
- `it_behaves_like "an mcp-guardrails compliant server"` — the shared compliance suite,
  iterating every registered guarded tool (FR-018).

Matchers live behind `require "mcp/guardrails/rspec"` so RSpec stays a development
dependency. No MCP client, no network (FR-020).

**OPEN**: whether to also ship Minitest assertions. Deferred — spec Assumptions scope v1
to one framework; revisit only on demand.

## R9. Behavior toward pre-existing unguarded tools

**Decision**: Config setting `config.unguarded_tools` with values `:deny` (default) and
`:allow_with_warning`. The install generator writes the chosen value explicitly into the
initializer with both options commented, so the choice is visible rather than inherited
(FR-023). `:allow_with_warning` still writes a ledger entry marked `guard: none`, so
Constitution II holds even in the permissive mode.

## R10. Ecosystem positioning (carried forward, verified 2026-08-11)

Official `mcp` SDK, fast-mcp (~1.2k★, MIT, Rails generators, dry-schema params, token/JWT
auth, server-level dynamic tool filtering), and ActionMCP (Rails 8.1+, gateway auth,
per-tool consent) all authenticate the connection; none does per-principal record scoping,
compliance-grade audit, or a testing kit. fast-mcp's `filter_tools` filters *which tools
are visible* by request — it is not record-level scoping, and it is complementary rather
than overlapping. First adapter: fast-mcp (largest installed base).

**Sources**: [fast-mcp README](https://github.com/yjacquin/fast-mcp)
