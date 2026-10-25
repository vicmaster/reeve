# Tasks: Ledger Retention

**Input**: spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md in
`specs/005-ledger-retention/`

Test-first per the constitution (III): each implementation task follows the spec that fails
without it. Every tamper case sits beside its legitimate twin (SC-002), and every refusal asserts
the ledger is byte-identical afterwards (SC-003). On PostgreSQL and MySQL the purge specs run
over a real retention role holding exactly the grants in data-model.md, so the grants are tested
too. `[P]`: different files, no dependency on an unfinished task. `[US#]`: spec.md user story.

## Phase 1: Setup

- [x] T001 Add the `reeve_audit_retentions` table (data-model.md, unique `purge`) and the
  retention-role grants comment to `lib/generators/reeve/install/templates/create_audit_entries.rb.tt`;
  add `retentions` to `Ledger::CHAIN_TABLES` in `spec/reeve/audit/support/ledger.rb`
- [x] T002 [P] Add a spec helper `Ledger.retention_connection` in `spec/reeve/audit/support/ledger.rb`:
  an abstract `ActiveRecord::Base` subclass connected to the spec database; on PostgreSQL and
  MySQL it first creates a `reeve_retention` role (`CREATE ROLE`/`CREATE USER`, idempotent) with
  only the data-model.md retention grants and connects as it; on SQLite it reuses the file
- [x] T003 [P] Failing specs in `spec/reeve/generators/upgrade_generator_spec.rb` and
  `spec/reeve/generators/install_generator_spec.rb`: the upgrade adds a retention step that only
  creates the table, is idempotent, converges with a fresh install, and leaves the contract at 4;
  then add the step and its template `add_ledger_retention_to_reeve_audit_entries.rb.tt` to
  `lib/generators/reeve/upgrade/upgrade_generator.rb` and `lib/generators/reeve/upgrade/templates/`

---

## Phase 2: Foundational (blocks every story)

**Purpose**: retention records exist, are signed, can be read and checked; the retention
connection is validated. No purge yet.

- [x] T004 [P] Failing specs in `spec/reeve/configuration_spec.rb`: `ledger_retention_connection`
  defaults to nil, accepts a class responding to `connection_pool` and `connection_db_config`,
  names the missing method otherwise; then add the setting to `lib/reeve/configuration.rb`
- [x] T005 [P] Create `lib/reeve/audit/retention_record.rb`: read-only model on
  `reeve_audit_retentions` (refuses update and destroy, as `ChainEpoch` does); include it in
  `ChainRecord.require_same_database!` in `lib/reeve/audit/chain_record.rb`
- [x] T006 Failing specs in `spec/reeve/audit/chain/retention_spec.rb` for the record's digest:
  recomputed by hand from data-model.md's canonical form; record 0 links to the genesis digest,
  record n to record n−1's digest; a changed field, a deleted record, or a renumbered one fails;
  then add `RETENTION_TAG`, `RETENTION_FIELDS` and `retention_digest` to
  `lib/reeve/audit/chain/canonical.rb`
- [x] T007 Create `lib/reeve/audit/chain/retention/records.rb` (`Retention::Records.read`: one
  query, none when the table is absent; `#latest_valid`) and `lib/reeve/audit/chain/retention/check.rb`
  (`RetentionCheck`: signature under a held key else `unknown_key`, chain links, boundaries
  increasing, `retention_altered` breaks, per-record status), with specs in
  `spec/reeve/audit/chain/retention_spec.rb`
- [x] T008 Create `lib/reeve/audit/chain/retention/connection.rb` (`Retention::Connection.check!`:
  same database and host as the ledger; refuses the application's own username on PostgreSQL
  and MySQL; a warning on SQLite) with specs in `spec/reeve/audit/chain/retention_spec.rb`
- [x] T009 Add `retention_altered` to `KINDS`, `retention` and `awaiting_purge` to
  `Verification` (with JSON keys) in `lib/reeve/audit/chain/verification.rb`, and the checkpoint
  status `purged` to `lib/reeve/audit/chain/checkpoint_check.rb`; existing specs stay green

**Checkpoint**: a retention record can be written by hand in a spec and verified; nothing purges yet.

---

## Phase 3: User Story 1 - Purge a year-old range, and the ledger still verifies (P1) 🎯 MVP

**Goal**: the task purges a prefix ending at a checkpoint, and verification is INTACT afterwards,
naming the purged range.
**Independent test**: 10,000 entries, checkpoints every 1,000, purge through 6,000: INTACT over
6,001 onward, 1–6,000 purged; a second purge through 9,000 also INTACT, both records listed.

