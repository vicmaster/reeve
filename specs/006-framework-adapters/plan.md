# Implementation Plan: Framework Adapters

**Branch**: `006-framework-adapters` | **Date**: 2026-11-10 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/006-framework-adapters/spec.md`

## Summary

Two opt-in adapters, `reeve/mcp` (official SDK) and `reeve/action_mcp`, that route every tool
call of those libraries through the existing envelope, plus one additive core change: an
unrecorded `request` carrier on `Context` for the principal resolver. Both libraries return
rendered output rather than records, so the adapters hand the envelope the whole output and
the core's existing derived-result rule decides: allowed only after `scoped(...)`. No new DSL,
no schema change, no contract-version bump.

Planning found one spec error, fixed in this change: block-registered SDK tools are classes,
so they go through Reeve and are guarded like any other tool (research R3; Story 4 and FR-021
amended).

## Technical Context

**Language/Version**: Ruby 3.0+ core; SDK adapter on 3.0+ (R13 open item for 3.0); ActionMCP
adapter on 3.2+ (Rails 8.1)
**Primary Dependencies**: none at runtime. Development: `mcp` (>= 1.0, < 2.0), `actionmcp`
(>= 0.200.0, < 0.204), existing fast-mcp, pundit, activerecord, sqlite3
**Storage**: unchanged ledger table
**Testing**: RSpec (repo), with Minitest front-end parity specs for the testing kit
**Target Platform**: Rails applications serving MCP
**Project Type**: library (gem)
**Performance Goals**: no measurable cost beyond the envelope's existing cost; the adapters add
one buffer swap (ActionMCP) and one method-parameters check per call (SDK, cacheable per class)
**Constraints**: no runtime dependency; each adapter loads only on its own require; no adapter
wraps another library's tools
**Scale/Scope**: 2 adapters, ~6 new lib files, ~5 touched core files, README and CHANGELOG

## Constitution Check

*Pre-design and post-design results are the same; post-design notes in italics.*

| Principle | Status | Notes |
|---|---|---|
| I. Deny by Default | **PASS, with a justified weakness** | No principal, no guard, policy error, or output without `scoped` all deny; a denial never releases rendered output (FR-008). The weakness: on these libraries output is allowed or refused, not narrowed, and the `scoped` check is one flag per call. Not silent: stated normatively in the spec and README. See Complexity Tracking. *Post-design: block tools denied until guarded (R3) strengthens this.* |
| II. Every Call Leaves a Trace | PASS | Envelope runs inside each library's error handling, so tool errors are recorded before being swallowed (R8). Pass-through (R11) prevents double rows, never zero rows. A call halted before the body runs (ActionMCP callback, schema validation) writes no row, same as fast-mcp; documented. |
| III. Provable by Test | PASS | Testing kit runs adapter tools without a custom `invoke:` via the runner hook (R11), RSpec and Minitest. Test-first per task. |
| IV. Extension Layer | PASS | Conditionally loaded, never a dependency; positioning check R14. One gem. |
| V. Clean-Room Provenance | PASS | Built from the two libraries' public source (MIT) and Reeve's own code only. |
| VI. Boring DX | PASS | One require, `guard_with`, `scoped`. The one new API surface (`request:`) has a demonstrated need: the SDK resolver cannot identify a user without it, and `metadata:` would record credentials (R6). |

## Design

Details and alternatives are in [research.md](research.md); this is the shape.

### Core: request data (R6, [contract](contracts/request-data.md))

- `Context#request` (Hash, unrecorded), `Context#clear_request!`.
- `Invocation#call` ensure: clear request with principal.
- `Reeve.invoke(..., request: {})`, `Inventory#dispatch(..., request: {})`.
- `Reeve.invoke`'s runner: `tool.reeve_run(arguments)` when the class defines it (R11).

### Shared integration pieces

- **Version gate**: check `Gem.loaded_specs` against the adapter's range; raise
  `ConfigurationError` naming it (FR-013).
- **Pass-through**: `Reeve::Integrations.inside?(tool_name)`, true when the current thread
  already has an envelope open for that name (R11).
- **Install**: the fast-mcp pattern generalized: include `Guard` into the base, mark it
  abstract, prepend `Inheritance`, wrap existing subclasses, idempotent.

### Official SDK (R1–R4, [contract](contracts/mcp-adapter.md))

- `ToolExtension` prepended to each subclass's singleton class: `call(*args, **kwargs)`;
  read `server_context`; pass-through if inside; else `Reeve.invoke` with attribution,
  metadata and request from `ContextBuilder`; forward `server_context` only if the wrapped
  method accepts it; rescue `DeniedError` into an error `Response`.
- Class-level `scoped` / `authorize!` delegating to the same `Scoper` / adapter calls the
  instance helpers use (extracted so both share one implementation).
