# Feature Specification: Ledger Key Epochs

**Feature Branch**: `003-ledger-key-epochs`
**Created**: 2026-10-23
**Status**: Frozen (2026-10-23) — ground truth for build and verification
**Input**: "Complete key-rotation support for the tamper-evident audit ledger. Spec 002 settled
key rotation as 'addressed minimally' — this task addresses it fully. Rotating
`config.ledger_key` today breaks chain verification for all prior entries. We need key epochs
(entries know which key version chained them), verification that spans rotations cleanly, a
supported rotation procedure, and upgrade notes. Honor the audit-entry contract's own
versioning rule when deciding whether the contract number bumps."

## Overview

Spec 002 gave every chained entry the fingerprint of the key that signed it
(`chain_key_id`) and let verification hold any number of retired keys. That made rotation
*possible*: keep the old key as a retired key and old entries still verify. What it did not
give, and what this feature adds:

1. **A record of the rotation itself.** Nothing in the ledger says which keys have signed it,
   from where, in what order. So a row whose `chain_key_id` was rewritten to a fingerprint no
   configured key has reads as "signed by a key you don't have" (unverifiable, exit 2) rather
   than as tampering (specs/002 verification.md, "A rewritten key id reads as unverifiable").
   Telling those apart needs exactly this record.
2. **Entries that name their epoch.** Each entry written from now on carries the number of
   the key epoch that chained it, inside its digest, so a deleted or edited epoch record is
   visible from the entries that point at it.
3. **A supported procedure.** Today rotation is two lines in the README with an ordering trap
   (`ledger_key` must be assigned before `retired_ledger_keys`). There is no task that
   performs or checks a rotation, and nothing tells an operator, before it is too late, that
   the outgoing key is no longer configured.
4. **Verification that reports per epoch.** Which epochs verified, which could not be checked
   because their key is not configured here, and over which sequences.

The premise "rotating breaks verification for all prior entries" is accurate in its effect
for an operator who replaces the key without keeping the old one: every earlier entry becomes
unverifiable (never "tampered", never "intact"). This feature does not make an entry
verifiable without its key — no design can — but it makes the loss visible at rotation time
and closes the rewritten-key-id gap.

### What this feature guarantees, and what it does not

Normative, like specs/002's equivalent section, which still holds in full. Documentation,
CHANGELOG and output MUST NOT claim more.

**Added detection**, provided the attacker holds no ledger key:

- an epoch-bearing entry whose key id was changed to a key other than its epoch's key —
  reported as tampering (broken), where 0.6.0 reported it as unverifiable;
- an epoch-bearing entry whose epoch number was changed, or that names an epoch with no
  record;
- an epoch record that was edited, deleted, renumbered or inserted;
- an entry that names an epoch whose recorded start is after the entry's position.

**Not detected / not changed — stated plainly:**

1. **Entries chained before the first epoch** (written by 0.6.0, or by contract-3 code during a
   rolling deploy *before* the first epoch opened) keep 0.6.0 semantics exactly: a key the
   verifier lacks makes them unverifiable, and a rewritten key id on them is still
   indistinguishable from a missing key.
2. **A key the verifier does not hold.** An entry signed by it cannot be checked. Epochs make
   that loss visible and attributed to a named epoch; they do not undo it. Re-signing history
   under a new key remains out of scope (specs/002 FR-016).
3. **Pointing an entry at another epoch whose key the verifier also lacks.** Such an entry
   stays unverifiable rather than broken. Only possible where verification already cannot
   pass.
4. **Key compromise, tail truncation with a rewound head, deletion of the whole ledger** —
   unchanged from specs/002 items 1–3. A compromised retired key can recompute its epoch's
   rows exactly as a compromised current key could before.
5. **Deletion of every epoch record *together with* rewriting every epoch-bearing entry** back
   to a contract-3 shape under a key id nobody holds: verification ends at unverifiable, never
   intact — the 0.6.0 floor.

## Clarifications

### Session 2026-10-23

Decisions taken while writing this specification (the `/speckit.clarify` pass was answered
in-session, not by the maintainer; each is recorded so it can be overruled before review):

