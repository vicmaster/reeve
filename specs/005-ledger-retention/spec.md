# Feature Specification: Ledger Retention

**Feature Branch**: `005-ledger-retention`
**Created**: 2026-10-25
**Status**: Draft
**Input**: "Ledger retention: archiving or deleting audit ledger entries before a checkpoint, with
verification from that checkpoint. Builds on specs/004-ledger-anchoring (checkpoints,
FROM=latest verification) and specs/002/003. A purge must never read as tampering, and
tampering must never pass as a purge."

## Overview

The ledger only grows. A host that must keep a year of audit history, or must not keep more
than that, has no supported way to remove older entries: deleting them by hand breaks the
chain by design (specs/002 future work), and every later verification reports the gap as
tampering.

specs/004 built the half retention needs: a checkpoint names a point the chain reached, and
verification can start from one. This feature adds the other half: a **purge** that removes
the entries up to a checkpoint and leaves behind a signed **retention record** saying exactly
what was removed, up to where, under which checkpoint. Verification then starts from that
boundary and reports the removed range as retained-away, not missing.

Two rules govern everything here, from the input:

1. **A purge never reads as tampering.** After a legitimate purge, verification reports
   INTACT for what remains and names the purged range and its retention record.
2. **Tampering never passes as a purge.** Only entries that verified intact can be purged,
   only up to a checkpoint, and only by a retention record no one without a key can forge.
   Any removal that does not match a retention record is reported exactly as before: broken.

An archive, when written, holds the purged entries with their chain columns, so the range can
still be verified on its own, from the genesis to the boundary checkpoint, by anyone holding
the keys.

### What this feature guarantees, and what it does not

Normative, like the equivalent sections of specs/002, 003 and 004, which still hold in full.
Documentation, CHANGELOG and output MUST NOT claim more.

**Guaranteed**, provided the attacker holds no ledger key:

- every purged entry verified intact, under the chain's own rules, before it was removed;
- a purge removes exactly the entries at or before its boundary checkpoint, and the retention
  record says how many, of which kinds;
- removing any entry not covered by a retention record (one above the boundary, or below it
  with no record) is reported as broken, as in 0.7.0;
- a retention record that was edited, deleted while the purged range is gone, or forged, is
  reported as broken;
- an archive, verified on its own, is intact from the genesis to the boundary, or the check
  says where it is not.

**Not guaranteed, stated plainly:**

1. **A key holder can still rewrite anything**, a retention record included, as in specs/002
   item 1. A checkpoint made before the compromise still pins its entry (specs/004).
2. **What a purge removed is gone from the ledger.** Without an archive, nobody can read those
   entries again; the retention record proves only that they existed, verified, and were
   removed on purpose.
3. **An archive is a file.** Keeping it safe from deletion or edits is the host's part, as the
   anchor is. reeve can tell an archive that verifies from one that does not; it cannot keep
   one from being lost.
4. **An edit to a row inside the purged range while the purge runs** is not reported by the
   ledger, because the row is being removed; the archive holds what was read.
5. **Entries outside the chain** (written before the chain began, or unchained under
   `audit_failure_mode = :warn`) carry no digest, so their removal is counted, never verified.

## Clarifications

### Session 2026-10-25

Decisions taken while writing this specification (answered in-session, not by the maintainer;
each is recorded so it can be overruled before planning):

- Q: What may be purged? → A: **A prefix of the chain, ending at a checkpoint.** Entries 1 to
  S, where S is the sequence of a checkpoint that verifies. Nothing in the middle, nothing
  above the newest checkpoint. A prefix keeps the remaining chain whole: it links to S's digest
  exactly as a walk from that checkpoint does today (specs/004 FR-015).
- Q: Must the boundary be a published checkpoint? → A: **Yes: the purge needs a configured
  anchor, and its boundary must be a checkpoint that anchor holds.** A retention record in the
  database could be edited by someone who can also delete rows; the checkpoint in the anchor
  is what the database cannot change, so the boundary is witnessed from outside before
  anything is removed.
- Q: Does a purge verify first? → A: **Yes, the range it removes, in full.** The purge walks
  1 to S and refuses unless that range is intact. Purging a broken range would erase the
  evidence: exactly "tampering passing as a purge".
