# Implementation Plan: Ledger Anchoring

**Branch**: `004-ledger-anchoring` | **Date**: 2026-10-25 | **Spec**: [spec.md](spec.md)

## Summary

Add a **checkpoint**: one signed JSON line naming the genesis digest, the head (sequence and
digest) and the latest key epoch (number and digest), made by `bin/rails reeve:checkpoint_ledger`
under the chain record's lock and handed to a host-supplied **anchor** (`config.ledger_anchor`;
reeve ships `Reeve::Audit::FileAnchor`, append-only). Verification reads checkpoints from the
anchor or the caller, never the database, and checks each one against the ledger: three new
break kinds, a per-checkpoint result, and an anchoring statement on every summary line.
Verification can also start from a checkpoint. No schema change, no contract bump, no change to
the write path.

## Technical Context

**Language/Version**: Ruby 3.0+, Rails 7.0+ (unchanged)
**Primary Dependencies**: ActiveRecord; OpenSSL HMAC-SHA256; stdlib JSON (unchanged)
**Storage**: SQLite, PostgreSQL, MySQL via ActiveRecord (the specs/002 support matrix); no new
table or column. Checkpoints live in the host's store.
**Testing**: RSpec; `DB=` selects the engine (spec/support/optional/database.rb)
**Project Type**: Library (gem)
**Performance Goals**: write cost unchanged (SC-004); a checkpoint is O(1) in ledger size, under
1 s on 1,000,000 entries; checking checkpoints costs one query per 1,000 checkpoints
**Constraints**: no key value or entry content in a checkpoint; no ledger write waits on the
anchor; verification never takes checkpoints from the database; nothing depends on a
checkpoint's clock
**Scale/Scope**: hourly checkpoints are ~9,000 a year; they are parsed whole, entries are
walked in batches as today

## Constitution Check

| Principle | Check | Result |
|---|---|---|
| I. Deny by Default | No authorization path touched. | Pass |
| II. Every Call Leaves a Trace | The write path is not touched; a failing anchor can fail only the checkpoint task (FR-009). | Pass |
| III. Provable by Test | Each detection case ships with a failing-first spec beside one pinning the old limit (SC-001). Hosts assert anchoring through `LedgerChain anchored: true`, which proves their anchor round-trips (research R8). | Pass |
| IV. Extension Layer | No MCP-server code touched. Storage is the host's: reeve ships a file anchor and a two-method protocol, no service SDK (spec Clarifications, maintainer 2026-10-25). Positioning: no Ruby audit gem anchors a keyed chain (research R9). | Pass |
| V. Clean-Room | Prior art consulted is public (Certificate Transparency, C2SP tlog-checkpoint, CloudTrail digest files, S3 Object Lock docs); no names or shapes copied. | Pass |
| VI. Boring DX | One new setting (`ledger_anchor`), needed because the rotation task and verification must find checkpoints without being told each time. One new task. Two optional env vars on `verify_ledger` (`CHECKPOINTS=`, `FROM=latest`). Nothing changes for a host that sets no anchor except the words "not anchored" on the summary line. | Pass |
| Cost discipline | No multi-agent workflow; the code was read directly. | Pass |

Post-design re-check: unchanged.

## Design

### Making a checkpoint (`Chain.checkpoint!`)

1. Refuse with no `ledger_key` (`CheckpointResult` refused, `:no_key`), and with no chain or
   head 0 (`:no_chain`): there is nothing to pin. A refusal writes and publishes nothing.
2. In a transaction on the ledger's connection: `head.lock!` (specs/003's no-consume lock), then
   read `genesis_digest`, the pre-chain counts, `head_sequence`, `head_digest`, and the latest
   epoch (`epoch`, `epoch_digest`) through `Head.current`. The lock is what makes the head and
   the epoch one committed state: a write opens its epoch and moves the head in one transaction
   behind the same lock (research R2). Held for two reads, shorter than a chained write.
3. Build the `Checkpoint`, sign it (`Canonical.checkpoint_signature`), commit, then hand its line
   to the anchor if one is configured. Publishing happens after the lock is released, so a slow
   store never holds writers.

### Verifying with checkpoints

