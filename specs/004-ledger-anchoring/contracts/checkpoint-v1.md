# Contract: Ledger Checkpoint, format v1

A checkpoint is one line of UTF-8 JSON: an object with exactly the fields in
[data-model.md](../data-model.md) "Checkpoint", keys sorted, no whitespace between tokens, no
trailing newline (an anchor adds its own separator). Example (wrapped here for reading):

```json
{"epoch":1,"epoch_digest":"5c1e…","format":"reeve-ledger-checkpoint-v1",
 "genesis_digest":"a03f…","head_digest":"e9b2…","head_sequence":48211,"key_id":"3fa4b5c6d7e8f901",
 "ledger":"ledger","made_at":"2026-10-25T14:00:00.000000Z","pre_chain_count":5000,
 "pre_chain_unchained_count":0,"reeve_version":"0.8.0","signature":"7d40…"}
```

## Signature

```
signature = HMAC-SHA256(key, "reeve-ledger-checkpoint-v1\n" + Canonical.dump(pairs))
pairs     = [[field, value] for field in
             format ledger genesis_digest pre_chain_count pre_chain_unchained_count
             head_sequence head_digest epoch epoch_digest key_id made_at reeve_version]
```

`key` is the secret whose fingerprint is `key_id`. `Canonical.dump` is the form specs/002
contracts define for entry digests (typed values, integers as integers, nil as null). `made_at`
is signed as the string it is stored as, not converted to microseconds, so the line verifies
exactly as written. Lowercase hex, 64 characters.

## What it contains, and what it never contains

Only digests, sequence numbers, counts, a key fingerprint, a time and versions. Never entry
content, never a key. It can be stored where the ledger's data must not be.

## Versioning

`format` names the version. A change to the field list or the signed form is a new version,
`reeve-ledger-checkpoint-v2`, and a verifier that does not know a version refuses it
(`CheckpointError`), never skips it. A reeve release that adds a version keeps reading v1.

## What a v1 checkpoint asserts

"A process holding key `key_id` saw the chain named by `genesis_digest` reach entry
`head_sequence` with digest `head_digest`, with epoch `epoch` (digest `epoch_digest`) as its
latest epoch." It does not assert that the chain was intact, and its `made_at` is the
producing host's clock.