- [x] T010 [P] [US1] Failing specs in `spec/reeve/audit/chain/purge_spec.rb`: US1 scenarios 1–5;
  pre-chain rows go with the first purge and the summary says so; unchained contract-3 rows stay;
  a purge across rotations and with stragglers; checkpoints below the boundary report `purged`,
  the one at it `checked`; `OLDER_THAN=` picks the right checkpoint by its entry's time
- [x] T011 [P] [US1] Failing specs in `spec/reeve/audit/chain/purge_spec.rb` for interruption:
  a purge stopped after the record and some deletes reports the rest as `awaiting_purge` (INTACT,
  not BROKEN); rerun with the same boundary finishes and says "resumed"; a restore that puts purged
  rows back reads the same way
- [x] T012 [US1] Create `lib/reeve/audit/chain/retention/purge.rb` (`Retention::Purge`, `PurgeResult`):
  plan steps 2–7 (boundary, verify, dry run, archive hook, record, batched delete over the
  retention connection), resume when the latest record already names the boundary; add
  `Chain.purge!` to `lib/reeve/audit/chain.rb`
- [x] T013 [US1] Verification of a purged ledger: read records in `lib/reeve/audit/chain/verifier.rb`,
  start the walk at the latest valid boundary through `lib/reeve/audit/chain/anchoring.rb`
  (`start`/`link` take the boundary unless `from:` is higher), count `awaiting_purge`, and in
  `lib/reeve/audit/chain/checkpoint_check.rb` report checkpoints below the boundary as `purged` and
  check the one at it against the record's digest
- [x] T014 [US1] Purge clause and awaiting-purge clause on every walked summary line, and the
  pre-chain "purged" note, in `lib/reeve/audit/chain/report.rb`, with exact-line specs in
  `spec/reeve/audit/chain/verification_output_spec.rb` (SC rule: no "intact" without the purged
  range beside the coverage)
- [x] T015 [US1] `Tasks.purge_ledger` and the `reeve:purge_ledger` rake definition in
  `lib/reeve/tasks.rb`: env parsing per contracts/retention.md, each output line, exit codes;
  specs in `spec/reeve/tasks_spec.rb`; railtie spec in `spec/reeve/railtie_spec.rb` lists the task

**Checkpoint**: a legitimate purge, and two, and an interrupted one, all verify INTACT on all
three engines.

---

## Phase 4: User Story 3 - The task refuses what it cannot prove (P1)

**Goal**: every condition the purge cannot back is refused before anything changes.
**Independent test**: one refusal per condition; each exit 1 and a byte-identical ledger
(rows, chain record, epochs, retentions, compared before and after).

- [x] T016 [P] [US3] Failing specs in `spec/reeve/audit/chain/purge_spec.rb`: refusals for no key,
  no anchor, no retention connection, a connection to another database, the application's own
  role (PostgreSQL/MySQL), `THROUGH` at no checkpoint (naming the nearest below and above), a
  ledger that does not verify INTACT (its summary line in the output), a boundary checkpoint that
  does not check, a range signed by a key not configured, neither `ARCHIVE` nor `NO_ARCHIVE=1`,
  an archive path that exists or cannot be written, both or neither of `THROUGH`/`OLDER_THAN`,
  a second purge racing the first; each asserting the ledger byte-identical
- [x] T017 [US3] Implement the refusals (plan step 1 and the checks inside steps 2–3) in
  `lib/reeve/audit/chain/retention/purge.rb`, each with its sentence from contracts/retention.md

**Checkpoint**: SC-003 holds for every refusal.

---

## Phase 5: User Story 2 - Tampering cannot pass as a purge (P1)

**Goal**: any removal a retention record does not cover, and any edit to a record, is BROKEN.
**Independent test**: each US2 case by raw SQL is BROKEN, beside the same removal through the
task, which is INTACT.

- [x] T018 [P] [US2] Failing specs in `spec/reeve/audit/chain/purge_spec.rb`: US2 scenarios 1–5,
  each with its legitimate twin; also a retention record inserted by hand (forged, no key) and a
  record signed by a key the verifier lacks (UNVERIFIABLE, never INTACT)
- [x] T019 [US2] In `lib/reeve/audit/chain/verifier.rb` and `lib/reeve/audit/chain/retention/check.rb`:
  when a record fails, walk from the last record that verified, so the gap it leaves is reported
  as `missing`; a record with an unknown key still sets the boundary, and the run is UNVERIFIABLE
