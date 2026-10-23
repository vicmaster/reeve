# Tasks: Ledger Key Epochs

Test-first per the constitution: each implementation task is preceded by the spec that fails
without it. `[US#]` maps to spec.md user stories.

## Phase 1 — Contract 4 shape

- [x] T001 Failing specs: `ContractVersion` expects 4 and `chain_epoch`; upgrade generator emits the contract-4 step on a contract-3 table, is idempotent, and converges with a fresh install [US5]
- [x] T002 `CONTRACT_VERSION = 4` + rule comment (`lib/reeve/audit.rb`); `ENTRY_FIELDS[4]` (`canonical.rb`); `ContractVersion` constants
- [x] T003 Install template: `chain_epoch` + `reeve_audit_chain_epochs`; upgrade step + template `add_key_epochs_to_reeve_audit_entries.rb.tt` + message
- [x] T004 `Chain::COLUMNS` + `require_columns!` also require the epochs table (FR-018) [US5]

## Phase 2 — Write path

- [x] T005 Failing specs: first contract-4 write opens epoch 0 at its sequence; a new configured key opens epoch 1; stragglers write under their earlier epoch; contract-3 rows through `append!` get no epoch; two writers with one new key make one epoch [US1, US4]
- [x] T006 `chain/epochs.rb` (`Epochs` read/open, epoch digest in `Canonical`), `append!` epoch step

## Phase 3 — Verification

- [x] T007 Failing specs: every US2 tamper case BROKEN with the named kind; US4 stragglers and missing-key cases not BROKEN; pre-epoch rows unchanged [US2, US4]
- [x] T008 `Verifier` loads/checks epochs; `Walk` applies FR-011; `Verification` kinds/status/epochs/JSON; `Report` epoch lines

## Phase 4 — Rotation task

- [x] T009 Failing specs: ROTATED / CURRENT / REFUSED (each reason), ACCEPT_UNVERIFIABLE, no-consume lock leaves no gap, no key value in output [US1, US3]
- [x] T010 `Head#lock!`, `Chain.rotate_key!`, `chain/rotation.rb`, `Tasks.rotate_ledger_key` + rake definition

## Phase 5 — Documentation

- [x] T011 specs/001 contracts/audit-entry.md: version 4, rule wording, history, guarantee 10
- [x] T012 CHANGELOG "Unreleased" with upgrade notes (FR-021); README rotation section via the task (FR-022)
- [x] T013 Full suite; README spec; rubocop
