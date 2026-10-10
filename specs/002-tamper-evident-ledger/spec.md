# Feature Specification: Tamper-Evident Audit Ledger

**Feature Branch**: `002-tamper-evident-ledger`
**Created**: 2026-10-07
**Status**: Draft
**Input**: User description: "Tamper-evident audit ledger. Chain every audit ledger row to the one before it with a keyed digest (HMAC), so that editing, reordering, or deleting a row in the middle of the ledger is detectable by a verification pass, even by someone with write access to the ledger table but not to the key. […] Never claim a guarantee that was not established — verification of an unchained or partially chained ledger must say so rather than report a pass."

## Overview

Today the ledger is append-only *at the library level*: reeve exposes no update or delete
API, a persisted entry is read-only, and the generated migration documents the
`INSERT, SELECT` grant that enforces the rest where a database can enforce it. Nothing
detects a change made outside the library. A person with write access to the table — a
DBA, a compromised application credential, a well-meaning data fix — can edit a row,
delete one, or reorder them, and the ledger reads exactly as it did before. The question
the ledger exists to answer ("why did the AI expose that?") is only as trustworthy as the
table nobody watched.

This feature makes such changes **detectable**. Each new entry is linked to the one before
it by a keyed digest computed with a secret the database does not hold. A verification
pass walks the chain and reports every place it no longer holds.

The consumers are **Rails application developers** running reeve; the beneficiaries are the
**security and compliance reviewers** who must be able to say, about a given ledger, which
rows are covered by this guarantee and whether it held.

### What this feature guarantees, and what it does not

This section is normative. Documentation, CHANGELOG and verification output MUST NOT claim
more than it states.

**Detected**, provided the attacker does not hold the key:

- a covered entry whose recorded content was changed;
- a covered entry removed from anywhere *before* the most recent entry;
- covered entries swapped, renumbered, or moved;
- an entry inserted into the chain that reeve did not write, including one numbered past
  the head;
- removal of the most recent entries **when the chain record's head was left alone**;
- removal of the chain record itself while chained entries remain.

**Not detected — stated plainly, not as footnotes:**

1. **Compromise of the key.** Anyone holding the key can recompute the chain from any point
   forward. Tamper-evidence is exactly as strong as the separation between the key and the
   database.
2. **Truncation of the tail by someone who also rewinds the head.** Deleting the most
   recent N entries and setting the head back to the entry before them leaves a chain that
   is internally consistent and verifies. Only an anchor held outside the database (a
   published checkpoint) can catch this; external anchoring is out of scope here and listed
   as future work.
3. **Deletion of the entire ledger, chain record included.** Verification then reports that
   there is no chain — it does not report a pass — but it cannot tell an emptied ledger from
   one that was never chained.
4. **Entries written before the chain began.** Rows written under contract 1 or 2 carry no
   digest and remain exactly as protected as they are today. Verification reports them as
   uncovered; it never folds them into a pass.
5. **Prevention.** This detects tampering after the fact. It does not stop anyone from
   writing to the table; the database grant remains the control for that.

## Clarifications

### Session 2026-10-07

Decisions taken while writing this specification, recorded here so they can be overruled
before planning rather than discovered during it:

- Q: Is chaining opt-in, or required once the ledger is at contract 3? → A: Required. The
  input already treats a missing key as a failure to fail closed on, and an opt-in
  guarantee is one most hosts would never turn on. Upgrading therefore needs a key in every
  environment that runs guarded tools, the test environment included (FR-021). The cost of
  that was later removed by amendment 4 below.
- Q: Key rotation — addressed or deferred? → A: Addressed minimally. Every chained entry
  records *which* key signed it, and verification accepts a set of keys. Adding the key
  identifier later would be another contract bump on an append-only table, so it is cheaper
  now than ever again. Re-signing history under a new key is **not** offered — see FR-016.