- Q: How is the boundary chosen? → A: **By age, or by naming it.** `OLDER_THAN=` (for example
  `365d`) picks the newest checkpoint whose entry occurred before the cutoff; `THROUGH=` names
  a checkpoint's sequence. Either way the task says what it will remove before removing it, and
  removes nothing without an explicit confirmation flag.
- Q: Rows outside the chain? → A: Pre-chain rows (contracts 1 and 2) are purged with the first
  purge, and the genesis's pre-chain count is then reported as purged, not changed. Unchained
  contract-3+ rows are left in place: their place in time is known only by clock, and guessing
  wrong would delete a row the ledger still needs to report.
- Q: Who runs it? → A: An operator, through a task, on a database connection the host
  configures for it. The application's own role keeps `INSERT, SELECT` and gains no `DELETE`.
- Q: Does a purge conflict with the constitution? → A: **Amend Principle II** (maintainer,
  2026-10-25; constitution 1.1.0, MINOR). Application code still has no update or delete API
  for entries. The one exception is an operator-run purge of a prefix ending at an anchored
  checkpoint, verified first, over a connection the application does not use, leaving a
  signed record; a removal without one is tampering.
- Q: Archive or delete? → A: **An archive is written by default** (maintainer, 2026-10-25).
  Deleting without one needs `NO_ARCHIVE=1`, for hosts that must not keep old entries; the
  retention record then says no archive was written.

### Amended during planning (2026-10-25)

Four changes made by `/speckit.plan`; see plan.md and research.md.

1. **A purge requires the whole ledger to verify INTACT**, not only the range it removes (R3).
   Same walk, from the current boundary; it refuses a purge while anything is broken.
2. **No configured archive directory.** Each run gives `ARCHIVE=path` or `NO_ARCHIVE=1`; one
   setting fewer, and the path an operator chose is the path in the output.
3. **Concurrent purges are serialized by the retention record's unique number**, not the head's
   lock (R5). A purge never holds the lock writers queue on.
4. **Checkpoints below the boundary are reported as `purged`**, not "not reached", and anchor
   nothing; the one at the boundary is checked against the retention record (R6).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Purge a year-old range, and the ledger still verifies (Priority: P1)

An operator keeps one year of audit history. Each month they run the retention task with
`OLDER_THAN=365d`. It verifies the range, archives it, removes it, and writes a retention
record. Verification afterwards is INTACT for what remains and names the purged range.

**Why this priority**: This is the feature: bounded storage without losing verifiability.

**Independent Test**: 10,000 entries, checkpoints every 1,000; purge through the checkpoint at
6,000. Verification: INTACT, covering 6,001 onward, purged range 1 to 6,000 named with its
retention record and checkpoint. The archive verifies on its own from 1 to 6,000.

**Acceptance Scenarios**:

1. **Given** a chain with a checkpoint at 6,000 in the anchor, **When** the operator runs the
   task with `THROUGH=6000` and the confirmation flag, **Then** entries 1 to 6,000 are removed,
   a retention record is written, and the task reports what it removed and where the archive is.
2. **Given** that purge, **When** verification runs, **Then** INTACT, covering 6,001 to the
   head, with the purged range and the retention record on the summary line; exit 0.
3. **Given** `OLDER_THAN=365d`, **Then** the boundary is the newest checkpoint whose entry is
   older than the cutoff, and the task names it before removing anything.
4. **Given** no confirmation flag, **Then** the task reports what it would remove and removes
   nothing (exit 0).
5. **Given** a second purge later, **Then** the boundary moves forward; the earlier retention
   record is kept, and verification lists both.

---

### User Story 2 - Tampering cannot pass as a purge (Priority: P1)

Someone with database access deletes old entries, or edits a retention record to cover more
than was purged, hoping it reads as retention. Verification reports BROKEN.

**Why this priority**: The second rule of the input. A retention feature that could launder
tampering would undo specs/002.

**Independent Test**: Each case below with raw SQL; each is BROKEN, and each pinned beside the
same removal done through the task, which is INTACT.

**Acceptance Scenarios**:

1. **Given** no retention record, **When** entries 1 to 6,000 are deleted by hand, **Then**
   BROKEN (missing), as in 0.7.0.
