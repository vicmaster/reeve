# Tasks: Tamper-Evident Audit Ledger

**Input**: Design documents from `/specs/002-tamper-evident-ledger/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: REQUIRED. Constitution Principle III makes this repo test-first. Each spec task
precedes the implementation it pins, and must be seen failing first. Each tamper spec is
also verified red by disabling the check it covers (the 0.1.0 lesson: three regression
specs were vacuous until checked that way).

**Databases**: unless a task says otherwise, every spec under `spec/reeve/audit/` runs on
SQLite locally and on PostgreSQL and MySQL in CI (`DB=` harness,
`spec/support/optional/database.rb`). Run a server engine locally with
`DB=postgresql bundle install && DB=postgresql bundle exec rspec`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 chaining and detection · US2 honest verification · US3 upgrade path ·
  US4 CI check and rake task

---

## Phase 1: Setup

**Purpose**: Measure before building, so SC-005 is a number rather than a hope.

- [x] T001 Add a `:benchmark` exclusion filter to `spec/spec_helper.rb` so tagged examples
      run only with `--tag benchmark`
- [x] T002 Write `spec/reeve/audit/chain/benchmark_spec.rb` (tagged `:benchmark`): median and
      p95 of 1,000 uncontended `Reeve::Audit::Recorder#record` calls on the current (0.5.0)
      code. Run it on SQLite locally and on PostgreSQL and MySQL. Record the numbers under a
      new "Measured" heading in research.md R3. If 5 ms on top of that baseline is
      unrealistic, revise SC-005 in spec.md now and say why, rather than miss it later.
      DONE on all three engines (research.md R3 "Measured"; MySQL from the CI `database`
      job's benchmark step). SC-005 stands

**Checkpoint**: baseline recorded; SC-005 confirmed or revised.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Keys, the canonical form, and the schema. The canonical form is the
highest-risk piece of the feature (plan.md Risks), so it is proven on all three engines
before anything depends on it.

### Configuration and keys

- [x] T003 [P] Write specs in `spec/reeve/configuration_spec.rb` for `ledger_key` and
      `retired_ledger_keys` per the table in contracts/ledger-chain.md. Cover: nil allowed;
      blank or < 32 bytes raises `ArgumentError` on assignment; a retired key equal to
      `ledger_key` raises; `ledger_key_id` is 16 hex characters and stable; `to_h`,
      `inspect` and error messages never contain a secret
- [x] T004 Implement the two settings, their validation and `ledger_key_id` in
      `lib/reeve/configuration.rb`. Add both to `SETTINGS`. Make `to_h` and `inspect`
      show fingerprints, never secrets
- [x] T005 [P] Add `Reeve::LedgerKeyError < Reeve::Error` to `lib/reeve/errors.rb`, with a
      message naming `config.ledger_key` and the generated initializer line. Spec it in
      `spec/reeve/errors_spec.rb`
- [x] T006 [P] Write `spec/reeve/audit/chain/keyring_spec.rb`: the fingerprint is the first 16
      hex characters of `HMAC-SHA256(key, "reeve-ledger-key-id")`; `#signing` returns the
      current key and id; `#for(id)` finds current or retired keys and returns nil for an
      unknown id; `inspect` contains no secret
- [x] T007 Implement `lib/reeve/audit/chain/keyring.rb` (research R7)

### Canonical form (research R2)

- [x] T008 [P] Write `spec/reeve/audit/chain/normalizer_spec.rb`. Symbol keys become strings;
      a `Time` inside arguments renders as ActiveSupport's JSON renders it; `NaN` and
      `Infinity` become nil; `occurred_at` is floored, never rounded, to the column's
      effective precision as read from the schema (6 by default, 0 for a MySQL `datetime`
      with no precision); the precision lookup happens once per entry class
- [x] T009 Implement `lib/reeve/audit/chain/normalizer.rb`
- [x] T010 [P] Write `spec/reeve/audit/chain/canonical_spec.rb`. Cover: object keys sorted at
      every depth; `1.0e+20`, `100000000000000000000` and `1e20` canonicalize alike; `"1"`
      and `1` do not; nil is distinct from `{}` and `[]`; times become UTC integer
      microseconds regardless of `default_timezone`; the domain tags are
      `reeve-ledger-entry-v1` and `reeve-ledger-genesis-v1`; the entry field list exactly
      equals the order in data-model.md. Add a drift test: every `reeve_audit_entries`
      column except `id` and `chain_digest` appears in the written-out field list, so a
      future column cannot be silently left out of the digest
- [x] T011 Implement `lib/reeve/audit/chain/canonical.rb`: the canonical serializer, the
      entry digest and the genesis digest (research R1, data-model "Canonical entry")

### Schema

- [x] T012 Update `lib/generators/reeve/install/templates/create_audit_entries.rb.tt` to
      contract 3. Add `chain_sequence` (bigint), `chain_key_id` (string, limit 16) and
      `chain_digest` (string, limit 64), all nullable, with a unique index on
      `chain_sequence`. Create `reeve_audit_chains` per data-model.md, with a unique index
      on `name`. Replace the header comment's "no cryptographic chaining" paragraph and add
      the grants per contracts/audit-entry-v3.md. **Keep the template free of ERB**:
      `spec/reeve/audit/support/ledger.rb` evaluates it directly
- [x] T013 Update `spec/reeve/audit/migration_spec.rb` for the new columns, both unique
      indexes and the new table, on all three engines. Confirm that NULL `chain_sequence`
      values do not collide under the unique index
- [x] T014 [P] Write `spec/reeve/audit/chain_record_spec.rb`, then implement
      `lib/reeve/audit/chain_record.rb`: genesis columns `attr_readonly`, `destroy`
      aborts, no public method that advances the head
- [x] T015 Write `spec/reeve/audit/chain/roundtrip_spec.rb`. Insert the awkward-value corpus
      (research R2 "Test strategy") through the normalizer into the real table, read every
      row back, and assert the canonical form is byte-identical before and after on each
      engine (SC-002). **Gate: green on the PostgreSQL and MySQL CI jobs before Phase 3
      starts.** Also add the known-limit example: an integer beyond double precision on
      MySQL fails to round-trip, documented in the example's description. DONE, plus a
      `jsonb` copy of the table on PostgreSQL (`t.json` is PostgreSQL's `json`, which keeps
      text as written, so `jsonb` is the case the canonical form exists for). Mutation-checked:
      key sorting and the JSON round trip are caught on jsonb
- [x] T016 Move the contract to 3: `CONTRACT_VERSION` in `lib/reeve/audit.rb`, and
      `EXPECTED_VERSION` and `COLUMNS` in `lib/reeve/testing/checks/contract_version.rb`,
      both by hand as that file requires. Update `spec/reeve/audit/contract_version_spec.rb`
- [x] T017 Give every ledger-writing spec a fixed test key: configure `ledger_key` after each
      `Reeve.reset_configuration!` in `spec/reeve/audit/support/ledger.rb`,
      `spec/reeve/audit/support/envelope.rb` and `spec/reeve/testing/support/fixtures.rb`.
      Without it, the existing 577 examples fail closed once chaining lands. Add the same
      derived `ledger_key` line the initializer template carries to the hand-written
      `Reeve.configure` block in `spec/dummy/quickstart.rb`, which mirrors the template. Confirm
      the full suite is still green on SQLite
- [x] T018 [P] Extend `spec/reeve/generators/install_generator_spec.rb`: the
      initializer contains the derived `ledger_key` line and the commented dedicated-key
      alternative, and no key value
- [x] T019 Add the `ledger_key` line, the dedicated-key alternative and the rotation
      warning to `lib/generators/reeve/install/templates/initializer.rb.tt`. It lands here,
      not in US3, because US1 makes every write need a key: from the first chained write
      onward, the quickstart and every checkpoint stay green only if the template already
      carries the line

**Checkpoint**: keys, canonical form and contract-3 schema are in place and proven on three
engines. Nothing chains yet.

---

## Phase 3: User Story 1 — New entries are chained, and tampering is detected (P1) 🎯

**Goal**: Every entry reeve writes is linked to its predecessor. Verification finds every
edit, deletion and reorder of a chained entry.

**Independent Test**: write chained entries through a guarded tool; verify (intact). Then,
with raw SQL, edit one, delete another and swap two sequence numbers; verify and confirm
every break is reported with its sequence and kind.

### Tests first

- [x] T020 [P] [US1] Write `spec/reeve/audit/chain/append_spec.rb`. Cover:
      - sequences run 1..n with no gaps;
      - each row carries the signing key id and a digest that links to its predecessor;
      - the first append creates the chain record (genesis, `pre_chain_count`) atomically;
      - a replayed `invocation_id` returns the existing entry and leaves the head unmoved;
      - a host-transaction rollback rolls back the row and the head together, so the next
        write reuses that sequence;
      - two connections racing to create the chain yield exactly one chain record and
        sequences 1 and 2 (PostgreSQL and MySQL);
      - a missing key raises `LedgerKeyError`;
      - the genesis records `pre_chain_count` and `pre_chain_unchained_count`;
      - a host-supplied recorder that builds its own row and calls `Chain#append!` produces
        rows that verify intact (FR-007)
- [x] T021 [P] [US1] Write `spec/reeve/audit/chain/verifier_spec.rb` (walk only): intact over
      1..n; keyset pagination in batches of 1,000 (assert the batch size, not wall time);
      stops at the head read at start, even while another connection keeps appending; rows
      committed during the walk (between the two head reads) are not reported; a chained row
      above the head re-read at the end is reported as `beyond_head`; opens no long
      transaction
- [x] T022 [P] [US1] Write `spec/reeve/audit/chain/concurrency_spec.rb`. On PostgreSQL and
      MySQL, 8 threads × 1,000 invocations through `Recorder`, then 8 × 1,000 through
      `IsolatedRecorder`, each give sequences 1–8,000 with no gaps, no duplicates, no
      deadlock, and verify intact (SC-003). SQLite runs a reduced 4 × 100 through
      `Recorder`
- [x] T023 [P] [US1] Write `spec/reeve/audit/chain/tamper_spec.rb` for the spec's "Detected"
      list, each case through raw SQL that bypasses the model:
      - an edited value → `digest_mismatch` at that sequence;
      - a deleted middle row → `missing` plus `digest_mismatch` on the next row;
      - two swapped sequence numbers → a break at each;
      - a forged insert → `digest_mismatch`;
      - newest rows deleted with the head untouched → `head_mismatch`;
      - the chain record deleted → `chain_record_missing`;
      - a row forged one past the head → `beyond_head`, and the next legitimate write fails
        on the unique sequence with `AuditWriteError` (loud in both places, as the spec's edge
        case says);
      - three independent breaks → all three reported, with complete totals.

      Verify each example red by disabling the corresponding check in the verifier
- [x] T024 [P] [US1] Write `spec/reeve/audit/chain/restore_spec.rb`: dump the ledger and
      chain tables with the engine's own tool (`sqlite3 .dump`, `pg_dump`, `mysqldump`),
      restore into a fresh database with the primary keys renumbered, and verify intact
      (SC-002). In CI, run the server's own client through the service container (`docker
      exec`) so the dump tool's version matches the server's. Where the tool is absent locally,
      the example is pending with that reason, never passed. Also update `.github/workflows/ci.yml`
      if the job needs it

### Implementation

- [x] T025 [US1] Implement `lib/reeve/audit/chain.rb` `Chain#append!(row)` per research R3:
      update first, then read, compute the digest, insert, advance the head digest, all in
      one savepoint on `entry_class.connection`. On 0 rows updated, create the chain record
      with its genesis (both pre-chain counts), retrying the update once if the unique `name`
      index loses the race. Require the new `chain/*` files and `chain_record.rb` from
      `lib/reeve/audit.rb`
- [x] T026 [US1] Route `lib/reeve/audit/recorder.rb` through the normalizer and
      `Chain#append!`, keeping the replay semantics. Extend the enclosing-transaction
      warning: under a host transaction the chain lock is held until that transaction
      commits, and `IsolatedRecorder` is the answer. Extend
      `spec/reeve/audit/recorder_spec.rb`
- [x] T027 [P] [US1] Prove in `spec/reeve/audit/isolated_recorder_spec.rb` that chained writes
      run on the isolated connection and survive a host rollback (PostgreSQL and MySQL).
      Update the class comment in `lib/reeve/audit/isolated_recorder.rb`: the chain lock is
      held for one insert
- [x] T028 [US1] Implement `lib/reeve/audit/chain/verifier.rb` (research R6) and the result
      structure in `lib/reeve/audit/chain/verification.rb` (`status`, `covered`, `totals`,
      `breaks`, `head_at_start`, `head_at_end`, `Break`), including the second head read and
      the `beyond_head` scan. Expose `Reeve::Audit::Chain.verify(keys: nil)`
- [x] T029 [US1] Run T020–T024 green on all three engines; make the T002 benchmark cover the
      chained write too

**Checkpoint**: US1 complete. Chained writes and detection work, but the statuses are not
yet trustworthy for partial ledgers, so US1 must not ship without US2.

---

## Phase 4: User Story 2 — Verification never reports more than it established (P1)

**Goal**: Unchained, partially chained, unverifiable and empty ledgers are each reported for
what they are, and none of them reads as a pass.

**Independent Test**: build each US2 ledger in a test database and assert the status, the
summary line, and that only an intact chain gives a success result.

### Tests first

- [x] T030 [P] [US2] Extend `spec/reeve/audit/chain/verifier_spec.rb` with the status rules in
      data-model.md, in their order of precedence:
      - no key → `:unverifiable` and nothing else claimed;
      - no chain record and no chained rows → `:no_chain`;
      - contract-3 rows with no digest written before the chain started (`:warn`, key
        configured later) → reported as uncovered, not breaks; one written after → an
        `unchained` break identified by `invocation_id` → `:broken`, with the "by clock"
        wording;
      - a row signed by an unknown key → `:unverifiable`, counted separately;
      - a row signed by a retired key verifies;
      - contract-2 rows written after the genesis (rolling deploy) → still `:intact`, with
        the uncovered count now and at genesis both reported.
- [x] T031 [P] [US2] Write `spec/reeve/audit/chain/verification_output_spec.rb`. Every status's
      `to_s` matches the examples in contracts/ledger-chain.md "Output". **SC-006:** over
      every ledger state built in this file, no output line contains "intact" or "pass"
      without the covered range and the uncovered count on the same line. `LIMIT` caps the
      listed breaks but never the totals. `as_json` has every field in data-model.md. No
      output, in any format or state, contains a key secret (FR-008); only fingerprints
- [x] T032 [P] [US2] Extend `spec/reeve/audit/chain/tamper_spec.rb` with the "Not detected"
      list, pinned as undetected and labelled so in each example's description:
      - a key holder re-signs from row k → `:intact`;
      - newest rows deleted and the head rewound → `:intact`;
      - the whole ledger and the chain record deleted → `:no_chain`, never `:intact`;
      - a pre-chain row edited → `:intact`, with the uncovered count.

### Implementation

- [x] T033 [US2] Implement the status rules and the uncovered/unchained counts (two
      `COUNT(*)` queries) in `lib/reeve/audit/chain/verifier.rb`
- [x] T034 [US2] Implement `to_s` (summary line plus capped breaks) and `as_json` in
      `lib/reeve/audit/chain/verification.rb`, wording exactly as in
      contracts/ledger-chain.md

**Checkpoint**: US1 and US2 together are the shippable core (MVP).

---

## Phase 5: User Story 3 — Upgrade an existing ledger without rewriting history (P2)

**Goal**: A 0.5.0 host reaches a verified chain in three steps with no edit to existing rows
(SC-007).

**Independent Test**: start from a contract-2 table with rows; upgrade, migrate, invoke;
the old rows are byte-identical, the chain is intact, and the old rows are reported as
uncovered.

### Tests first

- [x] T035 [P] [US3] Extend `spec/reeve/generators/upgrade_generator_spec.rb`:
      - contract-2 table → emits only the contract-3 migration; running it again → nothing
        to do;
      - contract-1 table → both steps, oldest first;
      - the output prints the `ledger_key` line, the `secret_key_base` rotation warning and
        the large-ledger index note
      PULLED FORWARD into Phase 2: once T012 puts the install template at contract 3,
      the existing convergence spec (fresh install == upgraded table) needs this step
- [x] T036 [P] [US3] Extend `spec/reeve/audit/failure_mode_spec.rb` with the no-key matrix
      from contracts/ledger-chain.md "Writing":
      - `:fail` → `AuditWriteError`, cause `LedgerKeyError`;
      - `:warn` → a contract-3 row with all three chain columns NULL, a warning logged on
        every such write, and no chain lock taken;
      - a table missing the contract-3 columns → `AuditWriteError`, cause
        `ConfigurationError` naming `rails g reeve:upgrade`, never `UnknownAttributeError`
- [x] T037 [P] [US3] Write `spec/reeve/audit/chain/upgrade_spec.rb`, end to end:
      - build a contract-2 table and write 50 rows;
      - run the generated upgrade migration and snapshot the old rows;
      - invoke a guarded tool, then assert: old rows byte-identical, chain record with
        `pre_chain_count = 50`, verification intact with 50 uncovered;
      - write contract-2 rows after the genesis (rolling deploy) and assert verification is
        still intact with both counts shown

### Implementation

- [x] T038 [US3] Add `lib/generators/reeve/upgrade/templates/add_ledger_chain_to_reeve_audit_entries.rb.tt`
      (three nullable columns, the unique index, the chain table, and the grants comment).
      Add the contract-3 entry to `STEPS` in
      `lib/generators/reeve/upgrade/upgrade_generator.rb`; its applied-check must also
      require `reeve_audit_chains`. Extend `pending_message` with the initializer line, the
      rotation warning and the `algorithm: :concurrently` note
      PULLED FORWARD with T035, for the same reason
- [x] T039 [US3] In `lib/reeve/audit/recorder.rb`, implement:
      - the once-per-process column check, raising `ConfigurationError`;
      - the no-key behaviour: under `:fail` raise `LedgerKeyError` (the envelope wraps it);
        under `:warn` write unchained and log

**Checkpoint**: upgrade path proven from contract 1 and contract 2.

---

## Phase 6: User Story 4 — Prove the chain in CI, check it in production (P2)

**Goal**: `LedgerChain` in both compliance suites with no host code, and
`bin/rails reeve:verify_ledger` with distinct exit statuses.

**Independent Test**: compliance run with a key (passes), with nothing chained (skipped,
never passed), with a tampered ledger (fails naming the break); rake task exit statuses
against each US2 ledger.

### Tests first

- [ ] T040 [P] [US4] Extend `spec/reeve/testing/checks_spec.rb` with `LedgerChain`, per the
      table in contracts/ledger-chain.md "Testing kit":
      - intact → passed, stating the range;
      - broken, or any unchained row → failed;
      - unverifiable, or no key configured → failed, naming the missing key;
      - no compliance tools, or no ledger loaded → skipped with the "not verified" message;
      - a break left in the ledger before the check's own entries → failed (it verifies the
        whole visible ledger, not only its own entries).

      Also assert it invokes the first compliance tool once per fixture principal