- Q: Under `audit_failure_mode = :warn` with no usable key, is an entry written? → A: Yes,
  unchained and identified as such, and verification reports it as a break if it was written
  after the chain started (one written before is counted as uncovered). `:warn` exists
  to keep calls running, not to drop traces; an unchained entry is a trace that says what it
  lacks.
- Q: Does a verified chain that is preceded by pre-chain rows count as a pass? → A: The
  chain's own status and its coverage are reported separately (FR-012). A chain with no
  breaks is reported as intact *for the range it covers*, and the uncovered rows are always
  counted beside it, in the same line, never only in detail output.

### Amended during planning (2026-10-07)

Four changes made by `/speckit.plan`. The first three are there because the original
wording would have forced a design that reports more than it knows; the fourth removes the
cost of decision 1 above. See plan.md, "Spec amendments".

- **The genesis is link 0, held in the chain record, not a row in the ledger.** A genesis
  row would be a second ledger row for the invocation that started the chain, breaking
  "exactly one row per invocation", which `AuditCoverage` asserts and every query relies on.
  Chained entries are numbered from 1.
- **"Content altered" and "link broken" are one kind of break: digest mismatch.** A digest
  covers the content, the position and the predecessor together; when it fails, the gem
  cannot honestly say which of the three changed. Gaps and duplicates are still reported as
  their own kinds, next to the mismatch they cause.
- **A changed pre-chain count is reported, not counted as a break.** During a rolling
  deploy, servers still on 0.5.0 keep writing contract-2 rows after the chain has started.
  Those rows are uncovered by definition. Calling them tampering would make every rolling
  deploy read as an attack.
