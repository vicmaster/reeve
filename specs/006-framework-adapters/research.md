# Research: Framework Adapters

Read from source, 2026-11-10: `mcp` 1.0.0 and 1.9.0; `actionmcp` 0.200.0, 0.202.0 and 0.203.0
(0.203.0 was released after the spec was written). Line references are to 1.9.0 and 0.202.0.

## R1 — Where the official SDK calls a tool

**Finding.** `MCP::Server#call_tool_with_args` (server.rb:2011) calls the tool *class*:
`tool.call(**args, server_context: ctx)` when `accepts_server_context?(tool.method(:call))`,
else `tool.call(**args)`. `accepts_server_context?` (server.rb:2003) is true for a `**kwargs`
parameter or a `server_context:` keyword. The return value must respond to `to_h`
(`MCP::Tool::Response`). Any exception other than `RequestHandlerError`, `CancelledError` and
`InsufficientScopeError` becomes a JSON-RPC internal error with a generic message
(server.rb:1458). Identical in 1.0.0 (server.rb:1005, 1013).

**Decision.** Prepend a module to each tool subclass's *singleton class* with
`call(*args, **kwargs, &block)`. Because of the `**kwargs`, the SDK now always passes
`server_context:`. The wrapper reads it, then passes it on only if the method it wraps
(`method(:call).super_method`) would itself have received it under the SDK's own rule. The
tool sees exactly what it saw before (FR-020).

**Alternatives.** Wrapping `MCP::Server#call_tool`: covers every tool at one point, but it is a
private method, sits outside the per-tool class where `guard_with` lives, and would put Reeve
around argument validation the SDK does first. Rejected.

## R2 — Installing on tools defined before and after the require

**Decision.** Same shape as fast-mcp: prepend `Inheritance` to `MCP::Tool.singleton_class`, so
every later subclass gets the wrapper at `inherited` time (before its own `def self.call`,
which a prepended module still precedes). For tools that already exist, walk
`MCP::Tool.subclasses` recursively. `Class#subclasses` arrived in Ruby 3.1 and the SDK runs on
3.0, so on 3.0 fall back to `ObjectSpace.each_object(MCP::Tool.singleton_class)`. Idempotent:
skip a class whose singleton already includes the module (FR-004).

## R3 — Block-registered SDK tools are not a bypass

**Finding.** `server.define_tool(...) { }` and `MCP::Tool.define(...) { }` both build
`Class.new(MCP::Tool)` and `define_singleton_method(:call, &block)` (tool.rb:139). They are
subclasses: `inherited` fires, so R2 wraps them like any other tool. The block runs with the
class as `self`, so `scoped` and `authorize!` as class methods work inside it.

**Consequence: the spec was wrong.** Story 4, FR-021 and "Not guaranteed" item 3 assumed block
tools escape Reeve and need the inventory. They do not escape it. They are routed through the
envelope and, having no guard, are denied `no_guard_declared` under the default `:deny`. They
are guarded by declaring on the class the server holds:

```ruby
server.define_tool(name: "list_invoices") { |**| ... }
server.tools["list_invoices"].guard_with InvoicePolicy
```

Spec amended in this change: Story 4 now covers guarding block tools; FR-021 replaced.

**Behavior change worth stating in CHANGELOG.** Requiring `reeve/mcp` under `:deny` refuses
every SDK tool without a guard, block or class, on the next call. That is deny-by-default
working, and `:allow_with_warning` is the documented migration mode, but a host must read it
before deploying.

## R4 — Translating a denial on the SDK

**Decision.** Rescue `Reeve::DeniedError` in the wrapper and return
`MCP::Tool::Response.new([{ type: "text", text: e.message }], error: true)`, the same shape as
the SDK's own `error_tool_response` (server.rb:1963). The message names tool, principal and
rule, never a record (Constitution VI, FR-007). Tool errors and `Reeve::Error`
(configuration, recorder failure) are re-raised, so the SDK reports them as it does today
(FR-009). `error:` as a keyword exists from 1.0.0.

## R5 — The whole output is a derived result

**Decision.** The wrapper hands the envelope a block returning whatever the tool returned (on
the SDK) or the buffered response (on ActionMCP, R8). Neither is a record, relation or array of
records, so the core scoper's existing `scope_derived` branch decides: allowed only when
`scoped(...)` ran during this invocation, otherwise `unscoped_derived_result`. No change to
the scoper. Write rollback on denial (FR-010) comes from `run_guarded` as it does today.

