# Feature Specification: Ledger Anchoring

**Feature Branch**: `004-ledger-anchoring`
**Created**: 2026-10-25
**Status**: Draft
**Input**: "External anchoring of the tamper-evident ledger's chain head and key-epoch records.
Publish a checkpoint of the chain (head sequence and digest, plus the epoch records) somewhere
the database cannot change, so verification can detect tail truncation and deletion of the
whole ledger, which specs/002 lists as not detected, and so epoch records from specs/003
cannot be silently rewritten. Builds on specs/002-tamper-evident-ledger and
specs/003-ledger-key-epochs; the checkpoint should also be what future retention can verify
from."

## Overview

Everything the chain can be checked against today lives in the same database as the chain:
the entries, the chain record (genesis and head), and the key epochs. Someone who can write to
that database but holds no key cannot forge an entry, but can still do three things
verification does not catch (specs/002 "Not detected" items 2 and 3, specs/003 item 6):

1. **Delete the newest entries and rewind the head** to the entry before them. What remains is
   a shorter chain that is internally consistent and verifies INTACT.
2. **Delete the whole ledger, chain record and epochs included.** Verification reports NO
   CHAIN, which is honest but cannot tell an emptied ledger from one that was never chained.
3. **Delete the newest epoch record while no entry names it yet.** Nothing in the database
   points at it.

All three are the same gap: the database is the only witness to how far the chain reached. This
feature adds a second witness the database cannot change. A **checkpoint** is a small signed
statement, "on this date the ledger's chain reached sequence N with digest D, under epoch E",
that reeve produces and the host stores somewhere outside the database. Verification given
checkpoints checks that the ledger still reaches every point they name.

A checkpoint carries digests and counts, never entry content, so it can be stored in places
with weaker access control than the ledger (a log service, an object store, a ticket) without
disclosing what the ledger records.

The same statement is what a future retention feature needs (specs/002 future work: "retention
will need a checkpoint the chain can be verified from"). This feature makes verification able
to start from a checkpoint instead of the genesis, which is the half of retention that is
about proof. Deleting old entries stays out of scope.

### What this feature guarantees, and what it does not

Normative, like specs/002's and specs/003's equivalent sections, which still hold in full.
Documentation, CHANGELOG and output MUST NOT claim more.

**Added detection**, when verification is given a checkpoint and the attacker holds no ledger
key and cannot change or delete the checkpoint where it is stored:

- removal of any entry at or before the checkpoint's sequence, including the newest entries
  together with a rewound head;
- deletion of the whole ledger, or of the chain record, or its replacement by a different
  chain (a new genesis): reported as BROKEN, no longer as NO CHAIN;
- any change to, deletion of, or insertion before an epoch record that existed when the
  checkpoint was made, including the newest one when no entry names it yet;
- a checkpoint that was edited, or forged without a key the verifier holds.

**Not detected / not changed, stated plainly:**

1. **Anything after the latest checkpoint.** Entries written after it can still be truncated
   with a rewound head. The window is exactly the time between checkpoints, and the report
   always says how many entries are beyond the latest checkpoint.
2. **Deletion of the checkpoints themselves.** If the store lets the attacker delete or
   overwrite checkpoints, the protection falls back to whichever checkpoints survive, or to
   specs/002's. reeve cannot make a store append-only; choosing one that is (or that the
   database's attackers cannot reach) is the host's part, and the documentation says so.
3. **Key compromise.** A holder of a ledger key can recompute the chain and sign a matching
   checkpoint, as before (specs/002 item 1). A checkpoint made before the compromise still
   pins the chain up to its sequence: rewriting an entry it covers changes the digest it names.
4. **A verifier not given the checkpoints.** Verification without checkpoints behaves exactly
   as in 0.7.0, and says on its summary line that it was not anchored.
5. **Trust in the time on a checkpoint.** The time is the producing host's clock, recorded for
   people. Nothing in verification depends on it, and it proves nothing about when the
   checkpoint was really made, unless the store itself records that.
6. **Prevention.** As in specs/002, this detects after the fact.

## Clarifications

### Session 2026-10-25

Decisions taken while writing this specification (answered in-session, not by the maintainer;
each is recorded so it can be overruled before planning):

- Q: Does the audit-entry contract bump? → A: **No.** Nothing in the ledger table changes, and
  no new table is added: a checkpoint kept in the database would be exactly as changeable as
  the head it is meant to witness. The checkpoint gets its own format version (FR-003).
- Q: What does a checkpoint name, given that it must cover every epoch? → A: The genesis digest,
  the head's sequence and digest, and the latest epoch's number and digest. Epoch digests
  already chain each epoch to the one before it and epoch 0 to the genesis (specs/003 FR-002),
  so naming the latest epoch pins all of them, the same way naming the head pins every entry.
- Q: Is the checkpoint signed, given that it is stored outside the database? → A: Yes, with the
  configured ledger key (amendment 1), and it names that key's fingerprint. The store's access control is what
  stops deletion, and a signature is what stops a forged or edited checkpoint from being
  believed. A verifier without that key reports the checkpoint as unverifiable, never as
  checked.
- Q: Does making a checkpoint verify the chain first? → A: No. A checkpoint is a statement of
  where the chain reached, not that it was intact. Tampering before a checkpoint is still
  caught by the chain itself, and a truncation made before a checkpoint is caught by any
  earlier checkpoint, whose entry the truncation removed or replaced (FR-011). Requiring a
  full walk would make each checkpoint cost minutes on a large ledger and discourage making
  them often, which is what shrinks the window in guarantee item 1.
- Q: Where does verification read checkpoints from? → A: From the anchor (FR-006) or from
  checkpoints supplied by the caller, never from the database.
- Q: Where are checkpoints published? → A: **To an anchor the host supplies** (maintainer,
  2026-10-25). reeve ships one built-in anchor, a file it only appends to, and documents how to
  back it with a store the database's attackers cannot change (for example an object-locked
  bucket). No integration with a specific service: it would add a dependency and a vendor to
  the core (constitution IV, VI), and the host already has a place for records it must keep.
