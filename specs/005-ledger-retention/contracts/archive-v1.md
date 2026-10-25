# Contract: Ledger Archive, format v1

A UTF-8 file of JSON lines, written to `path.tmp`, flushed, then renamed to `path`. Its SHA-256 is
recorded in the retention record (`archive_sha256`).

## Line 1: header

```json
{"format":"reeve-ledger-archive-v1","ledger":"ledger","purge":0,
 "from_sequence":1,"through_sequence":6000,
 "through_checkpoint":"{\"epoch\":0,…}",
 "start":{"genesis":{"genesis_at":"…","pre_chain_count":5000,"pre_chain_unchained_count":0,
                     "genesis_key_id":"…","genesis_digest":"…"}},
 "chained":6000,"pre_chain":5000,"reeve_version":"0.8.0"}
```

`through_checkpoint` is the boundary checkpoint's line, verbatim (contracts/checkpoint-v1.md of
specs/004). `start` is the genesis for purge 0, or `{"checkpoint": "<previous boundary checkpoint
line>"}` for later purges.

## Lines 2…: rows

One object per row: every column of the entries table except `id`, keys sorted, times as
ISO 8601 UTC with microseconds, JSON columns as JSON. Pre-chain rows first (no chain columns),
then chained rows in sequence order.

## Verifying

1. The header parses and names this format.
2. `through_checkpoint` (and, for later purges, the start checkpoint) verify under a held key.
3. For purge 0, the genesis digest recomputes under its key from the header's genesis fields.
4. Each chained row, rebuilt as an unsaved entry, recomputes its digest against the previous
   row's recorded digest, starting from the start link; sequences run `from_sequence` to
   `through_sequence` with no gap or repeat.
5. The last row's digest equals the boundary checkpoint's `head_digest`.
6. Counts match the header.

Any failure is a break, reported as `verify_ledger` reports one; a key not held is UNVERIFIABLE.

## Versioning

`format` names the version. A verifier that does not know a version refuses it, never skips it.