**Alternative considered: check every record the tool loaded.** Track each ActiveRecord
instance materialized during the invocation (an `after_find` hook scoped to the call) and deny
`out_of_scope_record` if any falls outside the principal's policy scope, reusing
`visible_ids_among`. It would close the one-flag weakness for ActiveRecord data. Not taken now:
tools legitimately load records the principal cannot see (the account a user belongs to,
settings, lookup tables), so it denies working tools; it needs a policy for every model a tool
touches; and it costs a query per type per call. A candidate for a later opt-in strict mode,
once a host shows the weakness matters. Recorded in Complexity Tracking against Principle I.

## R6 — Request data for the resolver (core change)

**Finding.** `Context#to_h` feeds the recorder, and everything in `metadata` is written.
`server_context` is whatever the host passed to `MCP::Server.new` (often the user object) plus
request `_meta`; `auth_info` is a verified OAuth access token; an ActionMCP session is an
ActiveRecord model.

**Decision.** `Context` gains `request` (a Hash, default `{}`), absent from `to_h`, `inspect`
and every error. `Reeve.invoke` and `Inventory#dispatch` accept `request:`. The envelope's
ensure clears it with the principal (`Context#clear_request!`, called next to
`clear_principal!`). Adapters fill it:

| Adapter | `request` keys |
|---|---|
| Official SDK | `server_context` (the `MCP::ServerContext`), `auth_info` |
| ActionMCP | `session`, `execution_context` |

Resolvers read `context.request[:auth_info]`, etc.

**Alternatives.** Put it in `metadata` and rely on redaction: redaction is by key name and
cannot know a user object or a nested token. Rejected. A thread-local the adapter sets: a
second, invisible channel next to `Context`, which exists to carry exactly this. Rejected.

## R7 — Attribution and metadata

**Decision.** Agent from the client's own report, attribution only (FR-012):

- SDK: `server_context.client_info` (envelope first, then session; server_context.rb), giving
  `id: name`, `name: "#{name} #{version}"`.
- ActionMCP: `session.client_info` (a JSON column).

Missing or blank: `unknown`. `metadata` gets only `{ client: { name:, version: } }`. Never
`_meta`, headers or `server_context` (FR-043). Amended in implementation: not the ActionMCP
session id either. On some transports a session id is enough to resume a session, and the
ledger is append-only, so it is treated like a credential.

## R8 — Where ActionMCP runs a tool

**Finding.** `ActionMCP::Tool#call` (tool.rb:540) sets `@response = ToolResponse.new`, runs
`perform` inside `run_callbacks :perform`, and rescues every `StandardError` into
`report_tool_error` with "An unexpected error occurred." for HTTP requests. `perform` is
`protected`; its return value is ignored; `render` adds content to `@response`. The same code
in 0.200.0, 0.202.0 and 0.203.0 (0.203.0 changed only input-schema resolution).

**Decision.** Prepend to each subclass a protected `perform` that:

1. keeps the real response, and points `@response` at a fresh `ToolResponse` (the buffer);
2. runs `Reeve.invoke(...) { super; @response }`, so the envelope sits *inside* ActionMCP's
   rescue and sees tool errors first (FR-030);
3. on allow, copies the buffer's contents, structured content and any tool-reported error into
   the real response;
4. on `Reeve::DeniedError`, reports `e.message` on the real response as a tool error;
5. in `ensure`, restores the real response, so a raised error discards the buffer before
   ActionMCP's rescue writes its generic message (FR-031).

Arguments for the ledger are the tool's ActiveModel `attributes`, so `redact` applies.

**Alternatives.** Wrap `call`: outside the rescue, so a raising tool returns a normal error
response and would be recorded `allow`. Rejected. `around_perform` callback: also inside the
rescue, but a host's own callbacks can be ordered around it, and a `prepend` cannot be
reordered or skipped. Rejected.

## R9 — ActionMCP's principal and background tasks

**Finding.** The gateway assigns identities to `ActionMCP::Current` (gateway.rb:96), so
`ActionMCP::Current.user` is the authenticated user. Task-augmented calls run in
`ToolExecutionJob` (tool_execution_job.rb:68), which sets the session on the tool but not
`Current.user`.

**Decision.** The adapter does not set the principal (FR-032). README resolver:
`->(_context) { ActionMCP::Current.user }`. In a job that returns nil, so the call is denied
`no_principal` and recorded (FR-033). A host that stores identity on the session can resolve
it from `context.request[:session]`; README shows the shape, not a recommendation.