- [ ] T041 [P] [US4] Extend `spec/reeve/testing/parity_spec.rb`,
      `spec/reeve/testing/rspec_front_end_spec.rb` and
      `spec/reeve/testing/minitest_front_end_spec.rb`: `LedgerChain` reaches the same result
      in both frameworks, and a skip shows as a skip in both
- [ ] T042 [P] [US4] Write `spec/reeve/tasks_spec.rb`: `reeve:verify_ledger` exits 0 when
      intact, 1 when broken, 2 for unverifiable or no chain; `LIMIT=0` prints the summary
      and totals only; `FORMAT=json` emits every break
- [ ] T043 [P] [US4] Extend `spec/load_safety_spec.rb`: `require "reeve"` with no Rails loaded
      neither loads the Railtie nor raises. Confirm `spec/reeve/testing/isolation_spec.rb`
      still loads the kit with no ActiveRecord

### Implementation

- [ ] T044 [US4] Add `#verify_chain` to `lib/reeve/testing/ledger.rb`: lazy, returns nil when
      `reeve/audit` is not loaded, and is the only path from the kit to `Chain.verify`
- [ ] T045 [US4] Implement `lib/reeve/testing/checks/ledger_chain.rb` (research R10). Add it to
      `ALL` and `GLOBAL` in `lib/reeve/testing/checks.rb`
