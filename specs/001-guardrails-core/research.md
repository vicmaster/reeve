# Research: reeve v1

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

**RESOLVED 2026-08-11 (T056), against fast-mcp 1.6.0 as installed.** In-tool request
access exists, so the server-level fallback is not needed. `FastMcp::Server` does:

```ruby
tool_instance = tool.new(headers: headers)          # mcp/server.rb:327
result, metadata = tool_instance.call_with_schema_validation!(**symbolized_args)
```

and `FastMcp::Tool` exposes `attr_reader :headers` (mcp/tool.rb:364). The transport's
headers are therefore the per-request context, and the only one a tool has — there is no
session or connection object reachable from inside `call`.

The adapter passes those headers through to the resolver untouched, as
`context.metadata[:headers]`: which header identifies the human is the host's decision,
not ours. Agent attribution reads `X-MCP-Client`, `X-Client-Name`, then `User-Agent`, and
records `"unknown"` when none answers — attribution is not authorization.

The envelope is installed by prepending a module to each tool **subclass** at `inherited`
time rather than to `FastMcp::Tool` itself: a module prepended to the parent still sits
behind the subclass's own `call` in the ancestry, so wrapping the parent would silently do
nothing. Prepending at `inherited` time works even though `call` is defined afterwards.

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
3. **Derived value** (count, sum, string, hash) — allowed only if the tool obtained its
   data through `scoped(Model)`, an instance method the guard mixes in that returns the
   policy-scoped relation. The envelope tracks whether `scoped` was called; a non-record
   return without it denies with `unscoped_derived_result`.

Mixed-type collections scope each type by its own policy; an unpoliced type denies the
whole call (spec edge case).

**Revised 2026-08-11**: case 3 originally required a `derives_from :invoices` macro. Asking
the developer to *declare* what they derived from is a promise; handing them the scoped
relation makes it true by construction. The `scoped` form is enforceable rather than
trusted, removes a macro from the public surface (Constitution VI), and steers toward the
safe path instead of documenting it. This is the collapse the plan's Constitution Check
flagged for the design panel — resolved before Phase 1 rather than during it.

**Alternatives rejected**: Scoping only relations and trusting everything else (fails
FR-003 for the aggregate case). Banning non-record returns from guarded tools entirely —
simpler, but "how many overdue invoices do I have?" is a legitimate MCP tool, and refusing
to guard it just pushes people to leave it unguarded, which is the worse outcome.
Deep-inspecting arbitrary return values (unbounded and still guessable).

## R5. Ledger storage and immutability

**Decision**: An ActiveRecord-backed table in the host's own database, created by the
install generator. Immutability is enforced at three levels: (a) the model raises on
`update`/`destroy` via `readonly?` and `before_destroy throw(:abort)`; (b) no public API
accepts an entry id for mutation (FR-010); (c) documentation tells hosts to grant
INSERT+SELECT only on the table for the app role, since a library cannot enforce this
against raw SQL and should not pretend to.

**Write path (corrected 2026-08-11)**: synchronous, in an `ensure` block, **in its own
transaction** — deliberately *not* the tool body's transaction.

The original decision put the write inside the tool's transaction so that a ledger failure
would fail the call. That was wrong in the other direction: a tool body that raises rolls
back its own audit row, so the invocations most worth recording — the ones that blew up —
would leave no trace. That contradicts Constitution II outright.

An independent transaction in `ensure` means the trace survives any rollback of the tool's
own work, on one connection. The honest caveat, documented rather than papered over: there
is a narrow window where the tool's data commits and the ledger write then fails. In the
default `:fail` mode the call still raises, so the caller learns — but the data change has
already landed. Closing that window entirely requires a second connection or two-phase
commit, which is disproportionate for v1 and is recorded here as the known limit.

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

**Decision (revised 2026-08-11)**: A framework-neutral check layer with three front-ends.

The original decision was RSpec-only, justified by a spec Assumption that I had written
myself — circular, and wrong on the merits. Both frameworks can express every assertion the
kit needs; RSpec's advantage was distribution and a quotable README demo, not capability.
Since a stock `rails new` app is Minitest and no team adds a second test framework to an
existing suite, RSpec-only means the gem simply does not work for a large share of Rails.
For a library whose purpose is to let people prove their guardrails hold, that is a failure
of purpose, not a market-segmentation choice.

All logic lives in plain-Ruby `Checks::*` objects returning a `Result`. RSpec matchers and
Minitest assertions are thin adapters; calling the checks directly is a supported third
path, which makes the guarantees assertable from a rake task, a CI script, or a boot-time
assertion — not only from a test suite. A single shared example table drives the same
fixtures through all three front-ends so none can silently diverge (SC-009).

Front-end surfaces:
- `expect(tool).to deny_access_for(other_principal)` — failure message names the leaked
  identifiers (FR-016, FR-019).
- `expect(server).to audit_every_call` — drives every registered tool through the
  envelope and asserts one entry each; failure names the unaudited tool (FR-017).
- `it_behaves_like "a reeve-compliant server"` — the shared compliance suite,
  iterating every registered guarded tool (FR-018).

Minitest gets `assert_denies_access_for` / `assert_audits_every_call` and a compliance
module with one assertion per check.

Front-ends live behind explicit requires (`reeve/rspec`,
`reeve/minitest`) so neither framework is a runtime dependency. No MCP client, no
network (FR-020).

**Resolved**: Minitest ships in v1, not deferred.

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