## R10 — `request_input!` and halted callbacks

**Finding.** `request_input!` does `throw :halt_execution`, and nothing in 0.202.0 catches it,
so Ruby raises `UncaughtThrowError`, a `StandardError`, which `call` turns into a tool error.
A `before_perform` that halts means `perform` never runs.

**Decision.** No special handling. The throw passes through the envelope as an error, is
recorded `tool_error`, and the buffer is discarded (R8 step 5). A halted callback writes no row,
as schema validation does on fast-mcp. Both listed in README.

## R11 — Not recording a call twice

**Finding.** The testing kit's default runner is `tool.new.call(**arguments)` inside its own
`Reeve.invoke` (authorization.rb:52). On SDK tools that raises (`call` is a class method). On
ActionMCP it reaches the adapter's `perform` and opens a second envelope.

**Decision.** Two parts.

1. **Pass-through.** If an envelope for the same tool name is already open on this thread
   (`Authorization::Current.state.context.tool_name`), the adapter runs the body directly: no
   second envelope, no denial translation. Covers the kit and a host that wraps
   `Reeve.invoke` around a library call itself (FR-051).
2. **Runner hook.** The core runner calls `tool.reeve_run(arguments)` when the tool class
   defines it. The SDK adapter defines it as the class `call`, passing `server_context: nil`
   only to tools that declare it. The ActionMCP adapter defines it as: build with
   `from_wire`, validate, set a fresh response, `run_callbacks(:perform) { perform }`, return
   the response, with no rescue, so a denial or error reaches the kit's envelope (FR-050).
   Invalid arguments raise `ArgumentError` naming the tool, not a silent error response.

## R12 — Abstract bases

**Decision.** `MCP::Tool` and `ActionMCP::Tool` are marked `reeve_abstract!` at install.
ActionMCP's own `abstract!` (capability.rb:69) is wrapped to mark the class abstract for Reeve
too, so `ApplicationMCPTool` is not reported by `GuardDeclared`. Existing abstract subclasses
are marked at install.

## R13 — Version ranges and CI

**Decision.**

| Library | Range | Why |
|---|---|---|
| `mcp` | `>= 1.0, < 2.0` | Uses only the public tool interface (class `call`, `server_context:`, `Response#error:`), identical in 1.0.0 and 1.9.0. |
| `actionmcp` | `>= 0.200.0, < 0.204` | Uses internals (`@response`, protected `perform`, `:perform` callbacks, `ToolResponse` API), identical 0.200.0–0.203.0. |

Outside the range the require raises `Reeve::ConfigurationError` naming the range (FR-013).
The ActionMCP ceiling means a Reeve patch release per ActionMCP minor; that is the price of
touching internals, and refusing an unverified version is deny-by-default applied to
ourselves.

Gemfile: `mcp` on every Ruby; `actionmcp` only on Ruby 3.2+ (Rails 8.1). CI: the existing
matrix runs the latest of each; one added job on Ruby 3.4 installs the range floors
(`MCP_VERSION=1.0.0`, `ACTIONMCP_VERSION=0.200.0`).

**Settled by the spike (T001), 2026-11-10.**

- `require "action_mcp"` and `ActionMCP::Tool#call` work without a booted Rails app (0.203.0
  on Ruby 3.3), so the ActionMCP specs need no dummy app.
- `mcp` 1.x and `json_schemer` (>= 2.4) both declare Ruby 2.7+, so the SDK installs on the
  3.0 job; CI confirms it. The adapter's specs pass on `mcp` 1.0.0 and 1.9.0.
- **Found: fast-mcp and the SDK clash.** fast-mcp ships `lib/mcp/tool.rb` and
  `lib/mcp/server.rb`, the paths the SDK autoloads `MCP::Tool` and `MCP::Server` from. If
  fast-mcp loads first, Ruby considers those paths loaded and the SDK's classes never
  appear. Not reeve's to fix: `reeve/mcp` raises `ConfigurationError` explaining it, and the
  spec suite loads the SDK first (`spec/support/optional/mcp_sdk.rb`). A host runs one MCP
  library per process.

## R14 — Positioning check (Constitution IV)

Neither library scopes per principal or keeps an audit ledger: the SDK provides OAuth bearer
verification and `require_scopes!` (connection-level scopes); ActionMCP provides gateway
authentication, profiles and per-tool consent. Both are connection or tool-level, not
record-level. Nothing here duplicates them. Reeve still does no connection authentication.