- [ ] T046 [US4] Implement `lib/reeve/railtie.rb` (registers the tasks only) and require it
      from `lib/reeve.rb` only when `Rails::Railtie` is defined
- [ ] T047 [US4] Implement `lib/reeve/tasks.rb`: the `reeve:verify_ledger` task, using the Rake
      DSL in a `.rb` file (research R9)
- [ ] T048 [US4] Extend the `gemspec.files` assertion in
      `spec/reeve/testing/framework_neutrality_spec.rb` to cover `lib/reeve/railtie.rb`,
      `lib/reeve/tasks.rb` and the new upgrade template. Add a `reeve:verify_ledger` run to
      the dummy app in `spec/reeve/quickstart_spec.rb`

**Checkpoint**: all four stories complete.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [ ] T049 [P] Apply contracts/audit-entry-v3.md to
      `specs/001-guardrails-core/contracts/audit-entry.md`. Add the two settings to
      `specs/001-guardrails-core/contracts/configuration.md` and `LedgerChain` to
      `specs/001-guardrails-core/contracts/testing-kit.md`. Add the `ledger_key` step to
      `specs/001-guardrails-core/quickstart.md`, which `spec/dummy/quickstart.rb` claims to
      follow step by step
      PARTLY DONE in Phase 2: the audit-entry.md change landed with T016, because
      `contract_version_spec.rb` ties the constant to the version that document states