`Chain.verify(checkpoints: nil, from: nil)`: `nil` means "the configured anchor's, or none";
an Array of lines or `Checkpoint`s is used as given (`[]` turns anchoring off). `Verifier`:

1. Parses every checkpoint first. A line that does not parse, or names an unknown format
   version, raises `CheckpointError` naming its position: never skipped, never passed. The task
   turns that into exit 2.
2. With no chain and at least one checkpoint, the answer is BROKEN (FR-013): each checkpoint is
   `checkpoint_not_reached`, "the ledger has no chain". With no checkpoints, NO CHAIN as today.
3. Walks as today, or from a checkpoint (below).
4. `CheckpointCheck` (new) checks each checkpoint after the walk, against the chain record, the
   epoch records `EpochRules` already loaded, and the entries at the checkpoints' sequences
   (`where(chain_sequence: [...]).pluck(:chain_sequence, :chain_digest)`, 1,000 sequences per
   query):
   - signature key not in the keyring → `unknown_key` (sequence nil, `checkpoint:` set):
     UNVERIFIABLE, and the checkpoint is not used for anything else;
   - signature does not match → `checkpoint_altered`;
   - genesis digest differs from the record's, or the epoch it names is absent or has another
     digest → `checkpoint_mismatch`;
   - its sequence is beyond the head read after the walk, or no entry has it →
     `checkpoint_not_reached`;
   - the entry at its sequence has another digest → `checkpoint_mismatch`.
   Each checkpoint yields one result: `checked`, `not_reached`, `mismatch`, `altered` or
   `key_not_configured`.
5. `anchored_at` is the checked checkpoint with the highest sequence; `beyond_anchor` is
   `head_at_start - anchored_at.sequence`.

No ordering between checkpoints is checked, and none is needed: every case a "later checkpoint,
lower sequence" rule would catch already fails the per-checkpoint check, and a rule like that
would need a trusted order the anchor cannot supply (spec amendment 2).

### Verifying from a checkpoint (`from:`)

`FROM=latest` picks the checkpoint with the highest sequence. It must verify on its own first
(signature, genesis, epoch, its entry); if it does not, the run reports that and does not walk.
`Walk` gains `start:` (sequence and digest): the batch scope begins at `chain_sequence > start`,
`@expected = start + 1`, and `last_sequence`/`last_digest` start at the checkpoint, so
`check_record`'s head comparison works unchanged. `covered` becomes `start + 1..head`, and
`Verification#walked_from` names the checkpoint so the report can say what this run did not walk.

### Reporting

`Verification` gains `checkpoints` (results), `anchored_at`, `beyond_anchor` and `walked_from`.
Every summary line that follows a walk ends with the anchoring clause: `; not anchored` or
`; anchored at #500 (checkpoint 2026-10-25 14:00 UTC), 300 entries after it`. Checkpoint breaks
are listed with the label `checkpoint #500`. JSON gains `checkpoints`, `anchored_at`,
`beyond_anchor`, `walked_from`. `Break` gains `checkpoint` (the sequence it names).

### Anchor protocol and `FileAnchor`

An anchor responds to `publish(line)` and `checkpoints` (an Array of lines, in any order).
`config.ledger_anchor=` checks both methods (`require_protocol!`, as `audit_recorder=` does).
`FileAnchor.new(path)` appends `line + "\n"` with `File::APPEND | File::CREAT`, under `flock`,
then `fsync`; it never opens the file for writing any other way. `checkpoints` reads every
non-blank line.

### Tasks

- `bin/rails reeve:checkpoint_ledger` → `Reeve::Tasks.checkpoint_ledger(env:, out:)`: prints the
  checkpoint line and where it went; exit 0, or 1 when refused or the anchor raised (the line is
  still printed, so it can be stored by hand).
- `bin/rails reeve:verify_ledger` gains `CHECKPOINTS=path` (a file of lines; overrides the
  anchor; `CHECKPOINTS=` empty turns anchoring off) and `FROM=latest`. Exit codes unchanged;
  `CheckpointError` → 2.
- `bin/rails reeve:rotate_ledger_key`: after ROTATED with an anchor configured, makes a
  checkpoint; an anchor failure prints why and exits 1, the rotation stands (FR-008).

### Canonical form