- **The generated initializer derives the key from the application's `secret_key_base`**
  (Rails' key generator, with a reeve-specific salt). That satisfies "outside the database"
  in every environment, the test environment included, with no new secret to provision. A
  dedicated key replaces it with one line. The cost: rotating `secret_key_base` rotates the
  ledger key, so the old derived key must be kept as a retired key or older entries become
  unverifiable (never "tampered").

## User Scenarios & Testing *(mandatory)*

### User Story 1 - New entries are chained, and tampering with them is detected (Priority: P1)

A developer upgrades reeve, runs the upgrade, and supplies a key from configuration held
outside the database. From then on every ledger entry reeve writes is linked to the one
before it. Weeks later a compliance reviewer runs verification over the production ledger.
If anyone has edited, removed or reordered a chained entry, the report says which entry,
what kind of break it is, and how many breaks there are in total.

**Why this priority**: This is the guarantee. Everything else is how it is installed,
checked in CI, or explained. On its own it turns "the table looks fine" into "the chain
verified from entry 1 to entry 48,211".

**Independent Test**: Write a run of chained entries through a guarded tool; verify
(intact). Then, through raw SQL that bypasses the library, change one value in one entry,
delete a different entry, and swap the sequence numbers of two others; verify again and
confirm all three breaks are reported, each with its sequence number and kind.

**Acceptance Scenarios**:

1. **Given** a ledger at contract 3 with a key configured, **When** a guarded tool is
   invoked, **Then** the new entry carries a sequence number one greater than the previous
   chained entry, the identifier of the key that signed it, and a digest that links it to
   the previous entry.
2. **Given** 100 chained entries, **When** verification runs with no tampering, **Then** it
   reports the chain intact over sequences 1–100 and states how many earlier entries, if
   any, are not covered.
3. **Given** a chained entry whose recorded arguments were changed by raw SQL, **When**
   verification runs, **Then** it reports a content break at that entry's sequence number.
4. **Given** a chained entry deleted from the middle of the ledger, **When** verification
   runs, **Then** it reports the missing sequence number(s).
5. **Given** two chained entries whose sequence numbers were swapped, **When** verification
   runs, **Then** it reports a break at each of them, and does not stop at the first.
6. **Given** several independent breaks, **When** verification runs, **Then** every one is
   reported, and the totals per kind of break are complete even when the detailed list is
   long.
7. **Given** a ledger table whose rows were dumped and restored into a fresh database of the
   same engine, with new primary keys, **When** verification runs, **Then** the chain
   verifies intact.
8. **Given** a replayed invocation (an `invocation_id` already recorded), **When** it is
   recorded again, **Then** no new entry is written, no sequence number is consumed, and the
   chain record's head does not move.

---

### User Story 2 - Verification never reports more than it established (Priority: P1)

A reviewer runs verification over a ledger that is not fully chained — an upgraded ledger
with years of contract-2 rows, a ledger with no chain at all, a ledger whose key is not
available to the person verifying, or a chain containing an entry that was written without
a key. Each case is reported for what it is. None of them reads as a clean pass.

**Why this priority**: The defects reeve has shipped and fixed so far were, almost every
time, the gem reporting a guarantee it had not established (a `GuardDeclared` check that
could never fail, fixed in 0.4.0; a compliance run that certified the subset of tools reeve
knew about as if it were the whole endpoint, fixed in 0.5.0). A tamper-evidence feature
that can print "intact" over rows it never checked is worse than not having one. This story
is the same priority as US1 because US1 is not shippable without it.

**Independent Test**: Construct each of the ledgers below in a test database and confirm the
outcome and wording of each report.

**Acceptance Scenarios**:

1. **Given** a ledger with no chain (no chain record, no chained entries), **When**
   verification runs, **Then** the outcome is "no chain", it states how many entries are
   present, and it is not reported as a pass.
2. **Given** 5,000 contract-2 entries, then the start of the chain, then 300 chained
   entries, **When** verification runs, **Then** the outcome is "intact" for sequences
   1–300, and the same summary states that 5,000 entries are not covered.
3. **Given** an entry written after the genesis without a digest (missing key under
   `:warn`, or a host recorder that did not chain), **When** verification runs, **Then** it
   reports that entry as an unchained break, not as an uncovered legacy row.
4. **Given** chained entries signed by a key the verifier does not have, **When**
   verification runs, **Then** those entries are reported as unverifiable, distinct from
   both "intact" and "tampered".
5. **Given** a chain whose most recent entries were deleted but whose head still
   records the later sequence, **When** verification runs, **Then** it reports the head as
   ahead of the last entry found.
6. **Given** no key configured for the verifier at all, **When** verification runs, **Then**
   the status is `unverifiable`, it says that no key was available, and it claims nothing
   else about the chain.

---

### User Story 3 - Upgrade an existing ledger without rewriting history (Priority: P2)

A developer on 0.5.0 bumps the gem, runs `reeve:upgrade`, migrates, and adds the one
initializer line the upgrade prints. The existing rows are untouched — nothing is
backfilled into an append-only table — and the first chained write creates the chain record,
whose genesis records where the chain starts. A fresh install reaches the same state with `reeve:install` alone.

**Why this priority**: Without an upgrade path the feature reaches only new installs, and
0.3.0 exists because the install generator cannot be re-run to upgrade. It is P2 because
US1–US2 can be built and tested against a freshly installed table first.

**Independent Test**: Install a contract-2 ledger, write rows, run the upgrade generator
and migrations, invoke a guarded tool, and confirm: the old rows are byte-for-byte
unchanged, the chain record and its genesis exist, the new entry is chained after it, and verification
reports the old rows as uncovered and the chain as intact.

**Acceptance Scenarios**:

1. **Given** a contract-2 ledger, **When** `reeve:upgrade` runs, **Then** it emits only the
   contract-3 step, and running it again afterwards reports nothing to do.
2. **Given** an upgraded ledger with no chain yet, **When** the first chained entry is
   written, **Then** the chain record is created with its genesis just before that entry,
   in a step of its own (see FR-022), recording when the chain started and how many entries
   preceded it.
3. **Given** a gem upgraded to contract 3 on a table still at contract 2, **When** a guarded
   tool is invoked, **Then** the failure names the missing upgrade and the command that
   performs it, rather than a database column error.
4. **Given** a fresh `reeve:install`, **When** migrations run and the first tool is
   invoked, **Then** the ledger is chained from its first entry and verification reports no
   uncovered entries.

---

### User Story 4 - Prove the chain in CI, and check it in production (Priority: P2)

A developer adds nothing to their test suite: the compliance suite they already run (RSpec
or Minitest) now includes a ledger-chain check that verifies the test ledger after the
suite's invocations. Separately, operations runs `bin/rails reeve:verify_ledger` against
production on a schedule; it streams the ledger rather than loading it, and its exit status
distinguishes "intact", "broken" and "could not verify".

**Why this priority**: Constitution III — a guarantee ships with the assertion that proves
it, in both frameworks. The rake task is how the guarantee is actually exercised where it
matters; the check is how a host knows its configuration produces chained entries at all.

**Independent Test**: Run the compliance suite in a host app with a key configured (check
passes), without a key (check fails, naming the missing key), and with
a tampered fixture ledger (check fails naming the break). Run the rake task against each of
the US2 ledgers and confirm exit statuses.

**Acceptance Scenarios**:

1. **Given** a compliance run in which guarded tools were invoked and a key is configured,
   **When** the ledger-chain check runs, **Then** it passes and states the range it covered.
2. **Given** a compliance run with no compliance tools or no ledger loaded, so the check can
   write and examine nothing, **When** the check runs, **Then** it is skipped with a message
   saying the chain was not verified — never passed.
3. **Given** the same check, **When** it runs under RSpec and under Minitest, **Then** it
   reaches the same result in both.
4. **Given** an intact production ledger, **When** the rake task runs, **Then** it exits
   with success and prints the covered range and the uncovered count.
5. **Given** a ledger with any break, **When** the rake task runs, **Then** it exits with a
   status that means "broken", distinct from the status that means "could not verify" (no
   chain, no key, unknown key).
6. **Given** writes continuing during verification, **When** the rake task runs, **Then** it
   verifies up to the head as it stood when verification began, says so, and neither
   blocks writers nor reports in-flight entries as missing.

### Edge Cases

- **Concurrent writers.** Many processes recording at once must produce one gap-free chain
  with no duplicated sequence numbers. Chained writes are serialized
  through the chain record;
  under contention they wait for it rather than fail, up to the database's own lock timeout,
  after which the write fails and `audit_failure_mode` decides what the caller sees.
- **A host transaction wrapped around the invocation** (default `Recorder`). The chain record
  is locked until the *host* transaction ends, so every other guarded invocation in the
  application waits behind it. This is a real cost, not a corner case; it MUST be documented
  next to the existing warning, and `IsolatedRecorder` named as the answer where available.
  If the host transaction rolls back, the entry and the head move roll back together, so the
  chain stays gap-free.
- **SQLite.** One writer at a time already; chaining must work there with the default
  recorder. `IsolatedRecorder` continues to refuse SQLite.
- **Database value normalization.** JSON columns may store keys in a different order than
  written (PostgreSQL `jsonb`, MySQL `JSON`); timestamps may be stored at reduced precision.
  An entry must verify after being read back, not only as it was in memory when written.
- **Two databases, one engine.** A same-engine dump and restore changes primary keys; the
  chain does not depend on them. A restore into a *different* engine is not claimed to
  verify (see Assumptions).
- **Key present but too short or empty.** Treated as no key; rejected when configured, not
  on first write.
- **Key rotated mid-ledger.** Entries before the rotation verify with the old key and
  entries after with the new one, provided both are available to the verifier.
- **Retired key removed from configuration.** Entries it signed become unverifiable; they
  are not reported as tampered and not reported as intact.
- **Genesis written twice** (two processes racing to start the chain). Exactly one chain
  record may exist; the loser of the race chains after the winner's entry.
- **A chain started, then its first write failed.** The chain record exists with its head at
  0 and nothing in it. Reported as no chain; the next chained write becomes sequence 1.
- **Entries added to or removed from the pre-chain region.** Not detected. Verification
  reports the number of uncovered entries now beside the number recorded when the chain
  started; a difference is shown, never judged, because servers on an older reeve version
  legitimately write uncovered entries during a rolling deploy.
- **Rolling deploy.** Old servers write contract-2 entries after the chain starts. They are
  uncovered, counted as such, and do not break the chain.
- **A key configured late under `:warn`.** Contract-3 entries written without a key before
  the chain started are counted at genesis and reported as uncovered, not as breaks.
  Unchained entries beyond that count are breaks: they can only have been written after
  the chain started, because servers on an older reeve version write contract 2.
- **A forged entry numbered past the head.** Verification reports it. It also takes the
  sequence number the next legitimate write needs, so that write fails on the unique
  sequence and `audit_failure_mode` decides what the caller sees: the tampering is loud
  in both places.
- **Very large ledgers.** Verification memory use must not grow with the ledger; the
  detailed list of breaks may be capped in output, but the totals never are.
- **A host recorder writing to reeve's table.** Contract-3 entries it writes without chaining
  are reported as unchained breaks; reeve provides a way for such a recorder to chain them.

## Requirements *(mandatory)*

### Functional Requirements

**Chaining**

- **FR-001**: Every entry reeve writes to a contract-3 ledger MUST carry a chain sequence
  number, the identifier of the key that signed it, and a keyed digest.
- **FR-002**: The digest MUST cover: the previous chained entry's digest, the entry's own
  sequence number, the key identifier, and every audit-entry contract field the entry
  records. It MUST NOT cover the database primary key or any value the database assigns.
- **FR-003**: The digest MUST be computed over a canonical form of the recorded values that
  is stable under each supported database's own storage normalization, so that an
  untampered entry verifies after it is read back on SQLite, PostgreSQL and MySQL.
- **FR-004**: Sequence numbers MUST be assigned by reeve, start at 1 with the first chained
  entry (the genesis is link 0, see FR-022), and increase by exactly 1 per chained entry, with no gaps produced by reeve itself —
  including under concurrent writers, under a rollback of the host's transaction, and on a
  replayed invocation (which writes nothing and consumes nothing).
- **FR-005**: There MUST be a single chain per ledger. Chained writes MUST be serialized
  through the chain record, and the head's advance and the entry's insert MUST commit
  together or not at all.
- **FR-006**: Chaining MUST work with `Reeve::Audit::Recorder` on SQLite, PostgreSQL and
  MySQL, and with `Reeve::Audit::IsolatedRecorder` on PostgreSQL and MySQL.
- **FR-007**: reeve MUST provide a supported way for a host-supplied `audit_recorder` that
  writes to reeve's table to produce chained entries. Entries such a recorder writes
  without it are reported by verification as unchained.

**The key**

- **FR-008**: The key MUST come from host configuration and MUST NOT be stored in, derived
  from, or written to the database, the ledger, logs, error messages, or verification
  output. Key identifiers MAY appear in all of those.
- **FR-009**: A key shorter than a documented minimum length, or empty, MUST be rejected
  when it is configured, with a message naming the requirement.
- **FR-010**: With no usable key on a contract-3 ledger: under `audit_failure_mode = :fail`
  every guarded invocation MUST fail with the existing audit-write error, naming the
  missing key and how to supply it; under `:warn` the invocation MUST proceed, the entry
  MUST be written unchained and identifiable as such, and a warning MUST be logged.
- **FR-011**: Configuration MUST accept one *current* key used for signing and any number
  of *retired* keys used only for verification, each with a stable identifier.

**Verification**

- **FR-012**: Verification MUST report, separately: (a) the status of the chain —
  `intact`, `broken`, `unverifiable`, or `no_chain`; (b) its coverage — the sequence range
  verified and the number of entries that precede the genesis. A summary that states (a)
  MUST state (b) in the same line.
- **FR-013**: Verification MUST continue past the first break and report every break with
  its sequence number (or the missing range; an unchained entry has no sequence and is
  identified by its `invocation_id`) and its kind. Kinds: *digest mismatch* (the
  entry does not verify at its position: its content, its sequence number, or its
  predecessor changed — editing, reordering, swapping and insertion all surface here, and
  the report says that it cannot tell which), *missing* (a gap in sequence numbers),
  *duplicate* sequence, *unchained* (a contract-3 entry outside the chain — no sequence number — beyond the number that already existed
  when the chain started — see FR-022), *head mismatch*
  (the chain record disagrees with the last entry found), *genesis altered*, *chain record
  missing* (chained entries exist but the chain record does not), *beyond head* (a chained
  entry numbered past the head, which reeve cannot have written, since an entry and its
  head move commit together), and *unknown key* (reported as unverifiable, FR-014). The number of uncovered pre-chain entries, now and
  at genesis, is reported beside the status and is not a break.
- **FR-014**: Entries signed with a key the verifier does not hold MUST be reported as
  unverifiable and counted separately; they MUST NOT contribute to an `intact` status. A
  verifier with no key at all MUST NOT report any chain status other than `unverifiable`.
- **FR-015**: Verification MUST be read-only, MUST NOT block writers for its duration, MUST
  verify up to the head as it stood when it began, MUST then report any chained entry
  numbered past the head as it stands when it ends, and MUST use memory independent of
  ledger size.
- **FR-016**: Re-signing existing entries under a new key MUST NOT be offered. History
  signed under a key stays signed under that key; rotation affects new entries only.
- **FR-017**: Verification MUST be available as a plain Ruby entry point usable without
  Rails, and as `bin/rails reeve:verify_ledger`, which prints the summary and every break
  (with the detailed list cappable but the totals always complete) and exits with distinct
  statuses for `intact`, `broken`, and "could not verify" (`unverifiable` or `no_chain`).

**Testing kit**

- **FR-018**: Both compliance suites (RSpec and Minitest) MUST include a ledger-chain check
  that writes entries of its own and then verifies the whole ledger visible to the run. It
  MUST pass only on an `intact` chain with at least one chained entry. It MUST fail on
  `broken`, on an unchained entry, on `unverifiable`, and when no key is configured (in a
  run that writes its own entries, each of these is a configuration error). It MUST be
  *skipped*, with a message saying the chain was not verified, when there is nothing it
  can write or examine (no compliance tools, ledger not loaded) — never passed.

**Contract and upgrade**

- **FR-019**: The audit-entry contract MUST move from 2 to 3. The new columns MUST be
  additive and nullable, as the contract's own rule requires. The bump is MAJOR because
  the meaning of an absence changes: on a contract-3 entry a missing digest is a break,
  where on earlier entries it means the entry predates chaining. The contract document,
  `Reeve::Audit`'s "what it does not" comments, the README and the CHANGELOG MUST be
  updated to match the guarantees section of this spec, word for word in substance.
- **FR-020**: `reeve:upgrade` MUST emit the contract-3 step only when the table lacks it,
  and `reeve:install` MUST produce a contract-3 table directly. Existing entries MUST NOT
  be modified.
- **FR-021**: The generated initializer MUST configure a key that works in every
  environment, test included, without a new secret: derived from the application's
  `secret_key_base` with a reeve-specific salt. It MUST show the one-line alternative of a
  dedicated key, and MUST NOT generate or embed a key value. The upgrade output MUST show
  the line to add to an existing initializer. The documentation MUST state that rotating
  `secret_key_base` rotates the ledger key.
- **FR-022**: The chain MUST begin with a genesis, created just before the first chained
  entry in a step of its own (amended during US4: created inside that entry's write, it
  deadlocked on MySQL, research R3), that records when the chain started, the number of entries already in the
  ledger, the number of those that are contract-3 entries written without a key, and the key
  that signed it, under its own keyed digest. The genesis is link 0: it
  is held in the chain record rather than as a ledger row, so ledger queries and the
  existing compliance checks never see it as an invocation. A chain started with no entry
  yet (head 0) MUST be reported as `no_chain`, never as an intact chain of nothing.
- **FR-023**: Every guarantee in this section MUST be covered by a test that fails with the
  behaviour reverted, run on SQLite, PostgreSQL and MySQL in CI — including concurrent
  writers on PostgreSQL and MySQL.

### Key Entities

- **Chained entry**: an audit entry written under contract 3. Adds a sequence number, a key
  identifier, and a digest linking it to its predecessor. All other fields are the existing
  contract-2 fields, unchanged in meaning.
- **Chain record**: the single record for the ledger's chain. Holds the genesis (link 0:
  when the chain started, how many entries preceded it and how many of those were unchained
  contract-3 entries, its key and digest — written once)
  and the head (latest sequence number and digest — advanced by every chained write). The
  point every chained write serializes on, and the reference verification checks the tail
  against.
