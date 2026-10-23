# Contract: Key Rotation and Epoch Verification

## Rake

```
bin/rails reeve:rotate_ledger_key                       # exit 0 ROTATED/CURRENT, 1 REFUSED
ACCEPT_UNVERIFIABLE=1 bin/rails reeve:rotate_ledger_key # lost-key case only
```

Ruby: `Reeve::Tasks.rotate_ledger_key(env: ENV, out: $stdout)` → Integer exit status.
Library: `Reeve::Audit::Chain.rotate_key!(accept_unverifiable: false, entry_class: Entry)` →
`Rotation`. `ACCEPT_UNVERIFIABLE` accepts `1` only; any other non-empty value is an
`ArgumentError` naming the accepted value.

### Output (first line always one of three)

```
reeve ledger key: ROTATED — epoch 1 opened with key 3fa4…(16 hex) from sequence 5,001; epoch 0 (key 9bc1…) stays verifiable while that key is in retired_ledger_keys
reeve ledger key: CURRENT — epoch 1 already signs with the configured key 3fa4…; nothing to do
reeve ledger key: REFUSED — <reason sentence naming the fix>; nothing was written
```

Warnings follow on lines prefixed `warning: `.

Refusal sentences:
- `:no_key` — "no ledger key configured (config.ledger_key)".
- `:key_reused` — "the configured key 3fa4… already opened epoch K; a key opens one epoch only — configure a new key".
- `:outgoing_key_missing` — "epoch N's key 9bc1… is not configured on this host, so its entries would become unverifiable here — add it to config.retired_ledger_keys, or run with ACCEPT_UNVERIFIABLE=1 if that key is lost".

## Writes

A chained contract-4 write opens the next epoch when the configured key has none (FR-004),
and signs as a straggler under its own earlier epoch otherwise (FR-005).

## Verification

Break kinds added (all BROKEN, exit 1): `epoch_missing`, `epoch_mismatch`, `epoch_altered`.
Rules: spec.md FR-010, FR-011.

Text report: after the existing summary (and totals), when there are two or more epochs or any
epoch is not verified, one line per epoch:

```
  epoch 0  key 9bc1d2e3f4a5b6c7  from sequence 1      4,999 entries  verified
  epoch 1  key 3fa4b5c6d7e8f901  from sequence 5,001    120 entries  key not configured
```

JSON: `epochs` (array) and `before_first_epoch` (integer) added; every existing key unchanged.
