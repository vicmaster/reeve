# Phase 0 Research: Tamper-Evident Audit Ledger

Each decision names what was chosen, why, and what was rejected. Confidence is stated where
it is less than high.

## R1. Digest primitive

**Decision**: HMAC-SHA256 from Ruby's `openssl` standard library, hex-encoded (64
characters). Every digest input begins with a fixed domain tag (`reeve-ledger-entry-v1`,
`reeve-ledger-genesis-v1`), so an entry digest can never be passed off as a genesis digest
or the other way round, and a future canonical form can move to `-v2` without ambiguity.

**Rationale**: HMAC is the construction that makes the chain unforgeable without the key,
which is the whole of FR-008's threat model. `openssl` ships with every Ruby the gem
supports, so the runtime dependency list stays empty (Constitution IV).

**Alternatives rejected**: an unkeyed SHA-256 chain (anyone with write access recomputes it —
the reason the spec exists); digital signatures (Ed25519 would let an auditor verify
without the signing secret, which is real value, but needs a key pair to manage and an
`openssl` API that differs across the Ruby 3.0–3.4 range; recorded as future work);
`ActiveSupport::MessageVerifier` (designed for messages, not chains, and would add
ActiveSupport to the core's write path).

## R2. Canonical form — the part most likely to go wrong

The spec requires an untampered entry to verify after being read back from SQLite,
PostgreSQL and MySQL (FR-003, SC-002). The databases do not return what they were given:

| Value | What changes |
|---|---|
| JSON columns (`arguments`, `record_ids`, `metadata`) | MySQL `JSON` and PostgreSQL `jsonb` reorder object keys and drop whitespace. `jsonb` rewrites `1.0e+20` as `100000000000000000000`, which Ruby reads back as an Integer. PostgreSQL `json` (what `t.json` creates) and SQLite text keep the text as written. |
| Symbol keys and non-JSON values in arguments | Stored as their JSON rendering (`:a` → `"a"`, `Time` → ISO-8601 at ActiveSupport's precision, `NaN` → `null`). |
| `occurred_at` | Stored at the column's precision. MySQL *rounds* fractional seconds rather than truncating; a column with no declared precision is whole seconds on MySQL and microseconds elsewhere. |

**Decision**: normalize before writing, canonicalize when digesting.

1. **Normalize before writing.** The recorder sends each JSON value through the same encode
   and decode ActiveRecord applies (`ActiveSupport::JSON`), and floors `occurred_at` to the
   column's effective precision (read from the schema once and cached), so the database
   has nothing left to round. What is written is then exactly what is read back, except
   for key order and number formatting.
2. **Canonicalize when digesting**, the same way at write and at verify time: JSON with
   object keys sorted at every level, numbers written in a normalized decimal form (so
   `1.0e+20`, `100000000000000000000` and `1e20` are the same number), strings escaped
   identically, `nil` distinct from empty. Times become integer microseconds since the
   epoch in UTC, so the host's `default_timezone` does not matter. Booleans and integers
   are typed, not stringified. Fields are digested in a fixed, written-out order (the
   ContractVersion lesson: an expectation derived from the thing being checked checks
   nothing).

**Known limit, stated rather than hidden** (confidence: high that it exists, low that any
host will hit it): a number beyond double precision in `arguments` can be rounded by MySQL's
`JSON` type and then fails to verify. Normalizing numbers cannot recover a value the
database changed. It is pinned by a spec and documented. It would show up as a false
break, never a false pass.

**Alternatives rejected**: insert the row, read it back, and digest what came back. This is
the most robust option, but the digest is then written by an `UPDATE`, which the
`GRANT INSERT, SELECT` the gem recommends forbids and the read-only model refuses. The other
rejected option was storing a canonical text copy of each entry next to it, which doubles
the ledger and leaves two copies that can disagree.

**Test strategy**: an awkward-value corpus (nested hashes with keys in reverse order,
symbol keys, non-ASCII, 0.1, 1.0, 1e20, very large integers, `true`/`false`/`nil`, empty
hash vs `nil` metadata, Times with nanoseconds), written and verified on all three engines
in CI (SC-002).

## R3. Serializing writers: the chain record and "update first, then read"

**Decision**: a separate one-row table, `reeve_audit_chains`. Each chained write runs inside
the recorder's existing savepoint:

```text
UPDATE reeve_audit_chains SET head_sequence = head_sequence + 1 WHERE name = 'ledger'
SELECT head_sequence, head_digest FROM reeve_audit_chains WHERE name = 'ledger'
-- compute the digest
INSERT INTO reeve_audit_entries (..., chain_sequence, chain_key_id, chain_digest)
UPDATE reeve_audit_chains SET head_digest = ? WHERE name = 'ledger'
```

The first statement is a *write*. On PostgreSQL and MySQL it takes the row lock; on SQLite
it takes the database write lock. Every concurrent writer therefore queues at the same
point, with the same SQL, on all three engines. The insert and both head updates commit or
roll back together, so a rolled-back invocation consumes no sequence number (FR-004, FR-005).

If the chain record does not exist (the `UPDATE` touches 0 rows), the writer creates it with
its genesis, guarded by a unique index on `name`. A writer that loses the creation race
gets a uniqueness error, rolls back its savepoint and retries the update. That retry happens
once, inside the same call.

**Rationale**: `SELECT … FOR UPDATE` is ignored by SQLite. Starting with a read and then
writing on SQLite upgrades a shared lock to a write lock, which SQLite can refuse at once
with `SQLITE_BUSY` instead of waiting. Taking a database-specific advisory lock
(`pg_advisory_xact_lock`, MySQL `GET_LOCK`, which is session-scoped rather than
transaction-scoped) means three code paths. Starting with the write avoids all of it.

**Alternatives rejected**: `MAX(chain_sequence) + 1` from the ledger (a race without a lock,
and a lock on an aggregate is not portable); a database sequence (gaps on rollback by design,
and none on SQLite); per-tool chains (spec decision: one chain).

**Cost, stated** (confidence medium on the size): four statements instead of one per ledger
write, plus one HMAC (microseconds). With the default `Recorder` inside a host transaction,
the chain lock is held until the *host* commits, which serializes every guarded call in the
application behind that transaction. A host transaction that runs two invocations can also
deadlock against another holding the tool's rows. The database detects it and the write
fails under `audit_failure_mode`. Both are documented next to the existing
enclosing-transaction warning, which gains a sentence; `IsolatedRecorder` holds the lock for
the length of one insert. To measure before committing to SC-005: benchmark 0.5.0's ledger
write and the chained write on each engine as the first implementation task.

### Measured (T002, 2026-10-07, before any chain code)

One uncontended `Recorder#record`, 1,000 samples after 100 warm-up writes, on a developer
laptop (Apple Silicon, local databases):

| Engine | Median | p95 |
|---|---|---|
| SQLite | 1.31 ms | 2.91 ms |
| PostgreSQL 18 | 1.60 ms | 2.42 ms |
| PostgreSQL 16 (CI runner) | 1.85 ms | 2.72 ms |
| MySQL 8.4 (CI runner) | 1.45 ms | 2.32 ms |

MySQL could not be measured locally (the Homebrew install does not start, a library
mismatch unrelated to this gem), so it comes from the informational benchmark step in the
CI `database` job, run 37687835913.

**SC-005 stands.** Chaining adds three statements, all on one indexed row, plus an HMAC
measured in microseconds. Against a baseline of about 1.5 ms, 5 ms of headroom is
realistic without being slack. T029 reruns this with chaining on.

**With chaining (T029, same laptop, two runs each):** SQLite median 1.76–1.91 ms (+0.5 ms),
PostgreSQL median 2.46–2.61 ms (+0.9 ms). Well inside SC-005. T054 measures again on all
three engines before release.

## R4. Genesis lives in the chain record (spec amended)

**Decision**: the genesis is link 0, stored on the chain record: `genesis_at`,
`pre_chain_count`, `genesis_key_id`, `genesis_digest = HMAC(tag ‖ genesis_at ‖ pre_chain_count ‖ key_id)`.
Entry 1 links to `genesis_digest`. The genesis columns are written once and are read-only in
the model; tampering with them breaks entry 1 and the genesis digest.

**Rationale**: a genesis *row* in `reeve_audit_entries` needs values for nine NOT NULL
invocation columns it does not have. It would be written by the invocation that happens to
start the chain, giving that invocation two rows. That breaks the "exactly one row per
invocation" guarantee `AuditCoverage` asserts and `Testing::Ledger#entries_after` relies on,
and it would need an exclusion predicate in every query scope. A separate record avoids all
of it, and deleting the record while chained entries exist becomes its own detectable break
(`chain_record_missing`).

## R5. Pre-chain rows and rolling deploys (spec amended)

**Decision**: `pre_chain_count` is recorded at genesis (`COUNT(*) WHERE contract_version < 3`
inside the genesis transaction) and reported by verification beside the current count. A
difference is shown, never judged.

**Unchained contract-3 rows get their own baseline.** A host on `:warn` that ran without a
key before configuring one has contract-3 rows with no digest from before the chain existed.
The genesis records that count as `pre_chain_unchained_count`. Only rows beyond it are
`unchained` breaks. Unlike contract-2 rows, this count is reliable during a rolling deploy:
no older reeve version writes contract 3. Which rows are the new ones is reported by
`occurred_at` after `genesis_at`, and the output says that this is by clock.

**Rationale**: after the migration (nullable columns, so 0.5.0 keeps writing) and during a
rolling deploy, old servers write contract-2 rows after the chain has started. Splitting
those by `occurred_at` against `genesis_at` fails at the boundary: an invocation that started
before the genesis and committed after it is miscounted. Any rule strict enough to call this
tampering would fire on ordinary deploys. Those rows are uncovered whatever happens, and the
report says so.

## R6. Verification algorithm

**Decision**: walk `reeve_audit_entries` in `chain_sequence` order with keyset pagination
(`WHERE (chain_sequence, id) > (?, ?) ORDER BY chain_sequence, id LIMIT 1000`), up to the
head sequence read at the start. Keep only the previous row's recorded digest and the running
counters; collect breaks into a list whose *printed* size can be capped while the totals
cannot.

For each row: if its sequence is not previous + 1, record `missing` (a range) or `duplicate`.
Then recompute its digest using the previous row's *recorded* digest. A mismatch is a
`digest_mismatch`. Linking to the recorded digest, not a recomputed one, means one edited
row produces one break rather than a cascade to the end of the ledger. An unknown key id
counts as `unverifiable`, and the walk continues trusting that row's recorded digest for
the next link.

At the end: compare the last row with the head (`head_mismatch`) and verify the genesis
digest (`genesis_altered`). Then **re-read the head** and look for chained rows above it
(`beyond_head`). Rows between the two head reads are legitimate writes that committed during
the walk. A row above the second read cannot be: an entry and its head move commit together,
so reeve never leaves a committed row past a committed head. Without this second read, a row
forged past the head would never be examined, by this run or any later one. Such a row also
takes the sequence number the next legitimate write needs, so that write fails on the unique
index. Both signals are reported, not hidden. Count contract-3 rows with no digest (`unchained`) and contract
1–2 rows (`uncovered`) with two `COUNT(*)` queries.

**Rationale**: memory stays flat whatever the ledger size (FR-015, SC-004). Short batched
reads keep no long transaction open and block no writers. Reading the head first and
stopping there is consistent because a head value is only visible once the transaction that
wrote row *n* has committed.

**Why "digest mismatch" is one kind**: swapping the sequence numbers of two rows, editing a
row, and inserting a forged row all show up as a failing digest at that position. Telling
them apart would mean searching for where a row would verify, and the report would still be
guessing. The output says what is known: this position does not verify, and the content,
the position or the predecessor changed.

## R7. Keys and key identifiers

**Decision**: two settings, validated when assigned like every other setting:
`config.ledger_key` (the signing secret, ≥ 32 bytes) and `config.retired_ledger_keys` (an
array, verification only). A key's identifier is a fingerprint the gem derives from the key,
the first 16 hex characters of `HMAC-SHA256(key, "reeve-ledger-key-id")`, so the host never
names a key and an identifier can never be pinned to the wrong secret. The secret appears in
no `inspect`, `to_h`, log line or error message; `Configuration#to_h` shows the fingerprint.

The generated initializer:

```ruby
config.ledger_key = Rails.application.key_generator.generate_key("reeve audit ledger", 32)
# Or a dedicated key, so rotating secret_key_base does not rotate the ledger's:
# config.ledger_key = Rails.application.credentials.reeve_ledger_key
```

**Rationale**: deriving from `secret_key_base` keeps the key outside the database in every
environment, including the test environment, where Rails supplies a fixed one. Adoption
stays at three steps with no new secret to provision (Constitution VI). Someone who
already has `secret_key_base` can forge sessions anyway, so the threat model is unchanged.

**Cost, stated**: rotating `secret_key_base` rotates the ledger key. The derived old key
must go into `retired_ledger_keys`, or older entries report as unverifiable. They would not
report as tampered, but that still costs the guarantee for them. The upgrade output and
README say this at the place where the line is added.

**Alternatives rejected**: host-named key IDs (one more thing to get wrong, and a renamed ID
silently orphans history); requiring a dedicated secret (an extra provisioning step in every
environment, including CI, for no gain in the threat model).

## R8. Missing key and the failure modes

**Decision**: the recorder asks for the key at write time.
- `:fail` → raises `Reeve::LedgerKeyError` (a new `Reeve::Error`). The envelope's existing
  `handle_write_failure` wraps it in `AuditWriteError`, so the caller sees the same error
  class as any other ledger failure, with a message that names the setting and the
  initializer line.
- `:warn` → writes the row at contract 3 with the three chain columns NULL, takes no chain
  lock, and logs a warning on every such write. Verification reports it as `unchained`.

A table missing the contract-3 columns raises `Reeve::ConfigurationError` naming
`rails g reeve:upgrade`, instead of ActiveRecord's `UnknownAttributeError`. The check runs
once per process; the column list is cached.

## R9. Rake task without breaking `require "reeve"`

**Decision**: `lib/reeve/railtie.rb`, required from `lib/reeve.rb` only when
`Rails::Railtie` is defined, registers the tasks from `lib/reeve/tasks.rb`, a Ruby file
using the Rake DSL. Exit statuses: `0` intact, `1` broken, `2` could not verify.
Environment options: `LIMIT=` (printed breaks, default 100; totals are always complete) and
`FORMAT=json`.

**Rationale**: a `.rake` file would not ship. `reeve.gemspec` packages `lib/**/*.rb` and
`lib/**/*.tt` only, so a task file would pass every spec in the working tree and be missing
from the gem users install. Keeping the task in a `.rb` file avoids it, and a packaging spec
asserts the task's file is inside the built gem.

## R10. Testing-kit check: `LedgerChain`

**Decision**: a new `GLOBAL` check. It invokes the first compliance tool once per fixture
principal, so it has entries of its own to examine even under transactional fixtures,
where the ledger is empty at the start of every example. It then verifies the whole ledger
as the database shows it to that example.

- `intact` with at least one chained entry → passed, message states the range;
- `broken` or any `unchained` entry → failed, message lists the breaks;
- `unverifiable`, or no key configured → failed: the run writes and signs its own entries,
  so a missing or unusable key is a configuration error, not an absence;
- nothing it can write or examine (no compliance tools, ledger not loaded) → skipped, with a
  message saying the chain was not verified.

It verifies the whole ledger visible to the example, not only its own entries. That is the
stronger claim, and on a test database that is not reset between runs it surfaces a break
left by an earlier run instead of hiding it.

It reaches the verifier through `Testing::Ledger` (a new `#verify_chain`), so the kit still
loads with no ActiveRecord (isolation_spec). Both front-ends pick it up from `Checks::ALL`
with no front-end code (FR-018, parity_spec).

## R11. Custom recorders (FR-007)

**Decision**: the chaining step is public: `Reeve::Audit::Chain.new(entry_class:).append!(row)`
takes a normalized row hash and performs R3 on the entry class's connection. `Recorder` is
its first caller. A host recorder that writes to reeve's table calls the same method. One
that does not produces `unchained` rows, which verification reports.

## R12. Schema changes and the upgrade step

**Decision**: contract 3 adds to `reeve_audit_entries` three nullable columns:
`chain_sequence` (bigint), `chain_key_id` (string, 16), `chain_digest` (string, 64). It adds
a unique index on `chain_sequence`, since NULLs are distinct on all three engines, and that
index also orders the verification walk. It creates `reeve_audit_chains`.

`UpgradeGenerator::STEPS` gains a contract-3 step whose `adds:` names the three columns;
the step's applied-check also requires the table. `reeve:install` creates both directly.
`ContractVersion::COLUMNS` and `EXPECTED_VERSION` move by hand, as that file requires.

**Large-ledger note** in the upgrade output: the unique index build scans the table.
PostgreSQL hosts with very large ledgers can switch the generated migration to
`algorithm: :concurrently`; MySQL 8 adds nullable columns instantly.

**Grants**: the recommended `GRANT INSERT, SELECT` on the ledger is unchanged. The chain
table needs `INSERT, SELECT, UPDATE`. The migration comment says so, and says plainly that a
role holding `UPDATE` there can rewind the head, which is "Not detected" item 2.

## R13. Positioning check (Constitution IV)

The Ruby audit gems (`audited`, `paper_trail`, `simple_audit_trail`) record model change
history; none chains entries with a keyed digest. The hash-chained audit logs that do exist
are in other ecosystems: the `auditchain` package (Python, HMAC-SHA256 with a seal key), the
`audit-trail` crate (Rust), and R's `regulog`. None is something reeve could build on, and
reeve's ledger is its own table, so this is not re-solving an upstream feature. The design
is public prior art: hash-chained secure audit logs predate all of these.