- Q: When are checkpoints made? → A: **On demand only** (maintainer, 2026-10-25): a task and a
  library call the host schedules (a cron job, a deploy step), plus one after each rotation
  that opens an epoch (FR-008). Never from the write path, so a ledger write never waits on or
  fails because of the store. The cost, stated plainly: the window in guarantee item 1 is
  whatever schedule the host keeps, and reeve cannot enforce one; the report's "entries after
  the latest checkpoint" count is what makes a lapsed schedule visible.

### Amended during planning (2026-10-25)

Two changes made by `/speckit.plan`; see plan.md and research.md R3, R4.

1. **A checkpoint is signed by the configured ledger key**, not "the current epoch's key". During
   a rolling deploy a process may hold an earlier epoch's key; a checkpoint it makes is still
   verifiable by anyone holding that epoch, and the key it names is in the line.
2. **Checkpoints are not checked against each other.** A rule like "a later checkpoint never
   names a lower sequence" needs a trusted clock or a trusted order, and the store supplies
   neither. Every case such a rule would catch already fails when each checkpoint is checked
   against the ledger: after a truncation and regrowth the higher checkpoint's entry is gone or
   different, and of two digests at one sequence at most one is the entry's.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A truncated tail is caught by a checkpoint (Priority: P1)

An operator schedules a checkpoint every hour. A week later someone with database access
deletes the last day of entries and rewinds the head to match. A reviewer runs verification
with the stored checkpoints. The report says BROKEN and names the checkpoint the ledger no
longer reaches, with its sequence.

**Why this priority**: This is the gap the feature exists to close (specs/002 item 2). Without
it the rest is bookkeeping.

**Independent Test**: Write entries, make a checkpoint, write more; delete every entry after
some sequence before the checkpoint's and rewind the head with raw SQL. Verification without
checkpoints: INTACT (the 0.7.0 limit, pinned). With the checkpoint: BROKEN, naming it.

**Acceptance Scenarios**:

1. **Given** a checkpoint at sequence 500 and a ledger at 800, **When** entries 401 to 800 are
   deleted and the head rewound to 400, **Then** verification with the checkpoint is BROKEN
   and names the checkpoint at 500 as not reached.
