# Feature Specification: mcp-guardrails v1 — Authorization, Audit, Testing Kit

**Feature Branch**: `001-guardrails-core`
**Created**: 2026-08-11
**Status**: Draft
**Input**: User description: "mcp-guardrails v1: per-record authorization, append-only audit ledger, and testing kit for Rails MCP tools"

## Overview

A Rails application that exposes MCP tools to AI agents can today authenticate the
connection but cannot answer two questions: *what may this agent see, for the specific
human it is acting for?* and *what did it actually see?* mcp-guardrails is a library the
application adds to answer both, plus a testing kit that turns those answers into CI
assertions.

The consumers of this feature are **Rails application developers** exposing MCP tools,
and the beneficiaries are the **security, compliance, and support people** at their
organizations who must later explain agent behavior.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Scope every tool call to the acting human (Priority: P1)

A developer has an MCP tool that returns invoices. Today it returns whatever the tool's
code queries. They declare which policy governs the tool and how to find the principal —
the human on whose behalf the agent is acting — and from then on the tool only ever
returns invoices that principal is permitted to see. A tool with no declaration returns
nothing and reports why.

**Why this priority**: This is the core safety guarantee. Without it, the audit ledger
merely records the breach and the testing kit has nothing to assert. It is also the only
story that delivers value entirely on its own.

**Independent Test**: Register a guarded tool in a test application with two principals
owning different records; invoke the tool as each principal and confirm each sees only
their own records, and that an unguarded tool returns nothing.

**Acceptance Scenarios**:

1. **Given** a tool guarded by a policy and a principal who owns 3 of 10 records, **When**
   the agent invokes the tool for that principal, **Then** exactly those 3 records are
   returned and the other 7 are absent from the result.
2. **Given** a tool guarded by a policy, **When** the agent invokes it for a principal the
   policy denies entirely, **Then** the call is denied, no records are returned, and the
   error names the tool, the principal, and the rule that denied it.
3. **Given** a tool with no guard declaration, **When** it is invoked through the
   guardrails layer, **Then** the call is denied by default and the message states that no
   guard is declared.
4. **Given** a guarded tool invoked with no resolvable principal, **When** the call runs,
   **Then** it is denied without consulting the policy.
5. **Given** a policy that raises an unexpected error, **When** the call runs, **Then** the
   call is denied (fail closed) and the error is surfaced, not swallowed.
6. **Given** a tool that acts on a single record by identifier, **When** the identifier
   refers to a record outside the principal's scope, **Then** the call is denied and does
   not disclose whether the record exists.

---

### User Story 2 - Answer "why did the AI expose that?" (Priority: P2)

After an incident or an audit request, a compliance reviewer needs to know which agent,
acting for which human, called which tool with which arguments, what came back, and
whether it was allowed or denied and by what rule. They query one ledger and get the
answer, including denied attempts.

**Why this priority**: Delivers value on top of Story 1 and is the second half of the
product promise, but a ledger over unscoped calls records the wrong thing — so it follows
authorization.

**Independent Test**: Invoke a mix of allowed and denied tool calls in a test application,
then query the ledger and confirm every call produced exactly one entry with the required
fields, and that no library-provided means exists to alter or remove an entry.

**Acceptance Scenarios**:

1. **Given** an allowed tool call, **When** it completes, **Then** exactly one ledger entry
   exists recording agent, principal, tool, arguments, identifiers of the records
   returned, the allow outcome, the deciding rule, and the time.
2. **Given** a denied tool call, **When** it completes, **Then** a ledger entry exists with
   the deny outcome and the deciding rule, and no record identifiers.
3. **Given** a set of existing entries, **When** the reviewer looks for a way to change or
   delete one through the library, **Then** none is provided.
4. **Given** arguments containing values the application has marked sensitive, **When** the
   entry is written, **Then** those values are redacted in the ledger while the argument
   names remain.
5. **Given** the ledger write fails, **When** the call runs in the default mode, **Then**
   the call fails rather than completing unrecorded.
6. **Given** a reviewer with a principal identifier, **When** they query the ledger for
   that principal over a time range, **Then** they get every call made on that principal's
   behalf in that range.

---

### User Story 3 - Prove the guarantees in CI (Priority: P3)

A developer adds assertions to their own test suite that fail the build if a tool ever
leaks across principals or a call goes unrecorded. They can assert a single tool's
behavior directly, or include a shared compliance suite that checks every registered
guarded tool at once.

**Why this priority**: Converts the guarantees into something continuously enforced rather
than a one-time verification. Depends on both prior stories existing to assert against.

**Independent Test**: In a test application with one correctly guarded tool and one
deliberately leaky tool, run the provided assertions and confirm they pass for the first
and fail with a clear message for the second.

**Acceptance Scenarios**:

