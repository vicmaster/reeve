# Feature Specification: Framework Adapters

**Feature Branch**: `006-framework-adapters`
**Created**: 2026-11-10
**Status**: Draft
**Input**: "Framework adapters for the official mcp SDK (gem `mcp`, verified against 1.9.0)
and ActionMCP (gem `actionmcp`, verified against 0.202.0), alongside the existing fast-mcp
adapter." Design settled with Victor on 2026-11-10; see the input in the conversation that
created this branch.

## Overview

Reeve claims to ride all three Ruby MCP server libraries. Today it rides one. A host on the
official SDK or on ActionMCP gets no guard on its tools unless it routes every call through
`Reeve.invoke` by hand, which is exactly the step a host forgets.

The fast-mcp adapter works because a fast-mcp tool **returns records** and Reeve narrows them
per record before anything leaves. The other two do not work that way:

- **Official SDK.** A tool answers with a finished response object it built itself. Tools can
  also be registered as blocks on a server; the SDK still makes a class for each.
- **ActionMCP.** A tool **renders** content into a response as it goes; what its body returns
  is ignored. The library catches every error a tool raises and replaces it with a generic
  message.

So the records are gone before Reeve sees the result. What reaches Reeve is output that was
*derived* from records, the same as a count or a sum. The core already has a rule for that:
a derived result is allowed only when the tool read its data through `scoped(...)`, and a
single record is checked with `authorize!`. These adapters apply that rule to the whole
response. No new DSL.

### What this feature guarantees, and what it does not

Normative. README, CHANGELOG and error messages MUST NOT claim more.

**Guaranteed**, for every tool defined on a supported library after the adapter is loaded,
and every tool defined before it:

- the call runs through the envelope: principal resolved, guard looked up, policy asked,
  output checked, one ledger row written, allowed or denied, including when the tool raised;
- no principal, no guard, or a policy that raises means the tool's output never reaches the
  client;
- a denial reaches the client as a tool error carrying the rule, and never names a record;
- output from a tool that never called `scoped(...)` is refused as `unscoped_derived_result`.

**Not guaranteed, stated plainly:**

1. **Per-record narrowing does not happen on these two libraries.** On fast-mcp a tool that
   returns `Invoice.all` gets back only the principal's invoices. Here the output is already
   rendered text or structured content when Reeve sees it; it can be allowed or refused,
   not narrowed. "`guard_with` is the only line you add" is true for fast-mcp only. For
   these adapters it is "`guard_with` plus `scoped`".
2. **The `scoped` check is one flag per call.** A tool that calls `scoped(Invoice)` and also
   renders `Invoice.find(id)` passes. Reeve proves the tool asked for scoped data; it does
   not prove every rendered value came from it. `authorize!` on any record fetched another
   way closes that, by the tool author's discipline, not by construction.
3. **Tools Reeve never sees are not protected.** Every tool class of a supported library is
   seen, block-registered SDK tools included; a tool served some other way is not.
4. **ActionMCP background-task calls have no principal by default.** They run outside the
   request that identified the user; they are denied `no_principal` unless the host's
   resolver can identify the user another way.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Guard a tool on the official SDK (Priority: P1)

A host serves MCP with the official SDK. They load Reeve's adapter, add `guard_with` to a tool
class, read through `scoped(...)`, and every call to that tool is authorized, checked and
recorded. They change nothing about how they build the server or the response.

**Why this priority**: The official SDK is stable (1.x), maintained by the protocol's own
organization, and runs on every Ruby Reeve supports. It is the larger audience and the lower
risk.

**Independent Test**: Define a tool on the SDK with `guard_with`, register it on a server,
send `tools/call` requests as two principals, and check the responses and the ledger.

**Acceptance Scenarios**:

1. **Given** a guarded tool that builds its response from `scoped(Invoice)`, **When** a
   principal calls it through the server, **Then** the response holds only what that
   principal's scope returned and one ledger row records `allow` with the principal and rule.
2. **Given** the same tool built from `Invoice.all` with no `scoped(...)`, **When** it is
   called, **Then** the client gets a tool error naming `unscoped_derived_result`, no
   invoice data, and the ledger records `deny`.
3. **Given** a tool that calls `authorize!` on a record outside the principal's scope,
   **When** it is called, **Then** the client gets a tool error naming the policy's rule and
   no record identifier, and any database writes the tool made are rolled back.