- [ ] T050 [P] Rewrite the "What it does not" section of `lib/reeve/audit.rb` per
      audit-entry-v3.md. Then `grep -rn "cryptographic chaining" lib/ specs/ README.md` and
      fix every remaining claim that chaining does not exist
- [ ] T051 [P] Add a README section for the ledger chain. It must give the spec's
      "Detected"/"Not detected" lists, the same in substance; the rake task and exit
      statuses; key rotation and the `secret_key_base` coupling; and the lock-contention
      note with `IsolatedRecorder` as the answer. The contention note must state each
      engine's default wait: PostgreSQL waits indefinitely (`lock_timeout` 0), MySQL 50 s
      (`innodb_lock_wait_timeout`), SQLite ActiveRecord's `timeout` (5 s). State the Rails
      7.0 + SQLite limit (research R3): concurrent guarded calls in one process can fail
      closed after the busy timeout, because sqlite3 1.x waits holding the GVL; Rails 7.1+
      or a server database avoids it. Constitution VI
      requires a runnable example for every new public entry point: `config.ledger_key`,
      `config.retired_ledger_keys`, `Reeve::Audit::Chain.verify`, `Chain#append!` (for
      custom recorders) and `bin/rails reeve:verify_ledger`. Extend the API assertions in
      `spec/readme_spec.rb` to name each, and keep it green