- Q: Does the audit-entry contract number bump? → A: **Yes, 3 → 4, MAJOR.** The contract's
  rule (specs/001 contracts/audit-entry.md: "Adding a nullable column is a MINOR change.
  Removing a column, renaming one, or changing the meaning of a value is MAJOR") read
  literally would make a nullable `chain_epoch` column MINOR. It is MAJOR for the same two
  reasons contract 3 was, and the precedent is recorded in that document's own history:
  (a) what an absence means changes — on a contract-3 row a NULL epoch means "written before
  key epochs existed", on a contract-4 chained row it cannot occur; (b) the meaning of an
  existing value changes — `chain_digest` on a contract-4 row covers the epoch number, so the
  canonical field list for contract 4 differs from contract 3's, and a consumer recomputing
  digests from the contract-3 list would get mismatches. Reason (b) alone forces the bump in
  code: the canonical field list is keyed by contract version. This feature also amends the
  rule's wording so the exception is written down rather than living only in precedent
  (FR-020).
- Q: Do entries need a new column, given `chain_key_id` already names the key? → A: Yes. A
  registry of epochs held only in its own table could be deleted wholesale and verification
  would silently fall back to 0.6.0 semantics. An epoch number inside each entry's digest is
  what makes the registry's deletion visible. It also gives "entries know which key version
  chained them" a literal, queryable answer (`where(chain_epoch: 2)`).
- Q: When does a new epoch begin — at a rotation command, or at the first write signed with a
  new key? → A: **At the first write with a key that has never opened an epoch, or earlier, by
  the rotation task.** Requiring the task before any write could use a new key would turn a
  routine `secret_key_base` rotation (the default initializer derives the ledger key from it)
  into every guarded call failing. The task exists to perform the rotation deliberately and to
  check it, not as a gate writes wait behind.
- Q: During a rolling deploy, servers with the old key keep writing after a server with the
  new key opened the next epoch. Is that tampering? → A: **No.** A process signs under the
  epoch its configured key opened; if that is an earlier epoch, the entry is a *straggler*:
  legitimate, verified by its own key, and counted. A key opens at most one epoch; a key that
  already opened one never opens another.
- Q: What does the rotation task refuse? → A: Opening an epoch while the outgoing epoch's key
  is not configured on this host (its entries would become unverifiable here) unless the
  operator states `ACCEPT_UNVERIFIABLE=1` — the lost-key case; and making a key current that
  already opened an earlier epoch.
- Q: Are 0.6.0-era rotations (several key ids before the first epoch) adopted into the
  registry? → A: No. Those entries keep 0.6.0 semantics (guarantee item 1). Adoption would mean
  vouching, after the fact, for which key signed what — the registry would be recording
  something nobody observed.
- Q: A generator as well as a rake task? → A: Rake task only. The existing upgrade generator
  gains the contract-4 step (that *is* the generator side). A rotation generator would have
  nothing to generate: keys live in the host's credentials, not in files reeve writes.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Rotate the key and keep the whole ledger verifiable (Priority: P1)

An operator replaces the ledger key (scheduled rotation, a departing administrator, a
`secret_key_base` rotation). They configure the new key, keep the old one as retired, deploy,
and run the rotation task. Every entry before and after verifies, and verification reports two
epochs with the sequences each covers.

**Why this priority**: This is the feature. Without it, rotation is a README footnote with a trap.

**Independent Test**: Write entries, rotate, write more, verify: intact, two epochs listed,
every entry covered.

**Acceptance Scenarios**:

1. **Given** a chained ledger whose entries carry epoch 0, **When** the operator sets
   `ledger_key` to a new key and `retired_ledger_keys` to the old one and runs
   `bin/rails reeve:rotate_ledger_key`, **Then** the task reports ROTATED, names epoch 1, its
   key fingerprint and its first sequence, and exits 0.
2. **Given** that rotation, **When** more entries are written, **Then** they carry epoch 1 and
   the new key's fingerprint, and `reeve:verify_ledger` reports INTACT over every sequence and
   lists epoch 0 and epoch 1 as verified.
3. **Given** the new key configured but the task never run, **When** an entry is written,
   **Then** that write opens epoch 1 itself, and the task run afterwards reports CURRENT.
4. **Given** the rotation task run twice in a row, **Then** the second reports CURRENT and
   changes nothing.

---

### User Story 2 - A rewritten key id is reported as tampering (Priority: P1)

A reviewer runs verification on a ledger in which someone with database access changed an
entry's `chain_key_id` (or its `chain_epoch`). The report says BROKEN and names the entry —
not "signed by a key you don't have".

**Why this priority**: The rewritten-key-id gap is the one known hole in 0.6.0's tamper
evidence; closing it is the security payoff of recording epochs.

**Independent Test**: Chain entries across a rotation; rewrite one entry's key id to a random
fingerprint; verify reports broken with an `epoch_mismatch` at that sequence.

**Acceptance Scenarios**:

1. **Given** an epoch-bearing entry, **When** its `chain_key_id` is changed to a fingerprint no
   epoch has, **Then** verification is BROKEN with `epoch_mismatch` at its sequence.
2. **When** its `chain_key_id` is changed to another epoch's key, **Then** BROKEN: the digest no
   longer verifies under that key (`digest_mismatch`) or, if that key is not configured, the
   key is not its epoch's key (`epoch_mismatch`).
3. **When** its `chain_epoch` is changed to an epoch with no record, **Then** BROKEN with
   `epoch_missing`.
4. **When** an epoch record is deleted, edited, or its number or start changed, **Then**
   BROKEN, with `epoch_missing` for entries pointing at a vanished epoch and `epoch_altered`
   for a record that no longer matches its digest or its place in the sequence of epochs.

---

### User Story 3 - The rotation task stops the operator before they lose verifiability (Priority: P1)

An operator configures a new key but forgets to keep the old one. The rotation task refuses,
says that epoch N's entries would become unverifiable on this host, and names the fix.

**Why this priority**: Losing the outgoing key is the failure 0.6.0 made easy and silent.

**Acceptance Scenarios**:

1. **Given** `ledger_key` set to a new key and the current epoch's key not configured, **When**
   the task runs, **Then** it reports REFUSED, names the epoch and the missing key's
   fingerprint, writes nothing, and exits 1.
2. **Given** the same, with `ACCEPT_UNVERIFIABLE=1`, **Then** it opens the epoch and says the
   earlier epoch is unverifiable on this host.
3. **Given** `ledger_key` set to a key that opened an earlier epoch, **Then** REFUSED (a key
   opens one epoch only), exit 1, nothing written.
4. **Given** no `ledger_key`, **Then** REFUSED naming the setting, exit 1.

---

### User Story 4 - Rolling deploys and missing keys are not reported as tampering (Priority: P2)

During the deploy that rotates the key, servers still on the old key keep writing. Afterwards
verification is INTACT; the stragglers are counted under the epoch that signed them. An
auditor who holds only the newest key gets UNVERIFIABLE naming the epoch whose key they lack,
not BROKEN.

**Acceptance Scenarios**:

1. **Given** epoch 1 open, **When** a process configured with epoch 0's key writes, **Then** its
   entry carries epoch 0, verifies, and the run is INTACT.
2. **Given** a verifier holding only epoch 1's key, **Then** status UNVERIFIABLE, epoch 0 listed
   as "key not configured", epoch-0 entries counted as unverifiable, never as breaks.
3. **Given** a 0.6.0 server still writing contract-3 rows after epoch 0 opened, **Then** those
   rows verify under 0.6.0 rules plus the epoch rules for rows without an epoch (FR-011).

---

### User Story 5 - Upgrade an existing 0.6.0 ledger (Priority: P2)

A host on contract 3 runs `bin/rails generate reeve:upgrade && bin/rails db:migrate`. Nothing
already written is touched. The first entry written afterwards opens epoch 0 with the
configured key. Verification is INTACT and reports the pre-epoch range separately.

**Acceptance Scenarios**:

1. **Given** a contract-3 table, **When** the upgrade generator runs, **Then** it emits exactly
   one migration (the contract-4 step), and running it again emits nothing.
2. **Given** an upgraded and a freshly installed table, **Then** their shapes are identical.
3. **Given** the upgraded ledger with 0.6.0 entries, **When** a new entry is written, **Then**
   epoch 0 opens at that entry's sequence and verification lists the earlier entries as
   "before the first epoch".
4. **Given** a table at contract 3 and the gem at contract 4, **When** a chained write is
   attempted, **Then** it fails with a `ConfigurationError` naming the upgrade command (as
   0.6.0 does for a contract-2 table).

### Edge Cases

- **No `ledger_key` configured**: writes behave as in 0.6.0 (`LedgerKeyError`, or an unchained
  row under `:warn`); no epoch is opened.
- **Rotation task on a ledger with no chain yet**: starts the chain and opens epoch 0 with the
  configured key; reports ROTATED (epoch 0).
- **Rotation task when the configured key opened the current epoch**: CURRENT, exit 0. If the
  previous epoch's key is not configured here, the output says so on a warning line (exit
  stays 0: nothing was refused, and verification will report it).
