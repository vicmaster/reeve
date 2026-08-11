# Contract: Audit Entry

**Stability**: public and **versioned** (FR-015). The entry shape is a compliance artifact;
downstream exports and SIEM mappings depend on it.

**Contract version**: `1`. Recorded in the initializer and asserted by the compliance suite.
Adding a nullable column is a MINOR change. Removing a column, renaming one, or changing the
meaning of a value is MAJOR.

## Shape

See [data-model.md](../data-model.md#auditentry--reeve_audit_entries) for the
column-level table. Contractual guarantees on top of it:

1. **Exactly one row per invocation.** `invocation_id` is unique; a retry that reuses the
   same id is a no-op insert, not a second row.
2. **Both outcomes recorded.** Denials are rows, not log lines (FR-008).
3. **`rule` is never null.** Every row explains itself (FR-009).
4. **Arguments are post-redaction.** Names survive, declared-sensitive values do not
   (FR-011). No unredacted copy is written anywhere by this gem.
5. **`record_count` is the truth even when `record_ids` is truncated**; `truncated` marks
   it explicitly (FR-014). Identifiers are never silently dropped.
6. **`occurred_at` is invocation time, not write time** — ordering reflects what happened.
7. **No mutation API.** No public method updates or deletes an entry (FR-010).

## Query interface (FR-013)

```ruby
Q = Reeve::Audit::Query

Q.for_principal(user)                       # => relation
Q.for_agent("claude-desktop")
Q.for_tool("InvoiceSearchTool")
Q.denied                                    # and .allowed
Q.between(1.week.ago, Time.current)

# composable, and the incident question answers in one chain:
Q.for_principal(user).for_agent("claude-desktop").between(1.week.ago, Time.current)
 .pluck(:tool_name, :record_type, :record_ids, :outcome, :rule)
```

Each scope maps to one of the composite indexes in data-model.md. The chain above is
SC-003's "single query, no log inspection".

## Non-guarantees (stated plainly)

- The gem does not prevent a database superuser or raw SQL from altering the table. It
  enforces immutability at the library level and documents the INSERT+SELECT grant that
  enforces it at the database level. It makes no stronger claim.
- No retention, rotation, or archival policy in v1 — the table is host-owned.
- No cryptographic chaining or tamper-evidence in v1. If it lands later it is additive
  (a nullable digest column), which this contract's versioning already permits.