- **Signing key**: a secret held in host configuration with a stable identifier. One is
  current; zero or more are retired and used only to verify.
- **Verification result**: chain status, coverage (range verified, entries before genesis),
  totals per kind of break, unverifiable count, and the list of breaks.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Each tamper class in the "Detected" list is detected in 100% of test cases on
  all three supported databases, and each testable "Not detected" class (items 1–4) is demonstrated by a test
  that documents it as undetected — so the limits are pinned as firmly as the guarantees.
- **SC-002**: An untampered ledger verifies `intact` in 100% of cases across the three
  databases, including entries whose arguments and metadata hold nested structures,
  non-ASCII text, numbers, booleans and nulls, and after a same-engine dump and restore.
- **SC-003**: 8 concurrent writers recording 1,000 invocations each produce 8,000 chained
  entries with sequence numbers 1–8,000, no gaps, no duplicates, no
  deadlocks, verified `intact` — on PostgreSQL and MySQL.
- **SC-004** *(measured 2026-10-10: memory met on both engines; time met on SQLite, 184 s,
  and missed on PostgreSQL, 331 s — see verification.md)*: Verification of a 1,000,000-entry ledger completes in under 5 minutes on a
  developer laptop with peak memory that does not grow by more than 10% between a 100,000-
  and a 1,000,000-entry ledger.