1. **Given** a tool that leaks another principal's records, **When** the developer asserts
   that it denies access for that other principal, **Then** the assertion fails and names
   the leaked record identifiers.
2. **Given** a correctly guarded tool, **When** the same assertion runs, **Then** it passes.
3. **Given** a tool that bypasses the guardrails layer, **When** the developer asserts that
   every call is audited, **Then** the assertion fails and names the unaudited tool.
4. **Given** an application with several guarded tools, **When** the shared compliance suite
   is included in its test suite, **Then** every registered guarded tool is checked without
   the developer writing a test per tool.
5. **Given** a failing assertion, **When** the developer reads the failure message, **Then**
   it states the tool, the principals involved, and what was expected versus what happened.

---

### User Story 4 - Adopt it in an existing MCP server in minutes (Priority: P4)

A developer already running an MCP server in Rails installs the library, runs one
generator that creates configuration and the ledger table, adds one declaration per tool,
and is protected — without switching MCP server libraries or rewriting tools.

**Why this priority**: Adoption ergonomics decide whether the other three stories ever
reach anyone, but they are refinement of an already-working core.

**Independent Test**: Starting from a sample Rails application using a supported MCP server
library with unguarded tools, follow the documented three steps and confirm the tools
become guarded and audited with no other changes.

**Acceptance Scenarios**:

1. **Given** a Rails application, **When** the developer runs the install generator, **Then**
   a configuration file and a ledger table migration are created and the migration applies
   cleanly.
2. **Given** an existing tool class, **When** the developer adds a single guard declaration,
   **Then** that tool is scoped and audited with no other code change.
3. **Given** an application using a supported MCP server library, **When** guardrails are
   installed, **Then** existing unguarded tools keep working or fail closed according to a
   documented, configurable setting — and the chosen behavior is stated at install time.
4. **Given** an application using none of the supported server libraries, **When** the
   developer uses the library directly, **Then** the guarantees still hold through a
   documented plain interface.

---

### Edge Cases

- A tool returns records of several different types in one response — each type is scoped
  by its own policy, and an unpoliced type denies the call.
- A tool returns an aggregate (a count, a sum) rather than records — the aggregate must be
  computed over the scoped set, and the ledger records that the result was derived rather
  than listing identifiers.
- A tool returns nothing because the principal legitimately has no matching records —
  recorded as an allowed call with zero identifiers, distinct from a denial.
- A very large result set — the ledger must not become unusable; record identifiers up to a
  documented limit and mark that the list was truncated, never silently.
- The same agent acts for different principals in quick succession — principal state must
  not leak between calls, including under concurrency.
- Nested or chained tool calls — each invocation is scoped and recorded on its own.
- The principal is deactivated or their permissions change mid-session — the next call is
  evaluated against current permissions, not those cached at connection time.
- A denied call must not leak existence information through error text or timing detail.
- The application has no MCP server library loaded at all — the library must still load and
  its non-integration behavior must still work.

## Requirements *(mandatory)*

### Functional Requirements

**Authorization**

- **FR-001**: The system MUST require every guarded tool invocation to carry an explicit
  principal, and MUST deny the invocation when no principal can be resolved.
- **FR-002**: The system MUST allow a developer to declare, per tool, the policy that
  governs it, using a single declaration in the tool.
- **FR-003**: The system MUST filter records returned by a guarded tool through the
  principal's permitted scope, such that no record outside that scope appears in the result.
- **FR-004**: The system MUST deny by default: a tool with no declaration, an unresolvable
  principal, an unknown record type, or a policy error all result in denial with no records.
- **FR-005**: The system MUST support both a widely-used Ruby policy convention and plain
  policy objects, without requiring any particular authorization library.
- **FR-006**: The system MUST report, for every denial, the tool, the principal identifier,
  and the specific rule that produced the denial, without disclosing whether an
  out-of-scope record exists.
- **FR-007**: The system MUST evaluate permissions at invocation time rather than caching
  them for the lifetime of a connection or session.

**Audit**

- **FR-008**: The system MUST append exactly one ledger entry per guarded invocation,
  covering both allowed and denied outcomes.
- **FR-009**: Each entry MUST record: acting agent identity, principal identity, tool name,
  invocation arguments, identifiers of records returned, outcome (allow or deny), the
  deciding rule, and the time of the call.
- **FR-010**: The system MUST NOT expose any means of updating or deleting ledger entries.
- **FR-011**: The system MUST redact argument values the application has declared sensitive,
  while preserving the argument names.
- **FR-012**: The system MUST, by default, fail the invocation if the ledger entry cannot be
  written, and MUST require an explicit opt-in for any degraded mode.
- **FR-013**: The system MUST provide a documented way to query the ledger by principal, by
  agent, by tool, by outcome, and by time range.
- **FR-014**: The system MUST truncate over-large record identifier lists at a documented
  limit and mark the entry as truncated rather than silently dropping identifiers.