2. **Given** a purge through 6,000, **When** entries 6,001 to 6,100 are also deleted, **Then**
   BROKEN: they are above the boundary.
3. **When** the retention record's boundary is edited to 7,000, **Then** BROKEN: the record no
   longer matches its signature.
4. **When** the retention record is deleted, **Then** BROKEN: the purged range is missing with
   nothing accounting for it.
5. **When** a range with a digest mismatch is purged through the task, **Then** the task
   refuses before removing anything, naming the break.

---

### User Story 3 - The task refuses what it cannot prove (Priority: P1)

The operator asks for a purge the task cannot back: no anchor, a boundary that is not a
checkpoint, a checkpoint the anchor does not hold, a range that does not verify, or a key the
host lacks. The task refuses, says why, and removes nothing.

**Why this priority**: Refusal is what keeps rule 2 true in the hands of a hurried operator.

**Independent Test**: One refusal per condition, each exit 1, each leaving the ledger
byte-identical.

**Acceptance Scenarios**:

1. **Given** no anchor configured, **Then** REFUSED, naming `config.ledger_anchor`.
2. **Given** `THROUGH=` a sequence no checkpoint names, **Then** REFUSED, naming the nearest
   checkpoints below and above.
3. **Given** a range signed partly by a key not configured, **Then** REFUSED: it cannot be
   verified, so it cannot be purged.
4. **Given** an archive path that cannot be written, **Then** REFUSED before anything is removed.
5. **Given** no `ARCHIVE=` path and no configured archive directory, and no `NO_ARCHIVE=1`,
   **Then** REFUSED, naming both ways to proceed.

---

### User Story 4 - An archive verifies on its own (Priority: P2)

An auditor receives the archive of a purged year and checks it without the live database.

**Why this priority**: The archive is what keeps purged entries usable as evidence.

**Independent Test**: Purge with an archive; verify the archive alone with the keys: INTACT
from 1 to the boundary, ending at the boundary checkpoint's digest. Edit one line: BROKEN at it.

**Acceptance Scenarios**:

1. **Given** an archive and its boundary checkpoint, **When** verified, **Then** INTACT from the
   genesis to the boundary, the last digest matching the checkpoint's.
2. **When** a line is edited, removed, or reordered, **Then** BROKEN, naming the entry.

---

### Edge Cases

- **Purge while writes continue**: the boundary is below the head, so writes are unaffected;
  the purge never takes the head's lock. Two purges at once: the second fails to number its
  record and refuses (amendment 3).
- **Checkpoints below the boundary**: reported as purged, anchoring nothing; the one at the
  boundary is checked against the retention record (amendment 4).
- **A row edited while a purge runs**, inside the range it removes: kept in the archive as read
  (an edit before the archive was written shows in `verify_archive`), and deleted from the
  ledger either way; the remaining ledger is untouched.
- **A purge interrupted midway** (crash after some deletes): the retention record is written
  first, then rows are removed in batches; a re-run completes the removal. Verification of a
  half-finished purge reports the remaining rows below the boundary as "awaiting purge", not as
  broken.
- **Boundary inside an epoch**: the epoch's records stay; its entry count covers what remains.
- **An epoch wholly purged**: verification no longer needs its key for live entries; the
  report says so, so the operator can retire the key once archives no longer need it.
- **Restore of a pre-purge backup**: the restored ledger has entries a retention record says
  were removed: reported as "purged range present", not broken, and the next purge removes them.
- **Large purges**: removal in batches, never one transaction holding millions of rows.
- **No checkpoint older than the cutoff**: nothing to purge; exit 0 with a message.

## Requirements *(mandatory)*

### Functional Requirements

**Purging**

- **FR-001**: `bin/rails reeve:purge_ledger` (a task and a library call) removes chained
  entries 1 to S, where S is the sequence of a boundary checkpoint, plus pre-chain rows on the
  first purge (Clarifications).
