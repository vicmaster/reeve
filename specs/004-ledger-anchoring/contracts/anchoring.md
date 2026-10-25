# Contract: Anchoring and Checkpoint Verification

## Configuration

```ruby
config.ledger_anchor = Reeve::Audit::FileAnchor.new("/mnt/ledger-anchor/production.checkpoints")
```

Any object responding to `publish(line)` and `checkpoints` (→ Array of String). Anything else is
an `ArgumentError` naming the missing method. `nil` (the default) means no anchor.

`FileAnchor.new(path)`: appends one line per `publish`, never rewrites or truncates; `checkpoints`
returns every non-blank line, and `[]` for a file that does not exist yet.

## Rake

```
bin/rails reeve:checkpoint_ledger                        # exit 0 made (and published), 1 refused or anchor failed
bin/rails reeve:verify_ledger                            # uses the anchor's checkpoints, if configured
CHECKPOINTS=path bin/rails reeve:verify_ledger           # a file of checkpoint lines instead
CHECKPOINTS= bin/rails reeve:verify_ledger               # not anchored, even with an anchor configured
FROM=latest bin/rails reeve:verify_ledger                # walk from the highest checkpoint
```

Ruby: `Reeve::Tasks.checkpoint_ledger(env: ENV, out: $stdout)` → Integer exit status.
Library: `Reeve::Audit::Chain.checkpoint!(entry_class: Entry, anchor: Reeve.config.ledger_anchor)`
→ `CheckpointResult`; `Reeve::Audit::Chain.verify(keys: nil, checkpoints: nil, from: nil, …)`
→ `Verification`. `checkpoints: nil` means the configured anchor's; an Array is used as given.
`from:` accepts `:latest` or a `Checkpoint`. `FROM` accepts `latest` only.

### checkpoint_ledger output

```
reeve ledger checkpoint: MADE — head #48,211, epoch 1, key 3fa4b5c6d7e8f901; published to the anchor
{"epoch":1,…}
reeve ledger checkpoint: MADE — head #48,211, epoch 1, key 3fa4…; no anchor configured, store the line below yourself
{"epoch":1,…}
reeve ledger checkpoint: MADE — head #48,211 …; the anchor failed (<error message>), store the line below yourself
{"epoch":1,…}
reeve ledger checkpoint: REFUSED — no ledger key configured (config.ledger_key); nothing was made
reeve ledger checkpoint: REFUSED — the ledger has no chain yet; nothing to checkpoint
```

Exit: 0 for MADE when published, or when no anchor is configured; 1 for REFUSED or an anchor
failure.

### rotate_ledger_key

After ROTATED with an anchor configured, a checkpoint is made and published; its MADE line
follows the ROTATED line. An anchor failure prints the MADE … failed line and exits 1; the
rotation is not undone.

## Verification

Break kinds added (BROKEN, exit 1): `checkpoint_not_reached`, `checkpoint_mismatch`,
`checkpoint_altered`. A checkpoint signed by a key not configured: `unknown_key` (UNVERIFIABLE,
exit 2). A checkpoint that does not parse: `CheckpointError`, exit 2, message naming its position.

Every summary line after a walk ends with the anchoring clause:

```
reeve ledger: INTACT — sequences 1–48,211 verified (head at start: 48,211); 5,000 earlier entries not covered; anchored at #48,000 (checkpoint 2026-10-25 14:00 UTC), 211 entries after it
reeve ledger: INTACT — sequences 1–48,211 verified (head at start: 48,211); 5,000 earlier entries not covered; not anchored
reeve ledger: BROKEN — 1 break in sequences 1–400; 5,000 earlier entries not covered; anchored at #300 (checkpoint 2026-10-24 14:00 UTC), 100 entries after it
reeve ledger: BROKEN — 1 break in the ledger; the ledger has no chain, but 3 checkpoints name one
reeve ledger: INTACT — sequences 9,001–10,000 verified from checkpoint #9,000 (2026-10-25 14:00 UTC); 9,000 earlier chained entries not walked by this run; … ; anchored at #9,000 …
```

Breaks are listed with the label `checkpoint #48,000`. JSON: `checkpoints` (array of results),
`anchored_at` (`{ head_sequence, made_at }` or null), `beyond_anchor`, `walked_from` (same shape
or null) added; each break gains `checkpoint`; every existing key unchanged.

## Testing kit

`Reeve::Checks::LedgerChain.new(anchored: true)`: after writing its entries, makes a checkpoint,
publishes it through `config.ledger_anchor`, reads the anchor back, and verifies with that
checkpoint only. Passes when INTACT and anchored at it; fails, naming the setting, when no anchor
is configured or the checkpoint does not come back. `anchored: false` (default) is unchanged and
never reads the anchor.