2. **Given** the same checkpoint, **When** only entries 501 to 800 are deleted and the head
   rewound to 500, **Then** verification is INTACT up to 500, anchored at 500, and the report
   states that the checkpoint does not cover anything after it (guarantee item 1).
3. **Given** a checkpoint at 500, **When** entry 500's content is changed, **Then** verification
   is BROKEN with a digest mismatch at 500 (as in 0.7.0) and the checkpoint is reported as not
   matching.
4. **Given** checkpoints at 500 and 900 where the ledger now ends at 700 with its head rewound,
   **Then** BROKEN, naming the checkpoint at 900; the one at 500 is reported as checked.

---

### User Story 2 - A deleted ledger is reported as tampering, not as "no chain" (Priority: P1)

Someone drops every ledger row, the chain record and the epochs, or replaces them with a fresh
ledger that starts a new chain. Verification with any checkpoint reports BROKEN and says the
chain the checkpoint names is gone, instead of NO CHAIN.

**Why this priority**: The whole-ledger case is the strongest form of the same attack and
specs/002 item 3 says it cannot be told apart from a ledger that was never chained. A
checkpoint is the only evidence that can.

**Independent Test**: Make a checkpoint; delete all rows from the three tables; verify with the
checkpoint: BROKEN. Write new entries so a new genesis exists; verify again: BROKEN, genesis
differs from the checkpoint's.

**Acceptance Scenarios**:

1. **Given** a checkpoint, **When** the ledger, chain record and epochs are emptied, **Then**
   verification with it is BROKEN (exit 1), not NO CHAIN (exit 2).
2. **Given** a checkpoint, **When** the ledger is emptied and new entries start a new chain,
   **Then** BROKEN: the genesis is not the one the checkpoint names.
3. **Given** no checkpoint, **When** the ledger is emptied, **Then** NO CHAIN, exactly as in
   0.7.0.

---

### User Story 3 - Epoch records are pinned by a checkpoint (Priority: P1)

An operator rotates the key, the rotation opens epoch 2, and a checkpoint is made before any
entry is written under it. Someone deletes the epoch 2 record. Verification with the
checkpoint reports BROKEN.

**Why this priority**: Closes specs/003 "Not detected" item 6 and is the "epoch records cannot
be silently rewritten" half of the input.

**Independent Test**: Rotate; checkpoint; delete the newest epoch record with raw SQL; verify
without the checkpoint: INTACT (pinned limit); with it: BROKEN.

**Acceptance Scenarios**:

1. **Given** a checkpoint naming epoch 2, **When** epoch 2's record is deleted, **Then** BROKEN,
   naming the epoch.
2. **When** any earlier epoch record is edited, **Then** BROKEN (as in 0.7.0, now also against
   the checkpoint).
3. **Given** the rotation task run with an anchor configured, **Then** it makes a checkpoint
   right after opening the epoch, so the newly opened epoch is pinned without a separate step.

---

### User Story 4 - The report says what was anchored (Priority: P2)

A reviewer reads a verification report and can tell, from its summary line alone, whether
truncation was checked and up to where.

**Why this priority**: specs/002 SC-006 made "intact" impossible to print without its coverage.
Anchoring is now part of what "intact" means, so it must sit on the same line.

**Independent Test**: Verify the same intact ledger with no checkpoint, with a stale one, and
with a current one; read the summary lines.

**Acceptance Scenarios**:

1. **Given** no checkpoint supplied, **Then** the INTACT line says "not anchored".
2. **Given** checkpoints, **Then** the INTACT line names the latest checkpoint's sequence and
   date and the number of entries after it.
3. **Given** a checkpoint signed by a key the verifier does not hold, **Then** the result is
   UNVERIFIABLE, naming the key fingerprint, never INTACT.
4. **Given** FORMAT=json, **Then** the result lists every checkpoint checked and its outcome.

---

### User Story 5 - Verification from a checkpoint (Priority: P3)

The operator of a large ledger verifies only what was written since the last checkpoint that
already verified intact, instead of walking from the genesis every time.

**Why this priority**: Useful for large ledgers, and it is what proves that a checkpoint is
enough to verify from, which retention will depend on. Nothing in P1 or P2 needs it.

