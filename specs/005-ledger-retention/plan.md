# Implementation Plan: Ledger Retention

**Branch**: `005-ledger-retention` | **Date**: 2026-10-25 | **Spec**: [spec.md](spec.md)

## Summary

Add `bin/rails reeve:purge_ledger`: verify the whole ledger INTACT against the anchor's
checkpoints, write an archive (default) of entries 1 to S where S is a checked checkpoint, insert
a signed and chained **retention record** in a new table `reeve_audit_retentions`, then delete
those entries in batches over a host-configured retention connection the application does not
use. Verification reads the retention records and starts its walk at the latest boundary, the
specs/004 walk-from-checkpoint with the record supplying the link. Add `reeve:verify_archive`.
No change to the entries table, so the audit-entry contract stays 4; one new table, one upgrade
step, one new setting.

## Technical Context

**Language/Version**: Ruby 3.0+, Rails 7.0+ (unchanged)
**Primary Dependencies**: ActiveRecord; OpenSSL HMAC-SHA256 and SHA-256; stdlib JSON (unchanged)
**Storage**: SQLite, PostgreSQL, MySQL. New table `reeve_audit_retentions`; entries table unchanged.
**Testing**: RSpec; `DB=` selects the engine
**Project Type**: Library (gem)
**Performance Goals**: the purge never holds the chain record's lock; deletes in batches of
1,000; verification after a purge walks only what remains (SC-004)
**Constraints**: the application's role gains no `DELETE`; nothing removed before the archive is
flushed and the retention record committed; no key value in a record, archive or output
**Scale/Scope**: retention records are few (one per purge); purged ranges can be millions of rows

## Constitution Check