- [ ] T052 [P] Add an Unreleased entry to `CHANGELOG.md`. It must cover:
      - contract 2 → 3 and why it is MAJOR;
      - the three upgrade steps;
      - "Breaking for custom recorders" (`Chain#append!`);
      - the rotation warning;
      - the MySQL large-number limit;
      - the new skip in the compliance suite.

      Name no consumer project
- [ ] T053 Write `specs/002-tamper-evident-ledger/verification.md`, mapping SC-001–SC-007 to
      their specs with a "Known gaps" section, and extend `spec/reeve/verification_spec.rb`
      to check this map as it checks 001's
- [ ] T054 Rerun the T002 benchmark with chaining. Add a `:benchmark` fixture builder to
      `spec/reeve/audit/chain/benchmark_spec.rb` that writes a 100k and a 1M-entry chained
      ledger through `Chain#append!` in batched transactions. Then measure SC-004 (verify
      1M rows; peak memory at 100k vs 1M) and SC-005 on each engine. Record the results in
      verification.md; if a target is missed, say so there and in the spec
- [ ] T055 Run the full suite on SQLite locally and confirm the PostgreSQL, MySQL, Ruby 3.0
      floor and RuboCop jobs pass in CI
- [ ] T056 Run `/code-review` on the branch. Give `canonical.rb`, `chain.rb` and
      `verifier.rb` the scrutiny `scoper.rb` got in 0.1.0. Re-verify red, by reverting the
      behaviour each pins: every tamper example, the sequencing, replay and rollback
      examples in `append_spec.rb`, and the no-key matrix in `failure_mode_spec.rb`
      (FR-023)