`CHECKPOINT_TAG = "reeve-ledger-checkpoint-v1"`, `CHECKPOINT_FIELDS = %w[format ledger
genesis_digest pre_chain_count pre_chain_unchained_count head_sequence head_digest epoch
epoch_digest key_id made_at reeve_version]`, signed with the same `dump`/`hmac` helpers. The
line is that object plus `signature`, keys sorted, as JSON.

## Project Structure

### Documentation (this feature)

```text
specs/004-ledger-anchoring/
├── spec.md, plan.md, research.md, data-model.md, quickstart.md
├── contracts/checkpoint-v1.md   # the checkpoint line: fields, canonical form, signature
├── contracts/anchoring.md       # anchor protocol, tasks, library API, verification additions
└── checklists/requirements.md
```

### Source Code

```text
lib/reeve/audit/chain/checkpoint.rb         NEW: value, build, sign, parse, to_line
lib/reeve/audit/chain/checkpoint_check.rb   NEW: per-checkpoint verification (FR-011)
lib/reeve/audit/file_anchor.rb              NEW: append-only file anchor
lib/reeve/audit/chain.rb                    checkpoint!, verify(checkpoints:, from:)
lib/reeve/audit/chain/canonical.rb          checkpoint tag, fields, signature
lib/reeve/audit/chain/verifier.rb           parse, no-chain case, CheckpointCheck, from:
lib/reeve/audit/chain/walk.rb               start:
lib/reeve/audit/chain/verification.rb       kinds, results, anchoring fields, JSON
lib/reeve/audit/chain/report.rb             anchoring clause, checkpoint labels
lib/reeve/configuration.rb                  ledger_anchor
lib/reeve/errors.rb                         CheckpointError
lib/reeve/tasks.rb                          checkpoint_ledger, verify env, rotate checkpoint
lib/reeve/testing/checks/ledger_chain.rb    anchored:
lib/generators/reeve/install/templates/…    commented ledger_anchor line in the initializer
CHANGELOG.md, README.md
spec/reeve/audit/chain/checkpoint_spec.rb, anchoring_spec.rb (NEW: US1–US3 tamper cases)
spec/reeve/audit/file_anchor_spec.rb (NEW) + touched specs (output, tasks, LedgerChain)
```

## Delivery Order

1. Checkpoint value, canonical form, signature, parse; `FileAnchor`; `checkpoint!` (no
   verification yet). Specs fail first.
2. Verification against checkpoints: tamper specs for US1–US3 first, each beside its
   no-checkpoint twin pinning the 0.7.0 limit.
3. Reporting (US4): anchoring clause, JSON. Re-pin `verification_output_spec.rb` (SC-003).
4. Tasks, configuration, rotation checkpoint.
5. Verifying from a checkpoint (US5).
6. `LedgerChain anchored:`; docs (README, CHANGELOG, contracts); benchmark (SC-004).

## Risks

- **False BROKEN after a legitimate database reset.** A development or test database recreated
  under a persistent anchor makes every old checkpoint fail, truthfully: that ledger is gone.
  Mitigations: `LedgerChain` never reads the anchor's history (research R8); README tells hosts
  to use one anchor per environment and to start a new one when a ledger is deliberately reset.
  The verifier brief must try to produce a false BROKEN from routine operations (restore,
  rolling deploy, rotation).
- **The summary line changes for every host**, anchored or not (`; not anchored`). Text output is
  for people and JSON is the stable interface, but a host grepping the text could break. Stated
  in the CHANGELOG.
- **A local file anchor on the database host protects nothing.** Documented next to the example
  and in the `FileAnchor` comment; reeve cannot detect where the file lives.
- **Lock held across reads on MySQL**: the checkpoint's reads must be locking reads
  (`Head.current`), as specs/003's were, or a checkpoint could name a stale head. Covered by the
  same snapshot spec pattern as `mysql_snapshot_spec.rb`.

## Complexity Tracking

| Addition | Why needed | Simpler alternative rejected because |
|---|---|---|
| A setting (`ledger_anchor`) | The rotation task must publish, and routine verification must find checkpoints, without the operator passing them each time | Env vars only: a rotation would leave its new epoch unpinned unless the operator remembered a second step |
| `from:` verification | Proves a checkpoint is enough to verify from, which retention will rely on (spec US5) | Deferring it to retention would leave that claim untested until then |
