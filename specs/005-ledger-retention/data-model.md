# Data Model: Ledger Retention

The entries table does not change; the audit-entry contract stays 4.

## `reeve_audit_retentions` — new table

| Column | Type | Null | Meaning |
|---|---|---|---|
| `id` | bigint | no | Surrogate; not digested |
| `purge` | integer | no | 0, 1, 2… unique; serializes concurrent purges |
| `through_sequence` | bigint | no | The boundary: entries at or below it were purged |
| `through_digest` | string(64) | no | The boundary checkpoint's head digest; the walk links to it |
| `previous_through` | bigint | no | The previous record's boundary, or 0 |
| `removed_chained` | bigint | no | Chained entries this purge removed |
| `removed_pre_chain` | bigint | no | Contract-1/2 rows this purge removed |
| `archived` | boolean | no | Whether an archive was written |
| `archive_sha256` | string(64) | yes | SHA-256 of the archive file; null when `archived` is false |
| `purged_at` | datetime(6) | no | When the record was written |
| `key_id` | string(16) | no | Fingerprint of the key that signed it |
| `retention_digest` | string(64) | no | HMAC-SHA256, below |

Indexes: unique `purge`.

Rules: `through_sequence > previous_through`; `previous_through` equals the previous record's
`through_sequence`; `removed_*` are counts at the time of the purge (a resumed purge does not
change them).

Digest canonical form:

```
reeve-ledger-retention-v1\n[["previous_digest", <previous record's digest, or the genesis digest for purge 0>],
                            ["purge", n], ["through_sequence", s], ["through_digest", "…"],
                            ["previous_through", p], ["removed_chained", c], ["removed_pre_chain", r],
                            ["archived", true], ["archive_sha256", "…" or null], ["purged_at", µs], ["key_id", "…"]]
```

Grants:

| Role | Needs |
|---|---|
| Application | `SELECT` on `reeve_audit_retentions` (verification); no `DELETE` anywhere, as before |
| Retention (the purge) | `SELECT` on the four ledger tables, `DELETE` on `reeve_audit_entries`, `INSERT` on `reeve_audit_retentions` |

## Verification result additions

- `retention`: `{ through, records: [{ purge, through_sequence, purged_at, removed_chained,
  removed_pre_chain, archived, status }] }`, status `verified`, `altered` or
  `key_not_configured`; nil when the ledger was never purged.
- `awaiting_purge`: chained rows still at or below the boundary (a purge in progress, or a
  restore).
- Checkpoint result status gains `purged`.
- Break kind added: `retention_altered` (BROKEN). A record signed by a key not configured adds
  `unknown_key` (UNVERIFIABLE).

## Purge result

`Reeve::Audit::Chain::PurgeResult`: `status` (`:dry_run`, `:purged`, `:nothing_to_purge`,
`:refused`), `reason` (refusal reason or nil), `through` (boundary sequence), `through_made_at`,
`removed_chained`, `removed_pre_chain`, `archive` (path or nil), `archive_sha256`, `purge`
(record number), `warnings`.

## Archive (outside the database)

See [contracts/archive-v1.md](contracts/archive-v1.md).
