# Data Model: reeve v1

**Date**: 2026-08-11 | **Feature**: 001-guardrails-core

## Runtime objects (not persisted)

### Context

The per-invocation carrier. Created by an adapter or by the caller of the plain interface;
never global, never reused between invocations.

| Field | Type | Notes |
|-------|------|-------|
| `principal` | any | The human/service the agent acts for. `nil` ⇒ deny (FR-001). |
| `agent` | Hash | Attribution only: `{ id:, name:, version: }`. Never a permission source. |
| `tool_name` | String | Registered name of the tool being invoked. |
| `arguments` | Hash | As received, before redaction. |
| `metadata` | Hash | Raw transport/server context an adapter passed through; opaque to the core. |
| `invoked_at` | Time | Set at envelope entry. |

Validation: `tool_name` required; `arguments` defaults to `{}`; `agent` defaults to
`{ id: "unknown" }` — an unidentifiable agent is recorded as unknown, never rejected, since
attribution is not authorization.

### Decision

The result of a policy evaluation. Immutable.

| Field | Type | Notes |
|-------|------|-------|
| `outcome` | Symbol | `:allow` or `:deny`. |
| `rule` | String | **Required, never nil.** What decided. |
| `detail` | String, nil | Human-readable context for error messages. |

Reserved rule identifiers for core deny paths (stable strings — the testing kit and hosts
match on them):

- `no_guard_declared` — tool has no `guard_with` (FR-004)
- `no_principal` — resolver returned nil or raised (FR-001)
- `policy_error` — policy raised (fail closed, FR-004)
- `unknown_record_type` — returned type has no policy (edge case)
- `unscoped_derived_result` — non-record return without `scoped(...)` (R4)
- `out_of_scope_record` — single-record fetch outside scope (FR-006)
- `audit_write_failed` — ledger write failed in default mode (FR-012)
- `tool_error` — the tool body raised after being allowed (added during T015; see below)

Policy-sourced rules use the adapter's own naming, e.g. `InvoicePolicy#index?` or
`InvoicePolicy::Scope`.

One reserved **allow** rule, kept separate from the deny list above:

- `unguarded_tool` — a tool with no `guard_with`, permitted because the host opted into
  `unguarded_tools = :allow_with_warning`. Recorded with `guard: "none"`.

**`tool_error` (added 2026-08-11, T015)**: when a policy allows an invocation and the tool
body then raises, the entry is recorded with `outcome: "deny"` and rule `tool_error`. The
authorization outcome was an allow, but no records reached the agent, and `outcome` answers
the operational question the ledger exists for — *did data go out?* The original exception
propagates to the caller untouched; only the ledger reinterprets it.

### ScopeResult

What a scoper returns to the envelope. Not persisted; it exists so the envelope reads
records out of the scoping step rather than out of the tool's return value, which is how
invariant 3 holds by construction.

| Field | Type | Notes |
|-------|------|-------|
| `decision` | Decision | Allow (rule `scoped`) or a deny carrying its own rule. |
| `records` | any | The value the caller receives. `nil` on a deny. |
| `record_type` | String, nil | Nil for derived results. |
| `record_ids` | Array<String> | Empty for derived results and denials. |
| `record_count` | Integer | True total; defaults to `record_ids.size`. |
| `truncated` | Boolean | Set by the scoper when it capped the identifiers. |
| `derived` | Boolean | The result came from `scoped(...)` rather than records. |

### GuardDeclaration

What `guard_with` records per tool, held in the registry.

| Field | Type | Notes |
|-------|------|-------|
| `tool_class` | Class | |
| `tool_name` | String | |
| `policy` | Class or object | Resolved through a policy adapter. |
| `action` | Symbol | Defaults to `:index`; overridable per tool. |
| `redacted_arguments` | Array<Symbol> | Merged with the global redaction list. |

### Registry

Process-wide set of `GuardDeclaration`s, keyed by tool class. Feeds the shared compliance
suite (FR-018) and `audit_every_call` (FR-017). Registration happens at class-definition
time via the DSL; the registry is enumerable and resettable in tests.

## Persisted entity

### AuditEntry — `reeve_audit_entries`

Append-only. One row per guarded invocation, allowed or denied (FR-008).