4. **Given** no principal can be resolved, **When** any guarded tool is called, **Then** the
   tool body does not run, the client gets a tool error naming `no_principal`, and a row is
   recorded.
5. **Given** a tool whose body raises, **When** it is called, **Then** the ledger records
   `tool_error` and the client sees the SDK's usual error for a failed tool.
6. **Given** a tool that declares the server context keyword and one that does not, **When**
   each is called, **Then** each receives exactly the arguments it would have received
   without Reeve.
7. **Given** a tool defined before the adapter was loaded, **When** it is called, **Then** it
   is guarded the same as one defined after; **And** loading the adapter twice does not
   record a call twice.

---

### User Story 2 - Guard a tool on ActionMCP (Priority: P2)

A host serves MCP with ActionMCP. They load Reeve's adapter, add `guard_with` to a tool,
read through `scoped(...)` in `perform`, and the principal is the user ActionMCP's gateway
already authenticated.

**Why this priority**: ActionMCP is very active but pre-1.0 and needs Rails 8.1 / Ruby 3.2+,
so it reaches fewer hosts and carries more maintenance risk. It ships after Story 1.

**Independent Test**: Define an ActionMCP tool with `guard_with`, set the current user as the
gateway would, call the tool as the server does, and check the response and the ledger.

**Acceptance Scenarios**:

1. **Given** a guarded tool whose `perform` renders from `scoped(Invoice)` and a user set by
   the gateway, **When** the tool is called, **Then** the rendered content is returned and one
   row records `allow` for that user.
2. **Given** a tool that renders from `Invoice.all` with no `scoped(...)`, **When** it is
   called, **Then** none of what it rendered reaches the client, the client gets a tool error
   naming `unscoped_derived_result`, and the ledger records `deny`.
3. **Given** a tool that raises in `perform`, **When** it is called, **Then** the ledger
   records `tool_error` before ActionMCP turns the error into its generic message.
4. **Given** a denial raised by `authorize!` in `perform`, **When** it is called, **Then** the
   client sees a tool error naming the rule, not ActionMCP's "unexpected error" message.
5. **Given** a tool called as a background task, with no user resolvable, **When** the task
   runs, **Then** it is denied `no_principal` and recorded.

---

### User Story 3 - Prove it in CI on either library (Priority: P2)

A host on either library runs Reeve's matchers and compliance suite against their tools with
the same lines a fast-mcp host writes, and gets the same answers.

**Why this priority**: Constitution III. A guard that cannot be proven in CI is a claim, not a
guarantee. Ships with whichever adapter it covers.

**Independent Test**: Run `deny_access_for`, `audit_every_call` and the full compliance suite
against a guarded and an unguarded tool from each library, under RSpec and under Minitest.

**Acceptance Scenarios**:

1. **Given** a guarded SDK or ActionMCP tool, **When** the compliance suite runs without a
   custom `invoke:`, **Then** it invokes the tool the way the library does and each check
   passes or fails on the tool's real behavior.
2. **Given** a tool invoked by the testing kit, **When** the call completes, **Then** exactly
   one ledger row exists for it.
3. **Given** an unguarded tool on either library, **When** the suite runs, **Then**
   `GuardDeclared` names it.

---

### User Story 4 - Guard a block-registered SDK tool (Priority: P3)

A host on the official SDK registers some tools as blocks on the server. Those calls go
through Reeve like any other: denied until guarded. The host guards one by declaring on the
tool the server holds for that name.

**Why this priority**: Block tools are a real SDK pattern. Amended during planning
(research R3): the SDK makes a class for every block, so these tools never bypass Reeve; the
story is only about guarding them.

**Independent Test**: Register a block tool on an SDK server, call it before and after
declaring a guard on it.

**Acceptance Scenarios**:

1. **Given** a block tool with no guard and the default `:deny`, **When** it is called,
   **Then** the block does not run, the client gets a tool error naming `no_guard_declared`,
   and a row is recorded.
2. **Given** the same tool after `guard_with` is declared on the server's tool for that name,
   **When** the block reads through `scoped(...)`, **Then** the call is allowed and recorded.

---

### User Story 5 - Resolve the principal without recording secrets (Priority: P1, with Story 1)