- **Two processes with the same new key write at once**: one opens the epoch; the other signs
  under it. Never two epochs for one key.
- **The rotation task and a write race**: serialized on the chain record's lock; the epoch's
  first sequence is exact either way.
- **An epoch opened by the task with no entries yet**: listed with no sequences; not a break.
- **Configuration rolled back to an earlier epoch's key**: writes continue as stragglers under
  that epoch; verification is INTACT; the rotation task, if run, reports REFUSED (key already
  used) so the operator learns the configuration is stale.
- **Many epochs**: verification reads every epoch record once; no per-entry query.
- **Unchained contract-4 rows** (`:warn`, no key): NULL epoch, as unchained as any other
  unchained row; reported exactly as in 0.6.0.

## Requirements *(mandatory)*

### Functional Requirements

**Epochs**

- **FR-001**: A key epoch is the stretch of the chain a single key began signing at a known
  position. Epochs are numbered from 0 with no gaps. Each is recorded once, in a new table
  `reeve_audit_chain_epochs`, with: `epoch` (integer, unique), `key_id` (the key's 16-hex
  fingerprint, unique — a key opens at most one epoch), `first_sequence` (the first chain
  sequence the epoch can cover), `opened_at` (microsecond time), and `epoch_digest`.
- **FR-002**: `epoch_digest` is an HMAC-SHA256 under the epoch's own key over a canonical form
  tagged distinctly from entry and genesis digests, covering `epoch`, `key_id`,
  `first_sequence`, `opened_at`, and the previous epoch's digest (the genesis digest for
  epoch 0). Epoch records are therefore a chain of their own, anchored to the genesis.
