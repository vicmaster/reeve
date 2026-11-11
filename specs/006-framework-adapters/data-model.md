# Data Model: Framework Adapters

No schema change. The ledger table, its columns and the contract version are unchanged; a row
written through either adapter has the same shape as one written through fast-mcp.

## Context (changed)

| Field | Recorded | Change |
|---|---|---|
| `tool_name`, `arguments`, `agent`, `metadata`, `invoked_at`, `invocation_id` | yes | none |
| `principal` | yes (type and id) | none |
| `request` | **never** | **new.** Hash, default `{}`, symbol keys. Read by the principal resolver only. |

Invariants:

1. `request` is absent from `Context#to_h`, `#inspect`, `DeniedError` messages, ledger rows,
   testing-kit reports and inventory reports (FR-041).
2. `request` is cleared in the envelope's `ensure`, next to the principal, whatever the
   outcome (FR-042). After an invocation, `context.request == {}`.
3. A non-Hash `request:` raises `ArgumentError`, as `metadata:` does.

## What each adapter puts where

| | Official SDK | ActionMCP |
|---|---|---|
| `tool_name` | `tool.name_value` (what `tools/list` publishes) | `tool_name` (capability name) |
| `arguments` | the keyword arguments the tool receives, minus `server_context` | the tool's `attributes` |
| `agent` | from `server_context.client_info` | from `session.client_info` |
| `metadata` | `{ client: { name:, version: } }` | `{ client: { name:, version: } }` (no session id, see research R7) |
| `request` | `{ server_context:, auth_info: }` | `{ session:, execution_context: }` |
| output checked | the tool's return value | the buffered `ToolResponse` |

`agent.id` is the client name, `unknown` when absent. Attribution never affects a decision.

## Outcomes per adapter

| Envelope outcome | Ledger | Official SDK client sees | ActionMCP client sees |
|---|---|---|---|
| allow | `allow` | the tool's response | the buffered content, moved to the real response |
| deny (any rule) | `deny`, rule | `isError: true`, text = denial message | tool error, text = denial message |
| tool raised | `deny`, `tool_error` | SDK internal error (unchanged) | "An unexpected error occurred." (unchanged) |
| recorder failed | per `audit_failure_mode` | SDK internal error | ActionMCP generic error |
| pass-through (R11) | none from the adapter; the outer envelope records | as the outer caller decides | as the outer caller decides |
