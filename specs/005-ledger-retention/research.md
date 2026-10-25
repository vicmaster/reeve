# Research: Ledger Retention

Decisions behind plan.md, read against the tree at `f2dd032` (spec 004 merged). The code was
read directly; no research agent was used.

## R1 — Where the record lives, and whether the contract bumps

- **Decision**: a new table `reeve_audit_retentions`; the audit-entry contract stays 4.
- **Findings**: Nothing about an entry's columns or digest changes. The upgrade generator detects
  each step by the tables and columns it adds (`upgrade_generator.rb` `STEPS`, `applied?`), so a
  step that only creates a table fits without a new contract number. Verification already treats
  an absent chain table as "none" (`EpochRules.read` checks `table_exists?`); retention records
  do the same, so an unmigrated ledger verifies as 0.7.0's.
- **Alternatives**: columns on the chain record (only the latest purge survives, and a retention
  history is evidence); a contract bump to 5 (would force every host through an upgrade for a
  feature most will not use).

## R2 — Signing and chaining the record

- **Decision**: HMAC under the configured ledger key, tag `reeve-ledger-retention-v1`, over the
  record's fields and the previous record's digest (the genesis digest for record 0).
- **Rationale**: the epochs use the same shape (`canonical.rb#epoch_digest`): deleting or editing
  one record breaks the chain at the next, and record 0's link to the genesis stops a forged
  first record. A distinct tag keeps a retention digest from passing as any other.

## R3 — Verifying before purging: the whole ledger, not the range

- **Decision**: the purge requires `Chain.verify` INTACT with the anchor's checkpoints, and the
  boundary checkpoint `checked` (spec amendment 1).
- **Rationale**: the spec asked for the range to verify; the whole-ledger check is the same walk
  with the rest of the chain included, costs one walk of what remains (the walk already starts
  at the previous boundary), and refuses to purge a ledger with a break anywhere. A purge is a
  deliberate, rare act; refusing it while something is broken is the conservative reading of
  "tampering must never pass as a purge".

## R4 — The retention connection

- **Decision**: `config.ledger_retention_connection`, an abstract ActiveRecord class the host
  defines with `connects_to` (or `establish_connection`) to the same database under a role with
  `DELETE`.
- **Findings**: `ChainRecord.require_same_database!` already compares `connection_db_config`
  hashes; the same comparison, on database and host, proves the retention class reaches the
  ledger's database, and equal usernames on PostgreSQL and MySQL prove it is the application's
  own role. SQLite has no roles: the check cannot tell, so the task warns and proceeds.
- **Alternatives**: credentials in env vars on the task (a password on a command line);
  `connected_to(role:)` (needs the host to configure roles for its whole app, much more than
  this needs).

## R5 — Deleting without holding writers

- **Decision**: delete by id in batches of 1,000, each its own transaction, no chain-record lock.
- **Findings**: Writes take the chain record's lock (`head.rb`) and only append above the head;
  the purge only deletes at or below a boundary under the head, so the two never touch the same
  rows. Two purges at once are serialized by the record's unique `purge` number: the second
  insert fails and refuses (spec amendment 3).

## R6 — Checkpoints at and below the boundary

- **Decision**: the checkpoint at the boundary is checked against the record's digest; lower ones
  get status `purged` and anchor nothing (spec amendment 4).
- **Findings**: `CheckpointCheck#position` reports an entry that is gone as `checkpoint_not_reached`
  (specs/004). After a purge that would make every old checkpoint a break. Their genesis and
  signature are still checked, so a forged old checkpoint is still caught.

## R7 — The archive

- **Decision**: JSON lines, a header carrying the boundary checkpoint's line and the start link,
  then every column of every row; verified by rebuilding unsaved `Entry` instances and applying
  the walk's digest rule.
- **Findings**: `Canonical.entry_digest` is computed over a model instance so that casts match the
  database (`chain.rb#link!` comment); rebuilding from JSON through `Entry.new` gives the same
  casts. specs/002's restore spec showed JSON round trips verify except integers beyond double
  precision on MySQL, a limit that applies here too. Written to `path.tmp`, `fsync`, renamed, so a
  partial archive is never mistaken for a whole one.
- **Alternatives**: CSV (loses JSON columns' types); the engine's dump tool (needs a matching
  client, as the restore spec found, and cannot be verified without a database).

## R8 — Choosing the boundary by age

- **Decision**: `OLDER_THAN=Nd` (days only) picks the highest checkpoint, among the anchor's that
  verify, whose entry occurred before now − N days.
- **Rationale**: sequence order is commit order and `occurred_at` is invocation time, so they can
  disagree by seconds; choosing by the boundary entry's own time keeps the rule simple and the
  task prints the boundary's time so the operator sees what "older than" meant.

## R9 — Prior art

- **CloudTrail** keeps digest files beside logs and lets logs age out under S3 lifecycle rules;
  the digest chain continues, and a validator reports which files are gone. reeve's retention
  record plays the role of "this gap is expected".
- **WORM retention** (S3 Object Lock, compliance mode): the store that should hold the archive.
- **Ruby gems**: paper_trail and audited offer age-based cleanup by deleting versions; neither has
  a chain to keep verifiable, so neither has this problem to solve.
