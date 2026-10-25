# Data Model: Ledger Anchoring

No table or column changes. The audit-entry contract stays 4.

## Checkpoint (outside the database)

`Reeve::Audit::Chain::Checkpoint`, a frozen value. Stored as one line: the fields below plus
`signature`, as a JSON object with sorted keys. Full format: [contracts/checkpoint-v1.md](contracts/checkpoint-v1.md).

| Field | Type | Null | Meaning |
|---|---|---|---|
| `format` | string | no | `"reeve-ledger-checkpoint-v1"` |
| `ledger` | string | no | `ChainRecord::LEDGER` (`"ledger"`) |
| `genesis_digest` | string(64) | no | The chain record's genesis digest |
| `pre_chain_count` | integer | no | From the genesis |
| `pre_chain_unchained_count` | integer | no | From the genesis |
| `head_sequence` | integer | no | ≥ 1 |
| `head_digest` | string(64) | no | The digest of the entry at `head_sequence` |
| `epoch` | integer | yes | Latest epoch's number; null when the ledger has no epochs |
| `epoch_digest` | string(64) | yes | Latest epoch's digest; null with `epoch` |
| `key_id` | string(16) | no | Fingerprint of the key that signed the checkpoint |
| `made_at` | string | no | ISO 8601 UTC, microseconds; for people, never used by verification |
| `reeve_version` | string | no | `Reeve::VERSION` that made it |
| `signature` | string(64) | no | HMAC-SHA256, see the contract |

Rules: parsing rejects a missing field, an unknown `format`, a wrong type, or extra fields
(`CheckpointError`, naming the line's position). `epoch` and `epoch_digest` are both null or both
set.

## Anchor (the host's)

Any object with `publish(line)` (stores one line; raises on failure) and `checkpoints` (returns
every stored line, any order). `Reeve::Audit::FileAnchor.new(path)` is the one reeve ships.

## Verification result additions

- `checkpoints`: array of `{ head_sequence, made_at, key_id, status }`, status one of `checked`,
  `not_reached`, `mismatch`, `altered`, `key_not_configured`. Empty when not anchored.
- `anchored_at`: the `checked` checkpoint with the highest `head_sequence`, or nil.
- `beyond_anchor`: entries after it (`head_at_start - anchored_at.head_sequence`), or nil.
- `walked_from`: the checkpoint the walk started from, or nil for a walk from the genesis.
- Break kinds added: `checkpoint_not_reached`, `checkpoint_mismatch`, `checkpoint_altered`, all
  BROKEN. A checkpoint signed by a key not configured adds an `unknown_key` break (sequence nil):
  UNVERIFIABLE.
- `Break` gains `checkpoint`: the `head_sequence` of the checkpoint a break is about.

Status, with checkpoints supplied: any checkpoint break makes it BROKEN, including when the
ledger has no chain (NO CHAIN is only for unanchored verification).

## Checkpoint result

`Reeve::Audit::Chain::CheckpointResult` (making one): `status` (`:made`, `:refused`), `reason`
(`:no_key`, `:no_chain`, or nil), `checkpoint`, `published` (true, false when no anchor is
configured), `error` (the anchor's exception message, or nil).