- **SC-005**: Chaining adds no more than 5 ms to the median ledger write for a single
  uncontended writer on a local database, measured against 0.5.0.
- **SC-006**: No verification output, under any ledger state in this spec, contains the word
  "intact" or "pass" without the coverage statement on the same line, and no state other
  than an intact chain with zero breaks and zero unverifiable entries produces a success
  exit status or a passing check.
- **SC-007**: A 0.5.0 host reaches a verified chain in three steps — upgrade generator,
  migrate, add the one initializer line the upgrade prints — with no edit to existing rows
  and no new secret to provision.

## Assumptions

- **Same-engine restore only.** A dump restored into the same database engine verifies; a
  migration across engines (for example PostgreSQL to MySQL) is not claimed, because
  timestamp precision and JSON normalization differ between engines. Documented as such.
- **The key lives with the host's other secrets.** By default it is derived from
  `secret_key_base`; a dedicated key may come from credentials or an environment variable.
  reeve reads it from configuration and does not prescribe a secret store.
- **Single database.** One ledger table, one chain. A host sharding the ledger across
  databases is out of scope.
- **The pre-chain region is protected only by count.** Hashing every legacy row at genesis
  would make the first chained write O(rows); the genesis records the count instead, and
  the spec says plainly that this detects a changed count and nothing more.
- **Rake integration requires Rails.** reeve does not load a Railtie today; adding one only
  to register the rake task is acceptable, provided `require "reeve"` keeps working without
  Rails.

### Out of scope (future work)

- **External anchoring of checkpoints** — publishing the chain record's head somewhere the database
  cannot change, which is what closes tail truncation (limit 2 above).
- **Retention, rotation and archival of entries.** Note for whoever builds it: removing old
  entries breaks the chain by design, so retention will need a checkpoint the chain can be
  verified from — it is not a matter of deleting rows.
- **Re-signing history** under a new key (FR-016).
- **Per-tool or per-tenant chains.**
