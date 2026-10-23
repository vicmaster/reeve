# Implementation Plan: Ledger Key Epochs

**Branch**: `003-ledger-key-epochs` | **Date**: 2026-10-23 | **Spec**: [spec.md](spec.md)

## Summary

Record each key that signs the ledger as a numbered **epoch** (new table
`reeve_audit_chain_epochs`, each record HMAC'd by its own key and linked to the previous
epoch or the genesis), stamp every contract-4 chained entry with `chain_epoch` inside its
digest, teach the verifier the epoch rules (three new break kinds, a per-epoch summary), and
add `bin/rails reeve:rotate_ledger_key`. The audit-entry contract goes 3 → 4 (MAJOR; the
rationale is in spec.md Clarifications). Writes never wait for the task: a configured key that
has not yet opened an epoch opens one on its first write.

## Technical Context

**Language/Version**: Ruby 3.0+, Rails 7.0+ (unchanged)
**Primary Dependencies**: ActiveRecord; OpenSSL HMAC-SHA256 (unchanged)
**Storage**: SQLite, PostgreSQL, MySQL via ActiveRecord (the specs/002 support matrix)
**Testing**: RSpec; `DB=` selects the engine (spec/support/optional/database.rb)
**Project Type**: Library (gem)
**Performance Goals**: one indexed point read added per chained write (SC-004); verification
adds one query for all epochs (FR-014)
**Constraints**: no change to any row already written; one writer at a time per chain record
(the specs/002 lock); no key value ever printed
**Scale/Scope**: epochs are few (rotations), entries are many — epoch records are loaded
whole, entries are walked in batches as today

## Constitution Check

| Principle | Check | Result |
|---|---|---|
| I. Deny by Default | No authorization path touched. | Pass |
| II. Every Call Leaves a Trace | No write path drops a row: a write with a new key opens an epoch rather than failing (FR-004/005); the `:warn` unchained path is unchanged. | Pass |
| III. Provable by Test | Every rule ships with a failing-first spec; hosts assert it through the existing `LedgerChain` check (it runs verification, which now enforces epochs) and `ContractVersion` (expects 4). | Pass |
| IV. Extension Layer | No MCP-server code touched. | Pass |
| V. Clean-Room | Prior art consulted is public (CloudTrail, C2SP signed-note, Rails encryption docs); no names or shapes copied. | Pass |
| VI. Boring DX | One new task, zero new configuration (rotation uses the existing `ledger_key` / `retired_ledger_keys`). An `ACCEPT_UNVERIFIABLE` env var on the task is the only new knob, and only for the lost-key case. | Pass |
| Cost discipline | "Estimated token cost is announced and approved BEFORE any multi-agent workflow is launched… research uses direct web search or a single agent at most." The pipeline run that builds this feature was requested explicitly by the maintainer with a written budget; one research agent was used. | Pass, noted |

Post-design re-check: unchanged.

## Design

### Write path (`Chain#append!`)

Inside the existing locked savepoint, after `head.advance!`:

1. If the row's `contract_version` is below 4 (a custom recorder writing contract 3), link it
   exactly as 0.6.0 does — no epoch.
2. Otherwise `Epochs#for_signing!(connection, keyring, sequence:, genesis_digest:)`:
   `SELECT epoch FROM reeve_audit_chain_epochs WHERE key_id = ?` (unique index); if absent,
   read `MAX(epoch)` and the latest digest and insert epoch `max + 1` (or 0) with
   `first_sequence = sequence`. Same connection, same savepoint.
3. Stamp `chain_epoch`, compute the digest over `ENTRY_FIELDS[4]`, insert, move the head.

Because the head UPDATE is taken first, two writers with the same new key serialize; the second
finds the first's epoch. The unique index on `key_id` is the backstop.

### Rotation (`Chain.rotate_key!`)

1. Refuse with no `ledger_key`.
2. `head.start!` (start the chain if needed), then lock without consuming a sequence:
   `UPDATE reeve_audit_chains SET head_sequence = head_sequence WHERE name = ?`.