- [ ] T057 `gem build reeve.gemspec` and list the packaged files. Confirm `railtie.rb`,
      `tasks.rb`, every `chain/*.rb` file and both migration templates are inside. Do not
      commit the `.gem`

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)** → **Foundational (Phase 2)** → user stories.
- **T015 is a gate**: the round-trip corpus must be green on all three engines before Phase 3.
- **US1 (Phase 3)** depends on Phase 2.
- **US2 (Phase 4)** depends on US1's verifier (T028). US1 must not ship without US2.
- **The initializer line and harness keys (T017, T018, T019) are in Phase 2**, because US1
  makes every write need a key.
- **US3 (Phase 5)** depends on US1 (T025–T026). It is independent of US2 except T037, which
  asserts an uncovered count (T033).
- **US4 (Phase 6)** depends on US2 (status rules). T046–T047 (Railtie, rake task) depend
  only on T028 and T034.
- **Polish (Phase 7)** after the stories it documents; T054 after T028.

### Within each story

Spec tasks first, seen failing. Then implementation. Then the same specs green on all
three engines before the checkpoint commit.

### Parallel opportunities

- Phase 2: T003, T005, T006, T008, T010, T014 and T018 touch different files and can be written
  together; T004, T007, T009 and T011 then follow their own specs.
