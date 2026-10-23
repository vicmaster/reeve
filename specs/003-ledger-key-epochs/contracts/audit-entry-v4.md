# Contract delta: audit entry, version 3 → 4

Applied to `specs/001-guardrails-core/contracts/audit-entry.md`, the single document describing
the entry shape.

## Version

`3` → `4`. **MAJOR**, by that document's rule as amended here: one nullable column, but
(a) what its absence means differs by contract (on a contract-3 row NULL `chain_epoch` means
"before key epochs"; a contract-4 chained row always has one), and (b) `chain_digest` on a
contract-4 row covers `chain_epoch`, so its meaning changes.

## Rule wording to amend

> Adding a nullable column is a MINOR change — **unless what its absence means, or what an
> existing value covers, differs between rows written before and after it; that is MAJOR, and
> contracts 3 and 4 are both examples.** Removing a column, renaming one, or changing the
> meaning of a value is MAJOR.

## History entry to add

> - **4** (specs/003) — Key epochs. New nullable column `chain_epoch`, inside the digest; new
>   table `reeve_audit_chain_epochs`. MAJOR: see the rule. Existing rows are not touched;
>   chained rows written before the first epoch keep contract-3 semantics.
>   **For custom recorders**: rows passed to `Reeve::Audit::Chain#append!` at contract 4 are
>   stamped automatically; rows passed at contract 3 are chained as before, without an epoch.

## Guarantee to add

> 10. **Chained entries name their key epoch.** Every contract-4 chained row records the epoch
>     whose key signed it. Verification reports a row whose key or epoch does not match the
>     epoch records as tampering. Rows chained before the first epoch keep guarantee 9 as it
>     was.