| Column | Type | Null | Notes |
|--------|------|------|-------|
| `id` | bigint PK | no | |
| `invocation_id` | uuid | no | Unique per invocation; the idempotency key that makes "exactly one row" checkable. Unique index. |
| `occurred_at` | datetime | no | From `Context#invoked_at`, not write time. |
| `agent_id` | string | no | `"unknown"` when unidentifiable. |
| `agent_name` | string | yes | |
| `principal_type` | string | yes | Null only on `no_principal` denials. |
| `principal_id` | string | yes | String, not bigint — hosts use UUIDs and composite ids. |
| `tool_name` | string | no | |
| `arguments` | json | no | Post-redaction (FR-011). |
| `outcome` | string | no | `"allow"` or `"deny"`. |
| `rule` | string | no | From `Decision#rule`; never null (FR-009). |
| `detail` | text | yes | From `Decision#detail`: why the rule fired, in words. Free-form and capped at 1000 characters — hosts match on `rule`, humans read `detail`. Never names a record (FR-006). Added 2026-08-11; a nullable column, so the contract version stays 1. |
| `record_type` | string | yes | Dominant returned type; null for derived/empty results. |
| `record_ids` | json | no | Array; `[]` for denials and empty results. |
| `record_count` | integer | no | True total, even when `record_ids` is truncated. |
| `truncated` | boolean | no | Default false; true when `record_count > max_recorded_ids` (FR-014). |
| `derived` | boolean | no | Default false; true when the result was a value derived via `scoped(...)` rather than records (R4). |
| `guard` | string | no | `"policy"`, or `"none"` when running in `:allow_with_warning` mode (R9). |
| `duration_ms` | integer | yes | Envelope wall time. |
| `metadata` | json | yes | The transport detail the caller passed as `metadata:` — headers, request ids — post-redaction, by the same redactor and declared names as `arguments`. Null when the caller passed none. Written NULL unconditionally through contract 1; populated from contract 2. |
| `contract_version` | integer | no | The audit-entry contract this row was written under, stamped by the recorder from `Audit::CONTRACT_VERSION`. Lets an export be read correctly across an upgrade instead of guessing which rules applied to a row. Added at contract 2. |

Indexes: unique on `invocation_id`; composite on `(principal_type, principal_id, occurred_at)`
and `(tool_name, occurred_at)` and `(agent_id, occurred_at)` and `(outcome, occurred_at)` —
one per FR-013 query axis.

**Immutability rules** (FR-010):
- Model defines `readonly?` ⇒ true after persistence, so `update`/`save` raise.
- `before_destroy { throw :abort }`.
- No public library method accepts an entry id for mutation.
- Documentation recommends granting the app role INSERT + SELECT only. The gem states
  plainly that it cannot prevent raw SQL and does not claim to.

**Retention**: none in v1. The table is host-owned; the host's existing policies apply
(spec Assumptions).

## Invocation state transitions

```text
                       ┌──────────────────────────────────────────┐
 receive invocation ──▶│ resolve principal                        │
                       └───────┬──────────────────────────┬───────┘
                          nil/raise                    resolved
                               │                          │
                               ▼                          ▼
                    Deny(no_principal)        ┌──────────────────────┐
                               │              │ look up guard        │
                               │              └──┬───────────────┬───┘
                               │            absent           present
                               │                │               │
                               │                ▼               ▼
                               │   Deny(no_guard_declared)  ┌─────────────────┐
                               │   *or* Allow(guard:"none") │ policy authorize │
                               │    if :allow_with_warning  └──┬───────────┬──┘
                               │                │           deny        allow
                               │                │             │            │
                               │                │             ▼            ▼
                               │                │      Deny(rule)   ┌──────────────┐
                               │                │             │     │ execute tool │
                               │                │             │     └──────┬───────┘
                               │                │             │            ▼
                               │                │             │     ┌──────────────┐
                               │                │             │     │ scope result │──┐
                               │                │             │     └──────┬───────┘  │ filtered on
                               │                │             │            │ ok       │ single fetch
                               │                │             │            │          ▼
                               │                │             │            │   Deny(out_of_scope_record)
                               ▼                ▼             ▼            ▼          │
                       ┌────────────────────────────────────────────────────────────┐ │
                       │ write exactly one AuditEntry (redacted args)               │◀┘
                       └───────┬────────────────────────────────────┬───────────────┘
                          write ok                            write failed
                               │                                    │
                               ▼                    default: raise AuditWriteError (rule
                    return records / raise DeniedError    audit_write_failed); :warn: log on

**Corrected 2026-08-11**: an earlier version of this diagram said a failed ledger write
produced a `Deny(audit_write_failed)` row. It cannot — the ledger is the thing that just
failed, so there is nowhere to write that row. The invocation raises `AuditWriteError`
instead, and that error carries `rule == Decision::AUDIT_WRITE_FAILED` so a host can match
on it the same way it matches any other rule. In `:warn` mode the failure is logged and the
call continues, which is the whole point of opting into it.
```

Invariants the tests pin:
1. Every path through the diagram terminates in exactly one `AuditEntry` write attempt.
2. Every terminal `Deny` carries a non-nil `rule`.
3. No path returns records without having passed through `scope result`.
4. Principal state set on the context is cleared in an `ensure`, so nothing leaks to the
   next invocation on the same thread.
