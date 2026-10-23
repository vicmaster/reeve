# Data Model: Ledger Key Epochs

## `reeve_audit_entries` — one column added (contract 4)

| Column | Type | Null | Meaning |
|---|---|---|---|
| `chain_epoch` | integer | yes | Number of the key epoch whose key signed this row. Set on every chained row written at contract 4; NULL on rows written at contract ≤ 3 ("before key epochs") and on unchained rows. |

Canonical field list, contract 4 (order fixed):

```
chain_sequence chain_key_id chain_epoch contract_version
invocation_id occurred_at agent_id agent_name principal_type principal_id
tool_name arguments outcome rule detail record_type record_ids record_count
truncated derived guard duration_ms metadata
```

## `reeve_audit_chain_epochs` — new table

| Column | Type | Null | Meaning |
|---|---|---|---|
| `id` | bigint | no | Surrogate; not digested |
| `epoch` | integer | no | 0, 1, 2… unique |
| `key_id` | string(16) | no | Fingerprint of the epoch's key; unique |
| `first_sequence` | bigint | no | First chain sequence the epoch can cover |
| `opened_at` | datetime(6) | no | When the epoch was opened |
| `epoch_digest` | string(64) | no | HMAC-SHA256 under the epoch's key |

Indexes: unique `epoch`; unique `key_id`.

Epoch digest canonical form:

```
reeve-ledger-epoch-v1\n[["previous_digest", <previous epoch's digest, or the genesis digest for epoch 0>],
                        ["epoch", n], ["key_id", "…"], ["first_sequence", s], ["opened_at", µs]]
```

Grants: the application role needs `INSERT, SELECT` on `reeve_audit_chain_epochs` (never UPDATE).

## Verification result additions

- `epochs`: array of `{ epoch, key_id, first_sequence, entries, status }`, status one of
  `verified`, `key_not_configured`, `altered`.
- `before_first_epoch`: count of chained rows positioned before epoch 0's `first_sequence`
  (all chained rows when there are no epochs).
- Break kinds added: `epoch_missing`, `epoch_mismatch`, `epoch_altered` — all BROKEN.

## Rotation value

`Reeve::Audit::Chain::Rotation`: `status` (`:rotated`, `:current`, `:refused`), `reason`
(`:no_key`, `:key_reused`, `:outgoing_key_missing`, or nil), `epoch`, `key_id`,
`first_sequence`, `previous_epoch`, `previous_key_id`, `warnings` (array of strings).