- **FR-015**: The system MUST provide a generator that creates the ledger table, and MUST
  document the entry shape as a stable, versioned contract.

**Testing kit**

- **FR-016**: The system MUST provide assertions that a given tool denies access for a
  principal other than the record owner, failing with the leaked identifiers named.
- **FR-017**: The system MUST provide an assertion that every invocation of a given tool or
  server produces a ledger entry, failing with the unaudited tool named.
- **FR-018**: The system MUST provide a shared compliance suite that a host application can
  include once to check every registered guarded tool.
- **FR-019**: Failure messages MUST state the tool, the principals involved, and expected
  versus actual outcome.
- **FR-020**: The testing kit MUST be usable without a running MCP client or network access.
- **FR-026**: The checks underlying the testing kit MUST be expressible independently of any
  test framework, and MUST be usable from the two testing frameworks in common use in Rails
  applications as well as from plain Ruby (a script, a task, or a startup assertion). No
  guarantee may be provable in one framework only.

**Adoption**

- **FR-021**: The system MUST provide an install generator producing a configuration file
  and the ledger migration.
- **FR-022**: The system MUST integrate with at least one widely-used Ruby MCP server
  library at v1, and MUST NOT require any specific server library in order to function.
- **FR-023**: The system MUST let the application choose, explicitly at install time, whether
  pre-existing unguarded tools are blocked or permitted, and MUST document the default.
- **FR-024**: The system MUST load and behave correctly when no MCP server library is present.
- **FR-025**: Every public entry point MUST ship with a runnable example in documentation.

### Key Entities

- **Principal**: The human (or service account) on whose behalf the agent acts. Identified
  stably; carries the permissions that determine scope. Not the agent.
- **Agent**: The AI client making the call. Identified for attribution; never the source of
  permissions.
- **Guarded tool**: A tool declared to be governed by a policy. Has a name, a policy
  association, and the record types it can return.
- **Policy decision**: The outcome of evaluating a principal against a tool and, where
  relevant, a record — allow or deny, plus the identifying rule.
- **Ledger entry**: The append-only record of one invocation. Holds agent, principal, tool,
  arguments (redacted where declared sensitive), returned record identifiers, outcome,
  deciding rule, truncation flag, and timestamp.
- **Compliance suite**: The reusable set of checks a host application runs against all of
  its registered guarded tools.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a reference application with two principals and a shared record set, 100%
  of guarded tool invocations return only records belonging to the invoking principal, over
  every tool and both principals.
- **SC-002**: 100% of guarded invocations — allowed and denied — appear in the ledger; zero
  invocations complete unrecorded in default mode.
- **SC-003**: A reviewer can answer "which records did this agent expose for this person
  last week, and under what rule?" with a single ledger query, with no application log
  inspection.
- **SC-004**: A developer starting from an existing MCP server can complete install,
  migration, and guarding of a first tool in under 15 minutes following documentation only.
- **SC-005**: Guarding a tool that already exists requires exactly one added declaration and
  no change to the tool's own logic, for every tool in the reference application.
- **SC-006**: Every misconfiguration listed in the edge cases produces a denial, never a
  silent pass — verified by a test per case.
- **SC-007**: The testing kit detects a deliberately introduced cross-principal leak and a
  deliberately introduced audit bypass, in each case failing the build with a message that
  names the offending tool.
- **SC-008**: The library loads successfully in an application with no MCP server library
  and no policy library installed.
- **SC-009**: Every guarantee the testing kit can assert is assertable from either common
  Rails testing framework and from plain Ruby, verified by running the same check suite
  through all three front-ends against the same fixtures with identical outcomes.

## Assumptions

- The host application already authenticates the MCP connection and can identify the agent
  and the human it acts for; establishing that identity is out of scope here.
- The host application already has, or is willing to write, policy objects expressing who
  may see what; this feature bridges to them rather than replacing them.
- Records are persisted through the application's ordinary data layer and are queryable as
  scopes; in-memory-only or external-API-backed resources are supported only through the
  documented plain interface, not automatic scoping.
- The ledger lives in the host application's own database as a table it owns, so retention
  and export follow the host's existing policies; the library provides no retention policy
  of its own in v1.
- v1 targets one MCP server library integration plus a plain interface; additional
  integrations are follow-on work, not part of this feature.
- The testing kit is framework-neutral at its core and ships front-ends for both testing
  frameworks in common use in Rails applications. A team must never have to adopt a second
  test framework to prove its guardrails hold — that would defeat the purpose of shipping
  the checks at all.
- Real-time alerting, dashboards, and a UI over the ledger are out of scope for v1 — the
  deliverable is a queryable ledger, not a console.
- Rate limiting, cost control, and prompt-injection defense are out of scope; this feature
  governs access and record-keeping only.
