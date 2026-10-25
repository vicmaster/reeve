# Research: Ledger Anchoring

Decisions behind plan.md, read against the tree at `7eaaa6f` (0.7.0 plus the SC-004 record).
No research agent was used; the chain code was read directly.

## R1 — What a checkpoint must name

- **Decision**: genesis digest (plus the pre-chain counts it covers), head sequence and digest,
  latest epoch number and digest, signing key fingerprint, time, reeve version, format version.
- **Findings**: The chain record holds the genesis and the head (`chain_record.rb`, `head.rb`).
  The genesis digest covers `genesis_at`, both pre-chain counts and the genesis key
  (`canonical.rb` `GENESIS_FIELDS`), so naming the digest pins all of them; the counts are
  carried as well for people and for retention, which removes rows and must still know how many
  preceded the chain. Each epoch digest covers the previous epoch's digest, and epoch 0's covers
  the genesis digest (`epochs.rb#open!`), so the latest epoch's digest pins every epoch record,
  the same way the head digest pins every entry.
- **Alternatives**: every epoch in the checkpoint (redundant given the epoch chain, and grows
  with rotations); the head only (leaves specs/003 item 6 open: a fresh epoch with no entries is
  named by nothing).

## R2 — Reading one consistent state

- **Decision**: take the head's no-consume lock (`Head#lock!`, specs/003 FR-008) in a transaction,
  read through `Head.current`, release before publishing.
- **Findings**: A write moves the head and opens its epoch in one transaction behind that lock
  (`chain.rb#link!`); the head digest is updated after the insert, in the same transaction
  (`head.rb#point_at!`). Two unlocked reads could pair a head with an epoch opened just after it.
  That pairing would still be true facts, but harder to state. The lock costs one UPDATE that
  changes nothing, and on MySQL the reads must be locking reads, as in specs/003's code review.
- **Alternatives**: unlocked reads (cheaper, but the checkpoint names a state that may never have
  existed at one instant); publishing inside the lock (a slow store would hold every writer).

## R3 — Signing

- **Decision**: HMAC-SHA256 under the configured `ledger_key`, tagged
  `reeve-ledger-checkpoint-v1`, over the same canonical `dump` as the other digests; the line
  names the key fingerprint.
- **Findings**: Every other digest is an HMAC over `Canonical.dump` with a distinct tag
  (`canonical.rb`). A distinct tag keeps a checkpoint signature from ever being accepted as an
  entry, genesis or epoch digest. The signer is the configured key, which during a rolling
  deploy may be an earlier epoch's key; its fingerprint is in the keyring of any verifier that
  holds that epoch, so this changes nothing a verifier needs (spec amendment 1).
- **Alternatives**: asymmetric signatures, so a third party can verify without the key: out of
  scope (specs/003, spec.md). Unsigned checkpoints, trusting the store alone: an edited
  checkpoint naming a shorter chain would then be believed.

## R4 — Checking checkpoints against each other

- **Decision**: don't. Check each checkpoint against the ledger independently.
- **Findings**: The cases a cross-check would catch (a later checkpoint naming a lower sequence;
  two digests at one sequence) need either a trusted clock or a trusted order. The clock is the
  host's (spec guarantee item 5); the order is whatever the store returns. And each case already
  fails a per-checkpoint check: after a truncation and regrowth, the higher checkpoint's
  sequence holds a different entry, so its digest differs; of two digests at one sequence, at
  most one is the entry's.
- **Alternatives**: chain checkpoints to each other, as CloudTrail digest files do (each names
  the previous file's signature). Rejected: publishing would then need to read the store, which
  rules out write-only stores (log shipping), and it only detects a deleted middle checkpoint,
  never the newest, which is the one an attacker wants gone.

## R5 — Malformed checkpoints

- **Decision**: `CheckpointError` naming the line's position; the task exits 2.
- **Rationale**: An unparseable line or an unknown format version is not evidence of tampering
  with the ledger (it may be a newer reeve's format, or the wrong file), so it is not a break.
  But skipping it would let a corrupted store read as "anchored by the rest". Refusing to
  answer is the only honest output, and 2 already means "could not verify".

## R6 — The anchor protocol

- **Decision**: two methods, `publish(line)` and `checkpoints`. Lines, not objects: the anchor
  stores text and never needs reeve's classes.
- **Findings**: `Configuration#require_protocol!` already validates `audit_recorder` and `logger`
  this way. Any store fits: a file, an object store client, a log shipper wrapper (whose
  `checkpoints` reads back from wherever the log lands).
- **`FileAnchor`**: `File::APPEND | File::CREAT`, `flock(LOCK_EX)`, write, `fsync`. Append mode
  makes each write land at the end even with two processes; the lock keeps lines whole. It is a
  building block: on the database host it protects nothing, but pointed at a mount backed by an
  object-locked bucket, or a path a separate shipper collects, it is the whole integration.

## R7 — Verifying from a checkpoint

- **Decision**: `Walk` takes a start (sequence, digest); the checkpoint is fully checked before
  the walk relies on it.
- **Findings**: The walk links each row to the previous row's recorded digest and starts from the
  genesis digest (`walk.rb`); starting from a checkpoint is the same with another link and
  another first sequence. Keyset pagination already starts from a bound (`batch_scope`), and
  `check_record` compares the head with `last_sequence`/`last_digest`, which start at the
  checkpoint. `EpochRules#check!` reads records, not walked rows, so it is unaffected; its
  per-epoch entry counts then cover the walked rows only, and the report says so.

## R8 — LedgerChain and test databases

- **Decision**: `LedgerChain.new(anchored: true)` makes its own checkpoint after writing its
  entries, publishes it through the configured anchor, reads the anchor back, and verifies with
  the checkpoint it made only. Passes when INTACT and anchored at that checkpoint.
- **Findings**: The check runs in a host's test suite, where transactional fixtures give every
  example an empty ledger (`ledger_chain.rb` comment). Any checkpoint from an earlier run names a
  genesis that no longer exists, and verifying with it would fail every time, truthfully and
  uselessly. What the host can prove in CI is that its anchor is configured and round-trips.
  Whether production checkpoints match production is the scheduled `verify_ledger`'s job.
- **Default**: `anchored: false`, so existing suites are unchanged.

## R9 — Prior art and positioning

- **Certificate Transparency** (RFC 6962): signed tree heads published so a log cannot quietly
  shrink; monitors compare heads. The same idea at a smaller scale, without a Merkle tree, since
  reeve's verifier walks the whole chain anyway.
- **C2SP tlog-checkpoint**: a small signed text note naming origin, size and root hash. Close in
  spirit; reeve's line is JSON for consistency with `FORMAT=json`, and signed by HMAC, not a
  public key.
- **CloudTrail log file integrity**: hourly digest files, signed, written to S3. The cadence model
  reeve's on-demand checkpoints follow, and the source of the rejected chaining idea (R4).
- **S3 Object Lock (compliance mode)**, and WORM storage generally: what the README points hosts
  at for the store.
- **Ruby gems**: paper_trail, audited and logidze version records and keep no keyed chain, so
  nothing to anchor or compete with (constitution IV).
