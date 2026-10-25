# Tasks: Ledger Anchoring

**Input**: spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md in
`specs/004-ledger-anchoring/`

Test-first per the constitution (III): each implementation task follows the spec that fails
without it, and each detection spec sits beside a twin that pins the 0.7.0 limit without a
checkpoint (SC-001). Every chain spec runs on SQLite locally and on PostgreSQL and MySQL in CI.
`[P]`: different files, no dependency on an unfinished task. `[US#]`: spec.md user story.

## Phase 1: Setup

- [x] T001 Add `Reeve::CheckpointError < Error` (message names the checkpoint's position in its list) to `lib/reeve/errors.rb`, with a case in `spec/reeve/errors_spec.rb`
- [x] T002 [P] Add raw-SQL tamper helpers to `spec/reeve/audit/support/ledger.rb`: `Ledger.truncate_tail!(after:)` (delete entries past a sequence and rewind `head_sequence`/`head_digest` to the entry left), `Ledger.empty!` (delete every row of the entries, chain and epochs tables), `Ledger.delete_epoch!(number)`, all bypassing the models

---

## Phase 2: Foundational (blocks every story)

**Purpose**: a checkpoint can be made, signed, stored, parsed and handed to verification. No detection yet.

- [x] T003 [P] Failing specs in `spec/reeve/audit/chain/checkpoint_spec.rb`: a checkpoint's line has exactly the data-model fields plus `signature`, keys sorted, no entry content and no key value (FR-004); the signature matches contracts/checkpoint-v1.md recomputed by hand; parsing round-trips; parsing refuses a missing field, an extra field, a wrong type, an unknown `format`, and `epoch` without `epoch_digest`, each with `CheckpointError`
- [x] T004 [P] Failing specs in `spec/reeve/audit/file_anchor_spec.rb`: `publish` appends one line and never truncates (existing content kept byte for byte); two processes publishing at once leave both lines whole; `checkpoints` returns every non-blank line, and `[]` for a missing file
- [x] T005 Add `CHECKPOINT_TAG`, `CHECKPOINT_FIELDS` and `checkpoint_signature(secret, values)` to `lib/reeve/audit/chain/canonical.rb` (signs `made_at` as its stored string, contracts/checkpoint-v1.md)
- [x] T006 Create `lib/reeve/audit/chain/checkpoint.rb`: frozen `Checkpoint` value with `.build(record:, epoch:, keyring:)`, `#to_line`, `.parse(line, position:)`, `#signed_by?(keyring)` → `:valid`/`:altered`/`:key_not_configured`; and `CheckpointResult` (status, reason, checkpoint, published, error) per data-model.md
- [x] T007 [P] Create `lib/reeve/audit/file_anchor.rb`: `FileAnchor.new(path)`, `#publish(line)` with `File::APPEND | File::CREAT`, `flock(LOCK_EX)`, `fsync`; `#checkpoints`. Its comment states that a file on the database host protects nothing (plan Risks)
- [x] T008 Add `ledger_anchor` to `lib/reeve/configuration.rb` (`SETTINGS`, reader, writer using `require_protocol!(:ledger_anchor, anchor, %i[publish checkpoints])`, nil allowed), with cases in `spec/reeve/configuration_spec.rb`
- [x] T009 Failing specs in `spec/reeve/audit/chain/checkpoint_spec.rb` for `Chain.checkpoint!`: names the head and latest epoch after writes and after a rotation; refused `:no_key` and `:no_chain` (head 0) publishing nothing; published to a configured anchor; an anchor that raises gives `published: false` and the error, with the checkpoint still returned; a write racing a checkpoint never yields a head/epoch pair that did not exist together (FR-005); a write is not blocked while a slow anchor's `publish` runs, and no write path ever calls the anchor (FR-009)
- [x] T010 Implement `Chain.checkpoint!(entry_class:, anchor:)` in `lib/reeve/audit/chain.rb`: transaction on the ledger connection, `Head#lock!`, reads through `Head.current` (latest epoch via a new `Epochs#latest`, in `lib/reeve/audit/chain/epochs.rb`), commit, then publish outside the lock (plan "Making a checkpoint")
- [x] T011 Failing specs in `spec/reeve/tasks_spec.rb` for `Tasks.checkpoint_ledger`: each output line in contracts/anchoring.md "checkpoint_ledger output", exit 0 / 1 as stated, the line printed even when the anchor failed, no key value in the output
- [x] T012 Implement `Tasks.checkpoint_ledger(env:, out:)` and the `reeve:checkpoint_ledger` rake definition in `lib/reeve/tasks.rb`
- [x] T013 Add verification plumbing with no new checks: `Chain.verify(checkpoints: nil, from: nil)` resolves nil to the configured anchor's lines and parses all of them first (`CheckpointError` on any bad line) in `lib/reeve/audit/chain.rb` and `lib/reeve/audit/chain/verifier.rb`; `Verification` gains `checkpoints`, `anchored_at`, `beyond_anchor`, `walked_from` and the three break kinds in `KINDS`, and `Break` gains `checkpoint`, in `lib/reeve/audit/chain/verification.rb`. Existing specs stay green

**Checkpoint**: `bin/rails reeve:checkpoint_ledger` publishes a valid line; verification accepts checkpoints and ignores them.

---

## Phase 3: User Story 1 - A truncated tail is caught by a checkpoint (P1) 🎯 MVP

**Goal**: removing entries the checkpoint saw, with the head rewound, is BROKEN.
**Independent test**: checkpoint at 500 of 800, `Ledger.truncate_tail!(after: 400)`: INTACT without the checkpoint, BROKEN with it.

- [x] T014 [P] [US1] Failing specs in `spec/reeve/audit/chain/anchoring_spec.rb`: US1 scenarios 1–4 (not reached at 500; INTACT anchored at 500 after truncating to exactly 500; digest mismatch plus `checkpoint_mismatch` when entry 500 is edited; of checkpoints at 500 and 900 with the ledger cut to 700, only 900 is not reached), each beside its no-checkpoint twin; truncation then regrowth past the checkpoint is `checkpoint_mismatch`; two checkpoints at one sequence with different digests flag the wrong one only (spec amendment 2)
- [x] T015 [US1] Create `lib/reeve/audit/chain/checkpoint_check.rb`: per checkpoint, signature (via `Checkpoint#signed_by?`), then the entry at its sequence looked up 1,000 sequences per query (`where(chain_sequence: [...]).pluck(:chain_sequence, :chain_digest)`, FR-016), reporting `checkpoint_altered`, `checkpoint_not_reached` (beyond the head read after the walk, or no entry) and `checkpoint_mismatch`; returns results and `anchored_at`
- [x] T016 [US1] Call `CheckpointCheck` from `Verifier#verify_chain` after the walk in `lib/reeve/audit/chain/verifier.rb`; set `anchored_at` and `beyond_anchor` on the result; checkpoint breaks make the status BROKEN through `Verification.status_for`

**Checkpoint**: US1 passes on all three engines; the old limit is pinned beside it.

---

## Phase 4: User Story 2 - A deleted ledger is reported as tampering (P1)

**Goal**: an emptied or replaced ledger is BROKEN when a checkpoint names the old chain.
**Independent test**: checkpoint, `Ledger.empty!`: NO CHAIN without it, BROKEN with it; then write a new chain: BROKEN, genesis differs.

- [x] T017 [P] [US2] Failing specs in `spec/reeve/audit/chain/anchoring_spec.rb`: US2 scenarios 1–3; the chain record deleted while entries remain is BROKEN with both `chain_record_missing` and the checkpoint breaks; the task exits 1 for an emptied ledger with a checkpoint and 2 without (`spec/reeve/tasks_spec.rb`)
- [x] T018 [US2] In `lib/reeve/audit/chain/verifier.rb`, before returning `unwalked(:no_chain)`: with checkpoints, return BROKEN with one `checkpoint_not_reached` per checkpoint ("the ledger has no chain") (FR-013)
- [x] T019 [US2] In `lib/reeve/audit/chain/checkpoint_check.rb`, compare the checkpoint's genesis digest and pre-chain counts with the chain record; a difference is `checkpoint_mismatch` ("names another chain")

**Checkpoint**: US1 and US2 pass together.

---

## Phase 5: User Story 3 - Epoch records are pinned by a checkpoint (P1)

**Goal**: an epoch record the checkpoint saw cannot be deleted or edited silently, including a fresh one no entry names.
**Independent test**: rotate, checkpoint, `Ledger.delete_epoch!(2)`: INTACT without the checkpoint, BROKEN with it.

- [x] T020 [P] [US3] Failing specs in `spec/reeve/audit/chain/anchoring_spec.rb`: US3 scenarios 1–2; a checkpoint made before any epoch existed (`epoch` null) stays `checked` after later epochs open; stragglers at the head do not affect it
- [x] T021 [P] [US3] Failing specs in `spec/reeve/tasks_spec.rb`: `rotate_ledger_key` with an anchor configured prints ROTATED then MADE and publishes; CURRENT and REFUSED make no checkpoint; an anchor failure exits 1 and the epoch stays opened (FR-008)
- [x] T022 [US3] In `lib/reeve/audit/chain/checkpoint_check.rb`, check the epoch the checkpoint names against the records `EpochRules` already loaded (no query): absent or another digest is `checkpoint_mismatch`
- [x] T023 [US3] In `lib/reeve/tasks.rb`, after a ROTATED rotation with `ledger_anchor` set, call `Chain.checkpoint!` and print its line; exit 1 on an anchor failure without undoing the rotation

**Checkpoint**: specs/003 "Not detected" item 6 is closed when a checkpoint follows the rotation.

---

## Phase 6: User Story 4 - The report says what was anchored (P2)

**Goal**: every summary line after a walk states the anchoring; a host can assert anchoring in CI.
**Independent test**: one intact ledger verified with no checkpoint, a stale one and a current one; read the first lines.

- [x] T024 [P] [US4] Failing specs in `spec/reeve/audit/chain/verification_output_spec.rb`: every summary line that follows a walk carries the anchoring clause in contracts/anchoring.md, in every state the file already builds plus the new ones (SC-003); checkpoint breaks listed as `checkpoint #N`; a checkpoint signed by a missing key gives UNVERIFIABLE naming its fingerprint and not counted as an entry; JSON gains `checkpoints`, `anchored_at`, `beyond_anchor`, `walked_from`, `breaks[].checkpoint`, with every existing key unchanged
- [x] T025 [US4] Report a checkpoint key not in the keyring as `unknown_key` (sequence nil, `checkpoint:` set) in `lib/reeve/audit/chain/checkpoint_check.rb`, and keep it out of the entry count in `Report#unverifiable` in `lib/reeve/audit/chain/report.rb`
- [x] T026 [US4] Add the anchoring clause to the INTACT, BROKEN and UNVERIFIABLE summaries and the `checkpoint #N` label in `lib/reeve/audit/chain/report.rb`; add the JSON keys in `lib/reeve/audit/chain/verification.rb`
- [x] T027 [P] [US4] Failing specs in `spec/reeve/tasks_spec.rb`: `verify_ledger` reads the anchor by default, `CHECKPOINTS=path` overrides it, `CHECKPOINTS=` turns anchoring off, a malformed line exits 2 naming its position
- [x] T028 [US4] Implement `CHECKPOINTS=` in `Tasks.verify_ledger` and map `CheckpointError` to exit 2 in `lib/reeve/tasks.rb`
- [x] T029 [P] [US4] Failing specs in `spec/reeve/testing/checks_spec.rb`: `LedgerChain.new(anchored: true)` passes with a working anchor; fails naming `config.ledger_anchor` with none, and when the published checkpoint does not come back; ignores checkpoints the anchor held before the run; `anchored: false` never calls the anchor (research R8)
- [x] T030 [US4] Implement `anchored:` in `lib/reeve/testing/checks/ledger_chain.rb`, verifying with the checkpoint it made only; route the checkpoint through the testing ledger adapter in `lib/reeve/testing/ledger.rb` if `verify_chain` needs the argument

**Checkpoint**: no output line says "intact" without its anchoring; host suites can assert an anchor works.

---

## Phase 7: User Story 5 - Verification from a checkpoint (P3)

**Goal**: verify only what was written after a checkpoint, the checkpoint itself checked first.
**Independent test**: 10,000 entries, checkpoint at 9,000, `FROM=latest`: covers 9,001–10,000 and says 9,000 were not walked.

- [x] T031 [P] [US5] Failing specs in `spec/reeve/audit/chain/anchoring_spec.rb`: US5 scenarios 1–3; a starting checkpoint that does not verify stops the run before the walk and says why; a checkpoint at the head walks nothing and is INTACT; `FROM=latest` in `spec/reeve/tasks_spec.rb`, and `FROM` with any other value is an `ArgumentError`
- [x] T032 [US5] Add `start:` (sequence, digest) to `lib/reeve/audit/chain/walk.rb`: batch scope from `chain_sequence > start`, `@expected`, `last_sequence` and `last_digest` begin at the checkpoint
- [x] T033 [US5] Handle `from:` in `lib/reeve/audit/chain/verifier.rb`: pick the highest checkpoint for `:latest`, check it first with `CheckpointCheck`, then walk from it; set `covered` and `walked_from`; add the "verified from checkpoint … not walked by this run" wording in `lib/reeve/audit/chain/report.rb`; `FROM=latest` in `lib/reeve/tasks.rb`

**Checkpoint**: a checkpoint is shown to be enough to verify from, which retention will rely on.

---

## Phase 8: Polish & cross-cutting

- [x] T034 [P] MySQL locking-read spec for `Chain.checkpoint!` next to `spec/reeve/audit/chain/mysql_snapshot_spec.rb`: with locking reads disabled the checkpoint can name a stale head; with them, never
- [x] T035 [P] Add a commented `config.ledger_anchor` line to `lib/generators/reeve/install/templates/initializer.rb.tt`, with the install generator spec updated in `spec/reeve/generators/`
- [x] T036 [P] README tamper-evidence section: anchoring per quickstart.md, one anchor per environment, the store requirement, the window, restore and reset behavior (FR-018); keep `spec/readme_spec.rb` green
- [x] T037 [P] CHANGELOG "Unreleased": new task and setting, the summary-line change for every host, the guarantees and limits in plain words (FR-019)
- [x] T038 Benchmark in `spec/reeve/audit/chain/benchmark_spec.rb`: time `Chain.checkpoint!` in the `:benchmark_large` example at 1,000,000 entries (SC-004, under 1 s); rerun the write benchmark against 0.7.0; record both next to SC-004 in `specs/004-ledger-anchoring/spec.md`
- [x] T039 Full suite on SQLite and PostgreSQL (`bundle exec rspec`, `DB=postgresql DB_HOST=/tmp bundle exec rspec`), `bundle exec rubocop`; MySQL through CI (SC-006)
- [x] T040 Cold read of the README and CHANGELOG sections: schedule checkpoints and verify with them from those alone (SC-005)

---

## Dependencies & execution order

- **Setup (T001–T002)** → **Foundational (T003–T013)** → stories.
- **US1 (T014–T016)** creates `CheckpointCheck`; **US2, US3, US4 and US5** extend it, so they follow US1. Among themselves they touch shared files (`checkpoint_check.rb`, `verifier.rb`, `tasks.rb`), so run them in order: US2 → US3 → US4 → US5.
- **US5** needs US4's report fields (`walked_from`).
- **Polish** after the stories it documents; T034 can run any time after T010.

Within a story: the failing spec first, then the implementation, then the story's checkpoint run on SQLite and PostgreSQL.

## Parallel opportunities

- Phase 1: T001 and T002.
- Phase 2: T003, T004 and T007 together (different files); T005 → T006 → T009/T010 in order; T008 alongside any of them.
- Inside a story, the `[P]` spec tasks can be written together (for example T020 and T021, or T024, T027 and T029), but the implementations share files and run one at a time.
- Phase 8: T034–T037 together.

## Implementation strategy

- **MVP**: Phases 1–3. Truncation with a rewound head is detected, the specs/002 item 2 gap. Shippable on its own, though without the anchoring clause (US4) the report does not yet say a run was unanchored, so do not release before US4.
- **Release scope**: US1–US4 are the minimum for a release (the guarantees section and SC-003 depend on US4). US5 can follow in a minor release if it slips.
- One builder at a time: the stories share files, so they are sequential, not parallel.
