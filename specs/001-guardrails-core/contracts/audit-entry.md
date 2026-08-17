# Contract: Audit Entry

**Stability**: public and **versioned** (FR-015). The entry shape is a compliance artifact;
downstream exports and SIEM mappings depend on it.

**Contract version**: `2`. Adding a nullable column is a MINOR change. Removing a column,
renaming one, or changing the meaning of a value is MAJOR.

Asserted by `Reeve::Checks::ContractVersion`, which compares both the column list and the
version against the host's table. Every bump moves the `contract_version` column, so the
column list catches a stale table even when the bump was purely semantic. A host may pass
`expected:` to pin the version its exports were built against.

Earlier revisions of this document claimed the version was "recorded in the initializer".
It never was; from contract 2 it is recorded on every row.

### Changes to the table must be additive

**A bump may add columns. It may not remove one, rename one, or narrow one — and a new
column must be nullable, or carry a default that is *true of the rows already written*.**

This is a consequence of what the table is, not a convenience. The ledger is append-only:
there is no honest value to backfill into a historical row, because nobody was there to
observe it. `contract_version` is the worked example — it defaults to `1` on an upgrade
because every row already in the table really was written under contract 1, and the
default is dropped afterwards so new rows must state their own.

Two things depend on this rule:

- `bin/rails generate reeve:upgrade` decides what to emit by asking the table which
  columns it has. A step that changes a column without adding one is invisible to that
  test and would need its own predicate.
- An upgraded ledger and a fresh install must reach the same shape, which is asserted by
  `spec/reeve/generators/upgrade_generator_spec.rb`. A destructive step makes the two
  paths diverge permanently, since the fresh one never had the column to destroy.

A change that genuinely cannot be expressed additively is a new table, not a new version
of this one.

### Migrating an existing ledger

`bin/rails generate reeve:upgrade && bin/rails db:migrate`. It emits only the steps the
host's table is missing and is a no-op on a current one. **Do not re-run `reeve:install`
to pick up a shape change**: Rails resolves a migration by name, so it emits nothing, or
offers to overwrite a migration that has already run — which does not touch the database
and destroys the record of what was applied.

### History

- **2** (2026-08-12) — Two changes, one bump.
  - `metadata` carries the transport detail the caller passed. Through version 1 it was
    written NULL on every row whatever was passed, so anything mapping version 1 rows
    could reasonably have read the column as always empty. What a value means changed,
    which this document's own rule makes MAJOR.
  - New `contract_version` column, non-null, stamped by the recorder. Version 1 rows
    could not name their own shape, which is what made the `metadata` change ambiguous to
    a reader in the first place: on a version 1 row a NULL `metadata` means "never
    recorded", on a version 2 row it means "the caller passed none". Every future bump is
    legible on the row rather than inferred from when it was written.

    **Breaking for custom recorders.** A host that configures `audit_recorder` and writes
    to `Reeve::Audit::Entry` must now set `contract_version`; the model rejects a row
    without it.
- **1** — initial shape.

## Shape

See [data-model.md](../data-model.md#auditentry--reeve_audit_entries) for the
column-level table. Contractual guarantees on top of it:

1. **Exactly one row per invocation.** `invocation_id` is unique; a retry that reuses the
   same id is a no-op insert, not a second row.
2. **Both outcomes recorded.** Denials are rows, not log lines (FR-008).
3. **`rule` is never null.** Every row explains itself (FR-009). Its companion `detail`
   carries the same explanation in words — "policy raised ArgumentError: owner_id is
   missing" — and is nullable, free-form and capped at 1000 characters. **Match on `rule`,
   read `detail`.** `detail` never names a record, so an out-of-scope denial stays
   indistinguishable from a record that does not exist (FR-006). Added 2026-08-11 as a
   nullable column, which the versioning rule below makes a MINOR change: contract
   version stays `1`.
4. **Arguments are post-redaction.** Names survive, declared-sensitive values do not
   (FR-011). No unredacted copy is written anywhere by this gem.
5. **`record_count` is the truth even when `record_ids` is truncated**; `truncated` marks
   it explicitly (FR-014). Identifiers are never silently dropped.
6. **`occurred_at` is invocation time, not write time** — ordering reflects what happened.
7. **No mutation API.** No public method updates or deletes an entry (FR-010).
8. **`metadata` is the caller's transport detail, post-redaction.** Whatever the adapter
   or the host passed as `metadata:` — headers, request ids, transport context — recorded
   through the same redactor as the arguments, so a declared-sensitive name is replaced
   wherever it appears, including nested. Nullable: a call that carried none records
   `NULL` rather than `{}`, so "carried nothing" stays distinguishable from "carried
   something that was emptied". Populated from contract version `2`.

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