The principal resolver needs what the transport knows (the SDK's server context and verified
access token; ActionMCP's session) to identify the human. Those can hold user objects and
tokens, which must never land in the ledger.

**Why this priority**: Without it, a host either cannot identify the principal on the SDK or
writes credentials into an append-only, tamper-evident table it cannot easily clean.

**Independent Test**: Call a guarded tool whose resolver reads the server context and access
token, then inspect the ledger row.

**Acceptance Scenarios**:

1. **Given** a resolver that reads the transport's request data, **When** a tool is called,
   **Then** the resolver can read it and the ledger row contains none of it.
2. **Given** an invocation has finished, allowed, denied or raised, **When** the next one
   starts on the same thread, **Then** nothing from the previous request's data is visible.
3. **Given** a host that passes `metadata:` itself, **When** the call is recorded, **Then**
   metadata is still recorded and redacted as in 0.9.0.

### Edge Cases

- A tool's output is `nil` or an empty response: treated like any other derived result; it
  needs `scoped(...)` unless the core's existing `nil` rule allows it. The spec does not
  invent a new rule for empty output.
- An SDK tool returns something other than the library's response object: the adapter does
  not convert it; the SDK's own handling applies after Reeve has checked it.
- ActionMCP halts a tool before `perform` (a `before_perform` callback, invalid input): the
  tool body never ran, so no envelope ran and no row is written. This matches fast-mcp, where
  schema validation runs before the tool too. Documented, not changed.
- ActionMCP's `request_input!` interrupts `perform` mid-way: the call ends with no output; it
  is recorded, and nothing it rendered before the interruption leaks.
- A tool subclassed from another guarded tool: inherits the guard, as in the core.
- An ActionMCP abstract base (`abstract!`) or the SDK's base tool class: carries the DSL but is
  not itself a tool the compliance suite asks about.
- A supported library version outside the tested range: the adapter refuses to load with a
  message naming the supported range, rather than guarding by guesswork.
- Both adapters, or an adapter and fast-mcp, loaded in one process: each guards its own
  tools; none wraps another library's tools. Exception found in implementation: fast-mcp
  ships files at the paths the SDK autoloads, so fast-mcp loaded first hides the SDK's
  classes; `reeve/mcp` then refuses to load with a message saying so (research R13).

## Requirements *(mandatory)*

### Functional Requirements

**Both adapters**

- **FR-001**: Each adapter MUST be opt-in by a single `require`, loaded only on request, and
  MUST NOT make its library a dependency of the core (Constitution IV).
- **FR-002**: Requiring an adapter when its library is missing MUST fail with a configuration
  error that names the library and points to `Reeve.invoke`, as the fast-mcp adapter does.
- **FR-003**: Every tool class of the library, whether defined before or after the adapter
  loads, MUST get the `guard_with` / `redact` DSL and have every call routed through the
  envelope, with no per-tool step beyond `guard_with`.
- **FR-004**: Loading an adapter more than once MUST NOT route a call through the envelope
  more than once.
- **FR-005**: `scoped(...)` and `authorize!` MUST be callable from wherever the library runs a
  tool's body (a class-level `call` on the SDK, the instance's `perform` on ActionMCP).
- **FR-006**: The adapters MUST treat the tool's whole output as a derived result: allowed
  only when the tool called `scoped(...)` during that invocation; otherwise denied
  `unscoped_derived_result`.
- **FR-007**: A denial MUST reach the client as a tool error in the library's own error shape,
  carrying the rule. It MUST NOT name or count records.
- **FR-008**: On a denial no part of the tool's output MAY reach the client.
- **FR-009**: A tool that raises MUST be recorded `tool_error` before the library handles the
  error, and the library's own error handling MUST then apply unchanged.
- **FR-010**: Write rollback on denial (0.9.0 behavior) MUST hold for tools on both adapters.
- **FR-011**: The tool's name in the registry and the ledger MUST be the name the library
  publishes to clients.
- **FR-012**: The adapter MUST record agent attribution from what the library knows about the
  client (client name/version from the session or request), falling back to `unknown`.
  Attribution MUST NOT affect authorization.
- **FR-013**: Each adapter MUST declare the library version range it was verified against and
  refuse to load outside it, naming the range.

**Official SDK**

- **FR-020**: A tool MUST receive exactly the arguments, including the server context keyword
  or its absence, that it would receive without Reeve.
