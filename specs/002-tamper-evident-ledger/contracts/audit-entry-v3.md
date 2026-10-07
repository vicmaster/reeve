# Contract delta: audit entry, version 2 → 3

This is the change set to apply to `specs/001-guardrails-core/contracts/audit-entry.md`,
which remains the single document describing the entry shape. It is written as a delta so
the review sees exactly what moves.

## Version

`2` → `3`. **MAJOR**, by that document's own rule: the shape change is additive (three
nullable columns), but **what an absence means changes**. On a contract 1–2 row a NULL
digest means "written before chaining". On a contract-3 row it means the row was written
unchained, which verification reports as a break.

## History entry to add

> - **3** — Entries are chained. New nullable columns `chain_sequence`, `chain_key_id`,
>   `chain_digest`; new table `reeve_audit_chains` holding the genesis and the head.
>   Existing rows are not touched and remain uncovered. **Breaking for custom recorders**
>   that write to `Reeve::Audit::Entry`: rows at contract 3 must be written through
>   `Reeve::Audit::Chain#append!`, or verification reports them as unchained.

## Shape: guarantees to add

> 9. **Chained entries are tamper-evident, within stated limits.** Every contract-3 row
>    written with a key carries a sequence number, the fingerprint of the key that signed
>    it, and a keyed digest linking it to its predecessor. Verification detects a changed,
>    removed, reordered or inserted chained row, and removal of the chain record, provided
>    the attacker does not hold the key. It does **not** detect: use of a compromised key;
>    removal of the newest rows together with a rewind of the head; deletion of the whole
>    ledger; anything about rows written before contract 3.

## "What it does not" — lines to replace

In the contract, in `lib/reeve/audit.rb`, and in the install migration's header comment:

> ~~No cryptographic chaining or tamper-evidence in v1. If it lands later it is additive
> (a nullable digest column), which this contract's versioning already permits.~~

becomes:

> Tamper-*evidence*, not tamper-*proofing*: chaining detects changes after the fact and
> prevents nothing; the database grant remains the control that prevents. The chain's
> limits are listed in guarantee 9. A role with `UPDATE` on `reeve_audit_chains` can rewind
> the head, which is one of them.

## Grants to document (migration comment)

```sql
-- the ledger: unchanged
GRANT INSERT, SELECT ON reeve_audit_entries TO app_role;
-- the chain record: the head moves on every write
GRANT INSERT, SELECT, UPDATE ON reeve_audit_chains TO app_role;
```