3. Read all epochs. Configured key opened the latest → CURRENT (+ warning if the previous
   epoch's key is not held). Opened an earlier one → REFUSED (`:key_reused`). Latest epoch's key
   not held and not `accept_unverifiable` → REFUSED (`:outgoing_key_missing`). Else insert epoch
   `max + 1` (or 0), `first_sequence = head_sequence + 1` → ROTATED.

### Verification

`Verifier` loads epochs once (`Epochs.load`), checks the records (FR-010), passes an
`EpochIndex` to `Walk`, which applies FR-011 per row before its digest check. `Verification`
gains `epochs` (an array of `EpochSummary`) and `before_first_epoch`; `Report` appends one line
per epoch; JSON gains the two keys. `status_for` treats the three new kinds as breaks.

### Canonical form

`ENTRY_FIELDS[4] = ENTRY_FIELDS[3] + ["chain_epoch"]`, entry tag unchanged (`reeve-ledger-entry-v1`
— the field list is already selected by contract version, which is inside the digest).
`EPOCH_TAG = "reeve-ledger-epoch-v1"`, `EPOCH_FIELDS = %w[epoch key_id first_sequence opened_at]`
plus `previous_digest`, same `dump`/`hmac` helpers.

## Project Structure

### Documentation (this feature)

```text
specs/003-ledger-key-epochs/
├── spec.md, plan.md, research.md, data-model.md, quickstart.md, tasks.md
├── contracts/audit-entry-v4.md     # delta to specs/001 contracts/audit-entry.md
├── contracts/key-rotation.md       # task + library API + verification additions
└── checklists/requirements.md
```

### Source Code

```text
lib/reeve/audit.rb                          CONTRACT_VERSION 4 + rule comment
lib/reeve/audit/chain.rb                    append! epoch step, rotate_key!, COLUMNS, require_columns!
lib/reeve/audit/chain/canonical.rb          ENTRY_FIELDS[4], epoch digest
lib/reeve/audit/chain/epochs.rb             NEW: reading/opening epoch records, EpochIndex
lib/reeve/audit/chain/rotation.rb           NEW: Rotation value + text
lib/reeve/audit/chain/head.rb               lock! (no-consume lock)
lib/reeve/audit/chain/walk.rb               epoch rules per row
lib/reeve/audit/chain/verifier.rb           load + check epochs
lib/reeve/audit/chain/verification.rb       kinds, status, epochs summary, JSON
lib/reeve/audit/chain/report.rb             epoch lines
lib/reeve/tasks.rb                          rotate_ledger_key + rake definition
lib/reeve/testing/checks/contract_version.rb  EXPECTED_VERSION 4, column
lib/generators/reeve/upgrade/…              contract-4 step + template
lib/generators/reeve/install/templates/create_audit_entries.rb.tt   contract-4 shape
specs/001-guardrails-core/contracts/audit-entry.md   version 4, rule wording, history
CHANGELOG.md, README.md
spec/reeve/audit/chain/epochs_spec.rb, rotation_spec.rb (NEW) + touched specs
```

## Delivery Order

1. Contract 4 shape: constant, canonical list, schema (install + upgrade), column guards, specs
   that fail first (ContractVersion, generator convergence).
2. Write path epochs (US1 scenario 3, US4 scenario 1).
3. Verification rules (US2, US4) — tamper specs first.
4. Rotation task (US1, US3).
5. Reporting (FR-013).
6. Docs: contract doc, CHANGELOG upgrade notes, README.

## Risks

- **False BROKEN during legitimate operation** — the worst failure for an audit tool (specs/002
  made the same call for rolling deploys). Mitigated by straggler semantics and by checking
  contract-3 rows structurally only when their key is absent. Verifier brief must try to break SC-003.
- **No-consume lock on SQLite**: an `UPDATE … SET x = x` must still take the write lock. If it does
  not on some engine, use the same increment-free UPDATE on a different column. Covered by a
  concurrency spec.
- **Existing output specs** pin the text report; adding epoch lines changes multi-epoch output
  only, but every contract-4 ledger has at least epoch 0. Decision: print epoch lines only when
  there are two or more epochs or any epoch is not `verified` — a single verified epoch adds
  nothing a reader needs (recorded as a build-time decision for the verifier).

## Complexity Tracking

| Addition | Why needed | Simpler alternative rejected because |
|---|---|---|
| New table | Epoch records must be write-once and few; entries must not carry rotation metadata twice | Columns on the chain record hold only the latest epoch; history is the point |
| Per-entry `chain_epoch` (contract bump) | Anchors the registry inside every digest | Registry-only can be deleted wholesale, silently reverting to 0.6.0 semantics |