- US1: T020–T024 are five independent spec files.
- US2: T030–T032 together.
- US3: T035, T036 and T037 together; then T038 and T039.
- US4: T040–T043 together; T046–T047 can proceed alongside T044–T045.
- Polish: T049–T052 together.

## Parallel Example: User Story 1

```text
# Five spec files, written together, all expected red:
T020 spec/reeve/audit/chain/append_spec.rb
T021 spec/reeve/audit/chain/verifier_spec.rb
T022 spec/reeve/audit/chain/concurrency_spec.rb
T023 spec/reeve/audit/chain/tamper_spec.rb
T024 spec/reeve/audit/chain/restore_spec.rb

# Then, in order: T025 chain.rb → T026 recorder.rb → T028 verifier.rb
# T027 (IsolatedRecorder) can run beside T028 once T026 is in.
```

## Implementation Strategy

**MVP = Phases 1–4 (US1 + US2).** Chaining without honest statuses is the failure this
project keeps catching in itself: a guarantee reported that was never established. The two
P1 stories therefore ship as one increment and are never merged apart.

Then US3, because no existing host can adopt the feature without it. Then US4, which is how
a host proves the guarantee in CI and checks it in production. Commit at every checkpoint
and confirm before any push (Constitution, Development Workflow). Version bump and release
are a separate release PR, as for 0.5.0.
