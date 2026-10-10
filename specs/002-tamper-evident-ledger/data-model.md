# Data Model: Tamper-Evident Audit Ledger

Audit-entry contract **2 → 3**. Every change is additive. Existing rows are never touched.

## `reeve_audit_entries` — three new nullable columns

| Column | Type | Null | Meaning |
|---|---|---|---|
| `chain_sequence` | bigint | yes | Position in the chain, from 1. Assigned by reeve under the chain lock. NULL on rows written before contract 3, and on contract-3 rows written without a key. |
| `chain_key_id` | string(16) | yes | Fingerprint of the key that signed this row (R7). Never the key. |
| `chain_digest` | string(64) | yes | Hex HMAC-SHA256 over the canonical entry (below). |

Index: unique on `chain_sequence`. NULLs are distinct on SQLite, PostgreSQL and MySQL, so
unchained rows do not collide. The index also orders the verification walk.

### How a row is classified

| `contract_version` | `chain_digest` | Classification | Effect on verification |
|---|---|---|---|
| 1 or 2 | NULL | **uncovered** | Counted beside the status; never part of a pass, never a break. |
| 3 | present | **chained** | Verified. |
| 3 | NULL | **unchained** | Written under `:warn` with no key, or by a host recorder that did not chain. Those that existed when the chain started (`pre_chain_unchained_count`) are reported as uncovered. Any beyond that count are `unchained` breaks: no older reeve writes contract 3, so they can only postdate the genesis. They have no sequence and are identified by `invocation_id`. Which of them are the new ones cannot be known exactly, so the report lists those with `occurred_at` after `genesis_at` and says that this is by clock. |
| 1 or 2 | present | **inconsistent** | A break (`digest_mismatch` at its sequence). reeve never writes this; it means the row was altered. |

### Canonical entry (input to `chain_digest`)

Domain tag `reeve-ledger-entry-v1`, then these fields in this order. The list is written out
in `Reeve::Audit::Chain::Canonical`, not derived from the columns:

```text
previous_digest   (genesis_digest for sequence 1)
chain_sequence
chain_key_id
contract_version
invocation_id  occurred_at  agent_id  agent_name  principal_type  principal_id
tool_name  arguments  outcome  rule  detail  record_type  record_ids  record_count
truncated  derived  guard  duration_ms  metadata
```

Excluded: `id`, the database primary key (FR-002), and `chain_digest` itself.

Value rules (R2): JSON values have keys sorted at every level and normalized numbers; times
are integer microseconds since the epoch, UTC; `nil` is distinct from empty; every field is
typed, so `"1"` and `1` never digest alike.

A future contract that adds a column adds it to the canonical form for rows written at that
contract only, keyed on the row's own `contract_version`. Earlier rows keep verifying under
the field list they were written with.

## `reeve_audit_chains` — new table, one row

| Column | Type | Null | Written | Meaning |
|---|---|---|---|---|
| `id` | primary key | — | once | Not used for anything; restore may change it. |
| `name` | string | no | once | Always `"ledger"`. Unique index: two writers racing to start the chain cannot both succeed. |
| `genesis_at` | datetime(6) | no | once | When the chain started. |
| `pre_chain_count` | bigint | no | once | Rows with `contract_version < 3` when the chain started. Informational (R5). |
| `pre_chain_unchained_count` | bigint | no | once | Contract-3 rows with no digest when the chain started (`:warn` without a key). The baseline for `unchained` breaks (R5). |
| `genesis_key_id` | string(16) | no | once | Key that signed the genesis. |
| `genesis_digest` | string(64) | no | once | HMAC over `reeve-ledger-genesis-v1 ‖ genesis_at ‖ pre_chain_count ‖ pre_chain_unchained_count ‖ genesis_key_id`. Link 0. |
| `head_sequence` | bigint | no | every chained write | Latest sequence assigned. 0 between creation and the first insert (in the same transaction, so never visible as 0). |
| `head_digest` | string(64) | no | every chained write | Digest of the row at `head_sequence`. |

The model (`Reeve::Audit::ChainRecord`) marks the genesis columns `attr_readonly` and
aborts `destroy`, as `Entry` does. It has no public writer. Only `Chain#append!` advances
the head.

### Life cycle

```text
(no record) ──before the first chained write──▶ started: genesis written, head = (0, genesis digest)
started/created ──each chained write──▶ head = (n+1, digest of row n+1)
```

The genesis is written in a step of its own, just before the first chained write (research
R3, "The genesis race on MySQL"), so a started chain with nothing in it can exist; the
verifier reports it as `no_chain`. A rolled-back write rolls back the head move with it.
There is no other transition.

## Configuration additions

| Setting | Type | Default | Validation |
|---|---|---|---|
| `ledger_key` | String or nil | nil | nil, or ≥ 32 bytes. Anything shorter or blank raises `ArgumentError` when assigned. |
| `retired_ledger_keys` | Array of String | `[]` | Each ≥ 32 bytes; none equal to `ledger_key`. |

`Configuration#to_h` and `#inspect` show fingerprints, never secrets.

## Verification result (`Reeve::Audit::Chain::Verification`)

| Field | Meaning |
|---|---|
| `status` | `:intact`, `:broken`, `:unverifiable`, or `:no_chain` |
| `covered` | Sequence range verified (`1..n`), or nil |
| `uncovered_now` | Rows with `contract_version < 3` now |
| `uncovered_at_genesis` | `pre_chain_count` from the chain record, or nil |
| `unverifiable_count` | Rows signed by a key the verifier does not hold |
| `breaks` | `[Break(kind, sequence or range, detail)]`, possibly capped for display |
| `totals` | Count per kind, never capped |
| `head_at_start` | The head sequence verification walked to |
| `head_at_end` | The head re-read after the walk; chained rows above it are `beyond_head` |
| `unchained_now` / `unchained_at_genesis` | Contract-3 rows with no digest, now and at genesis |

`totals` counts breaks per kind, one per break; a gap is one `missing` break whose range
shows the entries it spans.

`Break#kind` ∈ `digest_mismatch`, `missing`, `duplicate`, `unchained`, `head_mismatch`,
`beyond_head`, `genesis_altered`, `chain_record_missing`, `unknown_key`. A break carries a
sequence or range, except `unchained`, which carries an `invocation_id`.

Status rules, in order:
1. no key available to the verifier → `:unverifiable` (and nothing else is claimed);
2. no chain record and no chained rows → `:no_chain`;
3. any break other than `unknown_key` → `:broken`;
4. any `unknown_key` → `:unverifiable`;
5. otherwise → `:intact`.