- **FR-021**: Block-registered tools MUST be routed through the envelope like class tools, and
  MUST be guardable without rewriting them as classes.
- **FR-022**: The SDK adapter MUST run on every Ruby in Reeve's CI matrix that the SDK
  supports.

**ActionMCP**

- **FR-030**: The envelope MUST wrap the tool body inside ActionMCP's error handling, so a
  tool error or denial reaches the ledger before ActionMCP replaces it with a generic message.
- **FR-031**: Content a tool renders during a call MUST be held until the call is allowed, and
  discarded on denial.
- **FR-032**: The documented resolver for ActionMCP MUST be the user ActionMCP's gateway
  authenticated. The adapter MUST NOT set the principal itself; the resolver stays the one
  place that decides (README, "Wrapping your own JSON-RPC server").
- **FR-033**: Background-task calls MUST go through the envelope like any other, and with no
  resolvable principal MUST be denied `no_principal`.

**Core: request data for the resolver**

- **FR-040**: An invocation MUST be able to carry request data (transport context, verified
  access token, session) that the principal resolver can read.
- **FR-041**: That request data MUST NOT be written to the ledger, to `metadata`, to error
  messages, or to any output of the testing kit or inventory.
- **FR-042**: That request data MUST be cleared when the invocation ends, by the same
  guarantee that clears the principal.
- **FR-043**: `metadata:` MUST keep its 0.9.0 meaning: transport detail, recorded, redacted.
  Adapters MUST put only attribution-safe fields in it.

**Testing kit**

- **FR-050**: Matchers and the compliance suite MUST invoke a tool from either adapter the way
  its library does, without the host writing a custom `invoke:`.
- **FR-051**: A tool invoked by the testing kit MUST produce exactly one ledger row.
- **FR-052**: Both RSpec and Minitest front ends MUST give the same results for tools from
  either adapter (Constitution III).

**Documentation**

- **FR-060**: README MUST state, for these two adapters, that `guard_with` needs `scoped(...)`
  to return anything, and state the one-flag weakness in the words of "Not guaranteed"
  item 2.
- **FR-061**: README and CHANGELOG MUST name the verified version of each library and the Ruby
  and Rails each adapter needs.

### Key Entities

- **Adapter**: the opt-in bridge for one MCP library. Knows how that library names a tool,
  runs its body, reports a tool error, and identifies its client.
- **Request data**: per-invocation transport detail for the resolver only. Never recorded,
  cleared at the end of the call. Distinct from `metadata`, which is recorded.
- **Derived output**: whatever the tool's body produced for the client. Allowed or refused
  whole; never narrowed.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A host already on the official SDK guards a read tool with one `require`, one
  `guard_with` and one `scoped(...)`, and no other change to their server.
- **SC-002**: In the adapter specs, 0 denied calls on either library return any rendered
  content, and 0 ledger rows from either library contain request data (checked by searching
  every row for the values the specs put there).
- **SC-003**: Every acceptance scenario above has a passing spec; Story 1 on Ruby 3.0, 3.2 and
  3.4; Story 2 on 3.2 and 3.4.
- **SC-004**: The compliance suite runs against tools from all three adapters with the same
  host-written lines, under RSpec and Minitest, with identical results.
- **SC-005**: The packaged gem contains both adapters and its README makes no claim about
  them beyond "What this feature guarantees" (checked against the built `.gem`, not the tree).

## Assumptions

- Verified versions: `mcp` 1.9.0, `actionmcp` 0.202.0. The supported ranges are chosen in the
  plan from what those versions' internals allow; the SDK range can be wider because the
  adapter uses only its public tool interface.
- ActionMCP requires Rails 8.1 and so Ruby 3.2+; its specs are skipped on the 3.0 CI job, as
  fast-mcp's are, with the reason stated.
- Connection authentication stays with each library (SDK OAuth middleware, ActionMCP gateway).
  Reeve does not authenticate.
- Prompts and resources on either library are out of scope. Only tool calls are guarded, as
  on fast-mcp.
- Per-record narrowing of rendered output (for example, a helper that renders scoped records
  for the tool) is out of scope for this feature. It can be specified later if the one-flag
  weakness proves to matter in practice.
- Order of delivery: Story 1 and Story 5 first, released on their own if ready; Stories 2 and
  3 for ActionMCP after.