- `reeve_run(arguments)`: class `call`, with `server_context: nil` only when declared.
- Existing subclasses: `subclasses` on 3.1+, `ObjectSpace` on 3.0.

### ActionMCP (R8–R12, [contract](contracts/action-mcp-adapter.md))

- `ToolExtension` prepended to each subclass: protected `perform` that buffers the response,
  runs the envelope inside ActionMCP's rescue, merges on allow, reports the denial message on
  deny, restores the real response in `ensure`.
- `abstract!` wrapped to mark Reeve-abstract too.
- `reeve_run(arguments)`: `from_wire`, validate (raise `ArgumentError` naming the tool),
  fresh response, `run_callbacks(:perform) { perform }`, return the response; no rescue.

## Project Structure

### Documentation (this feature)

```text
specs/006-framework-adapters/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── request-data.md
│   ├── mcp-adapter.md
│   └── action-mcp-adapter.md
├── checklists/requirements.md
└── tasks.md            # /speckit.tasks
```

### Source Code

```text
lib/reeve/
├── context.rb                         # + request, clear_request!
├── invocation.rb                      # ensure clears request
├── authorization.rb                   # invoke(request:), reeve_run hook
├── authorization/guard.rb             # helpers extracted for class-level use
├── inventory.rb                       # dispatch(request:)
├── integrations.rb                    # new: inside?, version gate, shared install
├── mcp.rb                             # new: require "reeve/mcp"
├── action_mcp.rb                      # new: require "reeve/action_mcp"
└── integrations/
    ├── fast_mcp/                      # unchanged, may adopt shared install
    ├── mcp/
    │   ├── context_builder.rb
    │   └── tool_extension.rb
    └── action_mcp/
        ├── context_builder.rb
        └── tool_extension.rb

spec/reeve/
├── context_spec.rb, invocation_spec.rb    # request data
├── integrations/mcp_spec.rb               # Stories 1, 4, 5
├── integrations/action_mcp_spec.rb        # Story 2
└── testing/adapter_parity_spec.rb         # Story 3, RSpec and Minitest
spec/load_safety_spec.rb                   # each adapter loads alone; absence breaks none

Gemfile, .github/workflows/*.yml, README.md, CHANGELOG.md
```

**Structure Decision**: same layout as the fast-mcp adapter: one top-level require file per
adapter, its pieces under `integrations/<library>/`.

## Delivery Order

1. **Core request data** (Story 5). Small, additive, everything else needs it.
2. **Spike**: does `require "action_mcp"` need a booted Rails app; does `mcp` install on
   Ruby 3.0 (R13 open items). Amend FR-022 / SC-003 if 3.0 cannot run the SDK.
3. **Official SDK adapter** (Stories 1 and 4), with pass-through and the runner hook.
4. **Testing kit parity for the SDK** (Story 3, SDK half).
5. **README and CHANGELOG for the SDK.** Releasable here as a minor version.
6. **ActionMCP adapter** (Story 2).
7. **Testing kit parity for ActionMCP** (Story 3, ActionMCP half), CI floor job, docs.

Each step ends at a commit checkpoint.

## Risks

| Risk | Mitigation |
|---|---|
| ActionMCP changes `@response`, `perform` or callbacks in a minor release | Strict range, refuse to load outside it; CI floor job; a Reeve patch per verified ActionMCP release |
| Hosts read "one require" and expect per-record narrowing | Normative "Not guaranteed" in spec, README section, quickstart's "before deploying" |
| Requiring an adapter denies existing unguarded tools in production | CHANGELOG and README call it out; `:allow_with_warning` migration path |
| Pass-through hides a call that should have been recorded | Pass-through only when an envelope for the *same tool name* is already open on this thread; spec asserts exactly one row, never zero |
| The `**kwargs` wrapper changes what an SDK tool receives | FR-020 specs for tools with and without `server_context:` and with `**rest` |
| `json_schemer` or ActionMCP needs more than the spec env provides | Delivery step 2 settles it before adapter work starts |

## Complexity Tracking

| Tension | Why accepted | Stronger alternative rejected because |
|---|---|---|
| Principle I: output is allowed or refused, not narrowed; `scoped` is one flag per call | The libraries render output before Reeve sees it; there are no records left to narrow. Every unscoped output is still refused, and the weakness is stated, not silent. | Checking every ActiveRecord record loaded during the call (R5) denies working tools that load data the principal cannot see (their account, settings), needs a policy for every model, and adds a query per type per call. Candidate for a later opt-in strict mode. |
| ActionMCP adapter depends on library internals | `call` swallows every error, so the envelope must sit inside it, and rendered content must be held back; neither is possible from the public API | `around_perform` can be reordered by host callbacks; wrapping `call` records tool errors as `allow` (R8) |
| New public kwarg `request:` | Needed to identify the principal on the SDK without writing credentials to an append-only table (R6) | Redacting `metadata` by key cannot catch a user object or a nested token |