**Independent Test**: Ledger of 10,000 entries; checkpoint at 9,000; verify from it: the walk
covers 9,001 to 10,000, links 9,001 to the checkpoint's digest, and reports 1 to 9,000 as not
covered by this run.

**Acceptance Scenarios**:

1. **Given** a checkpoint at 9,000, **When** verification starts from it, **Then** coverage is
   9,001 to the head and the summary line counts 9,000 entries as not covered by this run.
2. **When** entry 9,001 no longer links to the checkpoint's digest, **Then** BROKEN at 9,001.
3. **When** entry 9,000 differs from the checkpoint, **Then** BROKEN: the starting point itself
   is checked.

---

### Edge Cases

- **Checkpoint of a ledger with no chain yet**: refused with a message; there is nothing to
  pin. Not an error at write time.
- **A checkpoint made while writes continue**: it names a head that was committed when it was
  read, with the epoch that was latest then; later writes do not invalidate it.
- **Two checkpoints at the same sequence**: both checked; consistent if they agree.
- **Checkpoints that contradict each other** (the same sequence with two digests, or a
  truncation and regrowth between two of them): BROKEN, naming each checkpoint whose entry the
  ledger no longer has. The order they were made in is never needed.
- **Restore from a backup taken before a checkpoint**: verification with that checkpoint is
  BROKEN, because the restored ledger is truncated relative to it. That is the truth; the
  documentation tells operators to expect it and says the restored ledger has lost entries.
- **Same-engine dump and restore** (specs/002 SC-002): checkpoints still verify; they name
  sequences and digests, not row ids.
- **Checkpoint signed by a retired key**: verifies if that key is configured as retired.
- **Rolling deploy with stragglers**: a checkpoint names the head and the latest epoch, not the
  epoch of the newest entry; a straggler at the head is fine.
- **The anchor fails** (store unreachable) when the task runs: the task fails with exit 1 and
  the error; writes are never affected.
- **A malformed or unknown-version checkpoint**: refused with a message naming it; never
  silently skipped.
- **Ledger whose rows predate the chain** (contracts 1 and 2): a checkpoint pins only the
  chained part; the pre-chain count is carried and checked like the genesis.

## Requirements *(mandatory)*

### Functional Requirements

**Checkpoints**

- **FR-001**: A checkpoint records: the ledger name, the genesis digest and the pre-chain counts
  the genesis holds, the head sequence and head digest, the latest epoch's number and digest
  (when the ledger has epochs), the fingerprint of the key that signed it, the time it was
  made, the reeve version, and the checkpoint format version.
- **FR-002**: A checkpoint is signed with an HMAC under the configured ledger key, over a
  canonical form tagged distinctly from entry, genesis and epoch digests.
- **FR-003**: A checkpoint is a self-contained text document (one line of JSON), so it can be
  stored anywhere text can, printed, and read back without reeve's database. Its format has a
  version of its own, documented in a contract next to the audit-entry contract.
- **FR-004**: A checkpoint contains no entry content and no key: only digests, sequences,
  counts, fingerprints and the time.
- **FR-005**: Making a checkpoint reads the head and the latest epoch as one consistent state
  that was committed, and does not block writes for longer than one chained write would.

**Publishing**

- **FR-006**: The host may configure one anchor: an object reeve hands each new checkpoint to
  and that can return the checkpoints it holds. Any object with those two operations works.
- **FR-006a**: reeve ships one anchor: a file, given by path, that it only appends to, one
  checkpoint per line, and reads back whole. It never rewrites or truncates the file. The
  README states that a local file on the database host protects nothing, and shows the file
  anchor backed by a store the database's attackers cannot change.
- **FR-007**: `bin/rails reeve:checkpoint_ledger`, backed by `Reeve::Tasks` and a library call,
  makes a checkpoint, hands it to the anchor if one is configured, and prints it. Exit 0 on
  success, 1 if the anchor refused or failed. Checkpoints are made only by this task, this
  call, and the rotation task (FR-008); the host schedules them.
- **FR-008**: `bin/rails reeve:rotate_ledger_key`, when it opens an epoch and an anchor is
  configured, makes a checkpoint afterwards. A failure to anchor is reported and gives exit 1,
  but does not undo the rotation.