| Principle | Check | Result |
|---|---|---|
| I. Deny by Default | No authorization path touched. | Pass |
| II. Every Call Leaves a Trace (1.1.0) | Removal only through the operator-run purge, of a prefix ending at a checkpoint the anchor holds, after an INTACT verification, over `config.ledger_retention_connection` (refused when it is the application's own), after a signed record is committed. Any other removal stays BROKEN (spec US2). Application code gains no delete API. | Pass |
| III. Provable by Test | Every tamper case in US2 pinned beside its legitimate twin; every refusal in US3 pinned byte-identical; hosts assert a purged ledger through the existing `LedgerChain`. | Pass |
| IV. Extension Layer | No MCP-server code touched; storage of archives is the host's (a path). | Pass |
| V. Clean-Room | Prior art is public (CloudTrail log retention with digest files, PostgreSQL partition detach patterns, WORM retention docs). | Pass |
| VI. Boring DX | One setting (`ledger_retention_connection`), needed by the principle itself. Two tasks. No archive-directory setting: `ARCHIVE=path` or `NO_ARCHIVE=1` on each run (spec amendment 2). | Pass |
| Cost discipline | No multi-agent workflow. | Pass |

Post-design re-check: unchanged.

## Design

### The retention record (`reeve_audit_retentions`)

One row per purge, numbered from 0 and unique on `purge`. Signed under the configured ledger key,
tagged `reeve-ledger-retention-v1`, over the canonical form of its fields plus the previous
record's digest (the genesis digest for record 0): a chain of its own, like the epochs
(data-model.md). Written through the retention connection; the unique number serializes two
purges at once (spec amendment 3), so the purge never takes the head's lock.

### Purging (`Chain.purge!`, `Retention::Purge`)

1. **Refuse** (`PurgeResult` refused, nothing written) when: no ledger key; no anchor; no
   `ledger_retention_connection`, or one whose database differs from the ledger's, or one that
   is the application's own connection on an engine with roles (same username); neither or both
   of `THROUGH=` / `OLDER_THAN=`; no archive path and no `NO_ARCHIVE=1`; the archive path exists
   or its directory is not writable.
2. **Boundary.** Read the anchor's checkpoints; `THROUGH=S` needs one at S; `OLDER_THAN=Nd`
   takes the highest checkpoint whose entry's `occurred_at` is before now − N days. A boundary
   at or below the current one refuses (`:nothing_to_purge`, exit 0).
3. **Verify.** `Chain.verify` with the anchor's checkpoints must be INTACT, and the boundary
   checkpoint's result `checked` (spec amendment 1). This walks from the current boundary, so a
   second purge does not re-walk what the first removed.
4. **Dry run** without `CONFIRM=1`: report boundary, counts, archive path; exit 0.
5. **Archive** (unless `NO_ARCHIVE=1`): stream the header and every row from the current boundary
   to S, plus pre-chain rows still present, to `path.tmp`, `fsync`, rename to `path`, SHA-256 it.
6. **Record.** Insert the retention record (counts, archive digest or null, boundary checkpoint
   sequence and digest, previous boundary, time, key fingerprint, digest). Commit.
7. **Delete** in batches of 1,000 ids, `chain_sequence <= S` and, on any purge, `contract_version < 3`,
   each batch its own transaction on the retention connection. A crash leaves rows "awaiting
   purge"; rerunning with the same boundary skips steps 3–6 (the record exists) and finishes 7.

### Verifying a purged ledger

`Retention::Records.read` (one query; none when the table is absent) and `RetentionCheck`
(signature under a held key, else `unknown_key`; chain to the previous record; boundaries
non-decreasing; record 0 links to the genesis). The latest record that verifies sets the walk's
start, exactly as `from:` does (specs/004): `Anchoring#start` and `#link` take the boundary when
there is one and no `from:` is given, or when `from:` is lower. Then:

- chained rows at or below the boundary are counted as `awaiting_purge`, never walked;
- checkpoints at or below the boundary: the one at the boundary is checked against the record's
  digest (`checkpoint_mismatch` if different); lower ones get status `purged` and anchor nothing
  (spec amendment 4); their genesis is still checked;
- a record that fails is `retention_altered` (BROKEN); the walk then starts at the last record
  that verified, so a gap it leaves is reported as `missing`, as in 0.7.0;
- `uncovered_now` subtracts nothing: the report states pre-chain rows purged beside the genesis
  count.

`Verification` gains `retention` (`{ through, records: [...] }`) and `awaiting_purge`. Every
summary line that follows a walk carries the purge clause (`; 1–6,000 purged (retention 0,
2026-10-25)`) beside the coverage (FR-011).

### Archive (`Retention::Archive`)

JSON lines: a header (format, from/through sequences, the boundary checkpoint line, the start
link: genesis record fields and digest for the first purge, else the previous boundary's
checkpoint line), then one object per row with every column, times as ISO 8601 microseconds.
`Chain.verify_archive(path, keys:)`: verifies the checkpoint lines' signatures, rebuilds each row
as an unsaved `Entry` (so casts match the database's), and walks it with `Walk`'s digest rule from
the start link to the boundary digest. Pre-chain rows are counted, not verified.

### Tasks

- `bin/rails reeve:purge_ledger THROUGH=|OLDER_THAN= [CONFIRM=1] ARCHIVE=path|NO_ARCHIVE=1`:
  exit 0 for a dry run, purged, or nothing to purge; 1 refused.
- `bin/rails reeve:verify_archive ARCHIVE=path`: exit codes as `verify_ledger`.

### Canonical form

`RETENTION_TAG = "reeve-ledger-retention-v1"`, `RETENTION_FIELDS = %w[purge through_sequence
through_digest previous_through removed_chained removed_pre_chain archived archive_sha256
purged_at key_id]` plus `previous_digest`.

## Project Structure

### Documentation (this feature)

```text
specs/005-ledger-retention/
├── spec.md, plan.md, research.md, data-model.md, quickstart.md
├── contracts/retention.md      # setting, tasks, library API, verification additions, output
├── contracts/archive-v1.md     # the archive file
└── checklists/requirements.md
```

### Source Code

```text
lib/reeve/audit/retention_record.rb            NEW: read-only model for verification
lib/reeve/audit/chain/retention/purge.rb       NEW: steps 1–7; PurgeResult
lib/reeve/audit/chain/retention/records.rb     NEW: read, latest valid boundary
lib/reeve/audit/chain/retention/check.rb       NEW: RetentionCheck
lib/reeve/audit/chain/retention/archive.rb     NEW: write, verify
lib/reeve/audit/chain/canonical.rb             retention tag, fields, digest
lib/reeve/audit/chain/anchoring.rb             start/link from the boundary
lib/reeve/audit/chain/checkpoint_check.rb      purged status, boundary check
lib/reeve/audit/chain/verifier.rb              read records, awaiting_purge
lib/reeve/audit/chain/verification.rb          kinds, retention, JSON
lib/reeve/audit/chain/report.rb                purge clause
lib/reeve/audit/chain.rb                       purge!, verify_archive
lib/reeve/configuration.rb                     ledger_retention_connection
lib/reeve/tasks.rb                             purge_ledger, verify_archive
lib/generators/reeve/install/templates/…       retentions table; grants comment
lib/generators/reeve/upgrade/…                 retention step + template
README.md, CHANGELOG.md
spec/reeve/audit/chain/retention_spec.rb, purge_spec.rb, archive_spec.rb (NEW) + touched specs
```

## Delivery Order

1. Schema: install template, upgrade step, model, setting, connection guard. Failing specs first.
2. Retention record: canonical form, write, read, `RetentionCheck`.
3. Purge (US1, US3): refusals first (byte-identical ledger), then dry run, then archive, record, delete.
4. Verification of a purged ledger (US1, US2): tamper specs beside legitimate twins.
5. Archive verification (US4).
6. Reporting, tasks, docs, benchmark (SC-004), cold read (SC-005).

## Risks

- **A false BROKEN after a legitimate purge** is the worst failure here. The verifier brief must
  try: interrupted purges, two purges, purges across rotations, a purge with stragglers, a
  checkpoint exactly at and below the boundary, a pre-chain ledger.
- **An edit racing the purge**, to a row in the purged range after the verification (step 3):
  before the archive reads it (step 5), the archived copy holds the edit and `verify_archive`
  reports it; after, the archive holds the row as verified and the edited row is deleted. Either
  way the remaining ledger is untouched and no edit becomes part of what verifies INTACT. With
  `NO_ARCHIVE=1` the edited row is simply deleted, which is what the purge was removing anyway.
  Stated in the guarantees, not locked against: the rows are ones nothing updates legitimately.
- **Same-username detection** is a heuristic: two roles with one username cannot exist, but one
  role reached through two configs can. SQLite has no roles; the task warns there and proceeds.
- **The Entry rebuild in archive verification** must cast exactly as the database did; the
  restore spec's lessons (specs/002) apply. Covered by an archive round-trip spec on all engines.

## Complexity Tracking

| Addition | Why needed | Simpler alternative rejected because |
|---|---|---|
| New table | A purge must leave a record verification can find and no one without a key can forge | Columns on the chain record keep only the latest purge; history is evidence |
| Setting `ledger_retention_connection` | Constitution II (1.1.0) requires a connection the application does not use | Env var credentials would put a database password in a task invocation |
| Archive format | Purged entries must stay verifiable outside the ledger (spec US4) | Host-side dumps lose the chain columns' meaning and cannot be checked by reeve |