- **FR-003**: Every chained entry written at contract 4 records `chain_epoch`, the number of the
  epoch whose key signed it, and `chain_epoch` is part of the contract-4 canonical field list,
  so it is covered by `chain_digest`.
- **FR-004**: A chained write signs with the configured `ledger_key` (as in 0.6.0). Under the
  chain record's lock it finds the epoch that key opened; if there is none, it opens the next
  epoch (`max + 1`, or 0) with that key, `first_sequence` = the entry's own sequence. The
  epoch record and the entry commit or roll back together.
- **FR-005**: An entry signed by a key whose epoch is not the latest is a straggler; it is
  written normally with that earlier epoch's number. No write ever fails because another epoch
  is current.

**Rotation task**

- **FR-006**: `bin/rails reeve:rotate_ledger_key`, backed by `Reeve::Tasks.rotate_ledger_key(env:,
  out:)` and the library call `Reeve::Audit::Chain.rotate_key!(accept_unverifiable: false)`,
  makes the configured `ledger_key` the key of the latest epoch. Outcomes:
  - **ROTATED** (exit 0): opened epoch N with the configured key, `first_sequence` = head + 1,
    starting the chain first if it has not started. Output names the new epoch, its key
    fingerprint, its first sequence, and the previous epoch with its key fingerprint.
  - **CURRENT** (exit 0): the configured key opened the latest epoch already; nothing written.
    If the previous epoch's key is not configured, a warning line says so.
  - **REFUSED** (exit 1), nothing written, the reason and the fix named: no `ledger_key`; the
    configured key opened an earlier epoch; the latest epoch's key is not configured on this
    host and `ACCEPT_UNVERIFIABLE=1` was not given.
- **FR-007**: The task never prints or logs a key, only fingerprints.
- **FR-008**: The task takes the chain record's lock without consuming a sequence, so a
  rotation racing with writes leaves no gap and an exact `first_sequence`.
- **FR-009**: The task's result is available as a value (`Reeve::Audit::Chain::Rotation`: status,
  epoch, key_id, first_sequence, previous_epoch, previous_key_id, reason, warnings) so a deploy
  script can use it without parsing text.

**Verification**

- **FR-010**: Verification reads every epoch record and checks: numbering 0..n without gaps
  (else `epoch_missing`); `first_sequence` strictly increasing with epoch number, and no later
  than one past the head (else `epoch_altered`); key ids distinct (else `epoch_altered`); each
  record's digest under its key when that key is configured (else `epoch_altered`; if the key is
  not configured, the epoch is reported unverifiable, not broken).
- **FR-011**: For each chained entry:
  - with a `chain_epoch` (contract ≥ 4): the epoch must have a record (else `epoch_missing`);
    the entry's key id must be that epoch's key (else `epoch_mismatch`); its sequence must not
    precede the epoch's `first_sequence` (else `epoch_mismatch`); then its digest is checked as
    in 0.6.0.
  - without one (contract 3) positioned at or after epoch 0's `first_sequence`: if its key is
    configured, its digest is checked as in 0.6.0; if not, its key id must be one some epoch
    opened at or before its position (else `epoch_mismatch`), and the entry is unverifiable.
  - without one positioned before epoch 0 (or with no epochs at all): exactly 0.6.0.