- **FR-009**: No ledger write waits on, or fails because of, the anchor.

**Verification**

- **FR-010**: Verification accepts checkpoints from the configured anchor or from the caller
  (the task reads them from a path the operator gives). It never reads checkpoints from the
  ledger's database.
- **FR-011**: For each checkpoint, verification checks: its signature, under a configured key
  (else unverifiable); its genesis digest and pre-chain counts against the chain record; that
  the entry at its sequence exists and has its digest; and that the epoch it names exists with
  its digest. Each checkpoint is checked on its own; none is compared with another (amendment 2).
- **FR-012**: A checkpoint the ledger no longer matches is a break: status BROKEN. New break
  kinds are listed in the result and its JSON, each naming the checkpoint by sequence and time.
- **FR-013**: When checkpoints are supplied and the chain record or every entry is missing, the
  status is BROKEN, not NO CHAIN.
- **FR-014**: The summary line of every status that walked the chain states the anchoring: "not
  anchored", or the latest checkpoint checked (sequence and date) and the number of entries
  after it. No output says "intact" without it on the same line.
- **FR-015**: Verification can start from a checkpoint: it checks the checkpoint's own entry,
  walks from the next sequence, and reports the entries before it as not covered by this run.
- **FR-016**: Checking checkpoints adds one query per checkpoint at most and does not change the
  walk's per-batch queries (specs/002 FR-014, specs/003 FR-014).

**Testing kit, docs**

- **FR-017**: `Reeve::Checks::LedgerChain` accepts checkpoints, and can require that the ledger
  is anchored, so a host's CI can assert it.
- **FR-018**: README's tamper-evidence section documents checkpoints: how to schedule them, that
  the store must be one the database's attackers cannot change, and what the window means.
- **FR-019**: CHANGELOG carries an unreleased entry with the new task and the guarantees section's
  limits, in plain words.

### Key Entities

- **Checkpoint**: a signed statement of where the chain reached at a moment: genesis, head,
  latest epoch, signing key fingerprint, time, versions. Lives outside the database.
- **Anchor**: the host's store for checkpoints, as reeve sees it: something to hand a
  checkpoint to and to read checkpoints back from.
- **Checkpoint result**: per checkpoint, as verification found it: checked, not reached,
  contradicted, or unverifiable (key not configured).

## Success Criteria *(mandatory)*

- **SC-001**: Each case in User Stories 1 to 3 (truncation with a rewound head, emptied ledger,
  replaced chain, deleted or edited epoch record) is reported BROKEN in 100% of tests when a
  checkpoint covering it is supplied, on all three databases; and each is shown INTACT or NO
  CHAIN without one, so the old limit is pinned beside the new guarantee.
- **SC-002**: An untampered ledger with any number of checkpoints, including across rotations
  and with stragglers, verifies INTACT in 100% of tests.
- **SC-003**: No output line containing "intact" or "pass" lacks the anchoring statement
  (FR-014), in every state the specs build, text and JSON.
- **SC-004**: Ledger write cost is unchanged from 0.7.0 (within the noise of specs/003's
  measurement), and making a checkpoint of a 1,000,000-entry ledger takes under 1 second.
- **SC-005**: A host can schedule checkpoints and verify with them from the README and the
  CHANGELOG alone (checked by a cold read).
- **SC-006**: Full suite green on SQLite, and on PostgreSQL and MySQL where CI runs them.

## Assumptions

- The threat model is specs/002's, plus: the attacker cannot change or delete checkpoints where
  the host stores them. The host chooses the store; reeve documents what it must provide.
- One ledger per database, as in specs/002 and specs/003.
- Positioning (constitution IV): no Ruby audit gem (paper_trail, audited, logidze) anchors a
  keyed chain externally, and reeve hands storage to the host rather than competing with
  storage services.
- Gem version and release are separate from this branch; the CHANGELOG entry is "Unreleased".

### Out of scope (future work)

- Retention: deleting or archiving entries before a checkpoint. This feature only makes
  verification able to start from one.
- Proving when a checkpoint was made (trusted timestamps) beyond what the store records.
- Checkpoints a third party can verify without the ledger key (asymmetric signatures; specs/003
  out of scope).
- Anchoring more than one ledger.