- **FR-002**: The boundary is given by `THROUGH=` (a checkpoint's sequence) or `OLDER_THAN=`
  (the newest checkpoint whose entry occurred before the cutoff). Exactly one is required.
- **FR-003**: Without `CONFIRM=1`, the task reports what it would remove and removes nothing.
- **FR-004**: Before removing anything, the task requires: an anchor; the boundary checkpoint
  held by that anchor and checked against the ledger (specs/004 FR-011); and the ledger
  verifying INTACT against the anchor's checkpoints with keys this host holds (amendment 1). Any
  failure refuses with exit 1 and removes nothing.
- **FR-005**: The task writes a retention record, then removes the rows in batches. The record
  names the boundary checkpoint (sequence, digest), the previous boundary, the counts removed
  (chained, pre-chain), the archive's digest if one was written, the time, and the signing key's
  fingerprint, and is signed under the configured ledger key, chained to the previous retention
  record.
- **FR-006**: Removal uses a database connection the host configures for retention, never the
  application's own; the application's role needs no `DELETE` (constitution II, 1.1.0). With no
  retention connection configured the task refuses, naming the setting.
- **FR-007**: The task writes an archive by default, to `ARCHIVE=path` (amendment 2): one line per entry with every column, including the chain columns, plus a header
  naming the boundary checkpoint; its digest goes in the retention record. It is written and
  flushed before anything is removed. `NO_ARCHIVE=1` skips it, and the retention record and the
  task's output then say that no archive exists.

**Verification**

- **FR-008**: Verification reads the retention records; with one, it starts the walk at the
  latest boundary, linking to the boundary checkpoint's digest, exactly as specs/004 FR-015.
- **FR-009**: Retention records are checked like epoch records: signature under a held key
  (else unverifiable), chain from one to the next, boundaries non-decreasing, each boundary's
  digest matching the checkpoint it names when the anchor holds it.
- **FR-010**: Chained rows at or below the latest boundary are "awaiting purge" (a purge in
  progress, or a restore), reported and counted, not broken. A missing or broken retention
  record with no rows below its boundary is broken.
- **FR-011**: The summary line names the purged range and the latest retention record beside
  the coverage, so no line says "intact" without saying the range before it was purged.
- **FR-012**: `Reeve::Audit::Chain.verify_archive(path, keys:)` and `bin/rails
  reeve:verify_archive ARCHIVE=path` verify an archive alone: intact from the genesis (or the
  previous boundary) to the boundary checkpoint, against its digest.

**Docs, testing kit**

- **FR-013**: `LedgerChain` passes on a purged ledger that verifies, and reports the purged
  range in its message.
- **FR-014**: README and CHANGELOG document the procedure, the grants, the archive, and the
  limits in the guarantees section, in plain words.

### Key Entities

- **Retention record**: one per purge, signed and chained: boundary checkpoint, previous
  boundary, counts removed, archive digest, time, key fingerprint.
- **Archive**: the purged entries with all their columns, and the boundary they end at.
- **Boundary**: the checkpoint up to which entries were purged; the walk starts after it.

## Success Criteria *(mandatory)*

- **SC-001**: After any number of legitimate purges, verification is INTACT in 100% of tests
  on all three databases, including purges across rotations, with stragglers, and interrupted
  and resumed.
- **SC-002**: Every case in User Story 2 is BROKEN in 100% of tests, each beside its legitimate
  twin, which is INTACT.
- **SC-003**: Every refusal in User Story 3 leaves the ledger byte-identical.
- **SC-004**: Purging 1,000,000 entries completes without holding the chain's lock for longer
  than one chained write at a time, and verification after it walks only the remaining entries.
- **SC-005**: An operator can configure, dry-run, run and verify a purge from the README and
  CHANGELOG alone (checked by a cold read).
- **SC-006**: Full suite green on SQLite, and on PostgreSQL and MySQL where CI runs them.

## Assumptions

- The threat model is specs/002's and specs/004's: the attacker may write to the database, holds
  no key, and cannot change the anchor.
- One ledger per database, as before.
- An archive is stored by the host; reeve writes it to a path and verifies it, nothing more.
- Gem version and release are separate from this branch; the CHANGELOG entry is "Unreleased".

### Out of scope (future work)

- Purging by anything but a prefix (per tool, per principal, per tenant): a chain cannot lose a
  middle range and stay verifiable.
- Scheduling: the host schedules the task, as it schedules checkpoints.
- Legal holds and erasure requests for one principal's entries.
- Purging unchained contract-3+ rows.