- **FR-012**: `epoch_missing`, `epoch_mismatch` and `epoch_altered` are breaks: status BROKEN,
  exit 1. A configured-key absence remains `unknown_key`: UNVERIFIABLE, exit 2.
- **FR-013**: The result lists the epochs: for each, its number, key fingerprint,
  `first_sequence`, how many walked entries named it, and one of `verified` (record and all its
  entries checked), `key_not_configured`, or `altered`. JSON gains an `epochs` array with those
  fields and `before_first_epoch` (the count of chained entries positioned before epoch 0).
  The text report lists one line per epoch after the summary (and totals) whenever there are
  two or more epochs, any epoch is not `verified`, or chained rows precede the first epoch
  (then a "before epoch 0" line comes first, with their count); a ledger with a single
  verified epoch and nothing before it prints exactly what 0.6.0 printed. *(Amended during
  planning: a lone verified epoch line tells the reader nothing the summary does not.
  Amended again during build, re-frozen 2026-10-23: the planning wording dropped the
  pre-epoch rows US5 scenario 3 requires the report to show.)* The summary line's format and
  every existing JSON field are unchanged; breaks gain an `epoch` field.
- **FR-014**: Verification reads the epochs with one query and keeps the walk's per-batch query
  count unchanged.

**Contract, schema, upgrade**

- **FR-015**: The audit-entry contract becomes 4. New nullable column `chain_epoch` (integer) on
  `reeve_audit_entries`; new table `reeve_audit_chain_epochs` (FR-001). Nothing already written
  is changed.
- **FR-016**: `bin/rails generate reeve:upgrade` gains one step (contract 4) that adds the column
  and creates the table, emitted only when missing, and an upgraded table matches a fresh
  install.
- **FR-017**: `bin/rails generate reeve:install` creates the contract-4 shape directly.
- **FR-018**: A chained write against a table missing `chain_epoch` or the epochs table raises
  `ConfigurationError` naming `bin/rails generate reeve:upgrade`.
- **FR-019**: `Reeve::Checks::ContractVersion` expects 4 and the new column.
- **FR-020**: The audit-entry contract document records contract 4 in its history with the
  rationale above, and its versioning rule states the exception explicitly: an added nullable
  column is MAJOR when what an absence means, or what an existing value covers, changes.

**Documentation**

- **FR-021**: CHANGELOG carries an unreleased entry with upgrade notes that a stranger can act
  on alone: the contract bump and migration, the rotation procedure step by step, the behavior
  changes (rows name their epoch; writes open epochs; the task), what is and is not newly
  detected (the guarantee section, not more), and how 0.6.0-era rotations are treated.
- **FR-022**: README's tamper-evidence section documents rotation through the task; its rotation
  example still runs (`spec/readme_spec.rb`).

### Key Entities

- **Key epoch**: number, key fingerprint, first sequence, opened-at, digest. Recorded once;
  never updated by reeve.
- **Chained entry (contract 4)**: everything contract 3 has, plus `chain_epoch`.
- **Rotation**: the value FR-009 describes.

## Success Criteria *(mandatory)*

- **SC-001**: A ledger rotated any number of times, with every epoch's key configured, verifies
  INTACT across every sequence, stragglers included.
- **SC-002**: Every tampering case in User Story 2 is reported BROKEN; none UNVERIFIABLE or
  INTACT.
- **SC-003**: No legitimate sequence of operations in User Stories 1, 4 and 5 (rotation, rolling
  deploy, task re-runs, upgrade) produces a BROKEN report.
- **SC-004**: Write overhead stays within specs/002's measured budget plus one indexed point
  read per chained write.
- **SC-005**: An operator can perform a rotation from the CHANGELOG upgrade notes alone (checked
  by a cold read: correct commands, in the correct order, with the old key retained).
- **SC-006**: Full suite green on SQLite, and on PostgreSQL and MySQL where CI runs them.

## Assumptions

- One ledger per database, as in specs/002 (`ChainRecord::LEDGER`). The epochs table carries no
  ledger name.
- Gem version and release are separate from this branch; the CHANGELOG entry is "Unreleased".
- The threat model is specs/002's: the attacker may write to the database but holds no key.

### Out of scope (future work)

- Adopting 0.6.0-era key changes into the registry.
- External anchoring of epoch records or the head (specs/002 future work).
- Asymmetric signatures; forward-secure key evolution.
- Re-signing history under a new key.