- [x] T020 [US2] Make `Retention::Purge` refuse a ledger whose verification is not INTACT before
  anything else (spec amendment 1), with the spec for a digest mismatch inside the range in
  `spec/reeve/audit/chain/purge_spec.rb` (US2 scenario 5)

**Checkpoint**: SC-002 holds on all three engines.

---

## Phase 6: User Story 4 - An archive verifies on its own (P2)

**Goal**: the archive of a purge verifies without the database, from its start link to the
boundary checkpoint.
**Independent test**: purge with an archive; verify it alone: INTACT; edit, drop or reorder a
line: BROKEN at it.

- [x] T021 [P] [US4] Failing specs in `spec/reeve/audit/chain/archive_spec.rb`: the file matches
  contracts/archive-v1.md (header, sorted keys, times, pre-chain rows first); its SHA-256 is the
  record's; it is written to `path.tmp` and renamed, and nothing is deleted if writing fails;
  verified alone it is INTACT for purge 0 and for a later purge; an edited, removed or reordered
  line is BROKEN; a header naming an unknown format is refused; awkward values (the roundtrip
  spec's set) verify on every engine
- [x] T022 [US4] Create `lib/reeve/audit/chain/retention/archive.rb` (`Archive.write`, `Archive.verify`)
  and wire it into `Retention::Purge` step 5; add `Chain.verify_archive` to `lib/reeve/audit/chain.rb`
- [x] T023 [US4] `Tasks.verify_archive` and the `reeve:verify_archive` rake definition in
  `lib/reeve/tasks.rb`, specs in `spec/reeve/tasks_spec.rb`

**Checkpoint**: archived ranges stay verifiable as evidence.

---

## Phase 7: Polish & cross-cutting

- [x] T024 [P] `LedgerChain` on a purged ledger: passes and its message names the purged range
  (`spec/reeve/testing/checks_spec.rb`); no change expected in `lib/reeve/testing/checks/ledger_chain.rb`
- [x] T025 [P] README tamper-evidence section: retention procedure per quickstart.md, the role and
  grants, the archive, the guarantees and limits; keep `spec/readme_spec.rb` green (FR-014)
- [x] T026 [P] CHANGELOG "Unreleased": the purge, the archive, the new table and setting, the
  constitution amendment, the summary-line change, the limits in plain words (FR-014)
- [x] T027 Benchmark in `spec/reeve/audit/chain/benchmark_spec.rb` (`:benchmark_large`): purge
  1,000,000 entries; record the time, that no write waited behind it (a writer thread's longest
  wait), and that verification afterwards walks only the remainder; record next to SC-004 in
  `specs/005-ledger-retention/spec.md`
- [x] T028 Full suite on SQLite and PostgreSQL (`bundle exec rspec`, `DB=postgresql DB_HOST=/tmp
  bundle exec rspec`), `bundle exec rubocop`; MySQL through CI (SC-006)
- [x] T029 Cold read of the README and CHANGELOG sections: configure, dry-run, run and verify a
  purge from those alone (SC-005); fold the findings back into the docs

---

## Dependencies & execution order

- **Setup (T001–T003)** → **Foundational (T004–T009)** → stories.
- **US1 (T010–T015)** builds the purge and the verification of a purged ledger; **US3** and
  **US2** add to the same `purge.rb` and `verifier.rb`, so they follow it, in that order (refusals
  before the tamper cases, so no tamper spec runs a purge that should have been refused).
- **US4** needs the purge's archive hook (T012) and can follow US1 directly, but shares
  `purge.rb`; run it after US2.
- **Polish** after the stories it documents; T027 needs US1 and US4.

Within a story: the failing spec first, then the implementation, then the story's checkpoint on
SQLite and PostgreSQL.

## Parallel opportunities

- Phase 1: T002 and T003 alongside T001's template change once the table shape is fixed.
- Phase 2: T004 and T005 together; T006 → T007; T008 alongside T006.
- Spec-writing tasks marked `[P]` inside a story can be written together (T010 and T011); the
  implementations share files and run one at a time.
- Phase 7: T024, T025 and T026 together.

## Implementation strategy

- **No MVP release before US3 and US2.** US1 alone would delete data without every refusal and
  without the tamper cases pinned; it is a build milestone, never a shippable state.
- **Release scope**: US1–US3 (all P1). US4 is P2, but an archive written without a verifier is
  evidence nobody can check, so ship it with them unless it slips badly; if it does, release with
  `NO_ARCHIVE=1` required and archives disabled, never with unverifiable archives.
- One builder at a time: the stories share files.
