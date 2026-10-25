# Contract: Ledger Retention

## Configuration

```ruby
# app/models/ledger_retention_record.rb
class LedgerRetentionRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :ledger_retention }   # same database, a role with DELETE
end

# config/initializers/reeve.rb, after require "reeve/audit"
Reeve.config.ledger_retention_connection = LedgerRetentionRecord
```

Any class responding to `connection_pool` and `connection_db_config`. The purge refuses when it
reaches another database than the ledger's, or, on PostgreSQL and MySQL, the same username as the
application's own connection. On SQLite it warns that roles cannot be told apart, and proceeds.

## Rake

```
bin/rails reeve:purge_ledger THROUGH=6000 ARCHIVE=/mnt/archive/ledger-1.jsonl          # dry run
bin/rails reeve:purge_ledger OLDER_THAN=365d ARCHIVE=/mnt/archive/ledger-1.jsonl CONFIRM=1
bin/rails reeve:purge_ledger THROUGH=6000 NO_ARCHIVE=1 CONFIRM=1
bin/rails reeve:verify_archive ARCHIVE=/mnt/archive/ledger-1.jsonl
```

Exactly one of `THROUGH` (a whole number) and `OLDER_THAN` (`<N>d`), and exactly one of `ARCHIVE`
and `NO_ARCHIVE=1`. `CONFIRM` accepts `1` only. Anything else is an `ArgumentError` naming the
accepted values.

Ruby: `Reeve::Tasks.purge_ledger(env:, out:)`, `Reeve::Tasks.verify_archive(env:, out:)`.
Library: `Reeve::Audit::Chain.purge!(through: nil, older_than: nil, archive: nil, confirm: false)`
→ `PurgeResult`; `Reeve::Audit::Chain.verify_archive(path, keys: nil)` → `Verification`.

### purge_ledger output

```
reeve ledger purge: WOULD PURGE — sequences 1–6,000 through checkpoint #6,000 (2025-10-01 14:00 UTC): 6,000 chained entries and 5,000 pre-chain rows; archive to /mnt/archive/ledger-1.jsonl; run again with CONFIRM=1
reeve ledger purge: PURGED — sequences 1–6,000 through checkpoint #6,000 (2025-10-01 14:00 UTC): 6,000 chained entries and 5,000 pre-chain rows; retention record 0; archive /mnt/archive/ledger-1.jsonl (sha256 3e1c…)
reeve ledger purge: PURGED — … ; retention record 1; no archive written (NO_ARCHIVE=1)
reeve ledger purge: NOTHING TO PURGE — no checkpoint older than 365 days above the current boundary (#6,000)
reeve ledger purge: REFUSED — <reason naming the fix>; nothing was removed
```

Exit: 0 for WOULD PURGE, PURGED and NOTHING TO PURGE; 1 for REFUSED. Warnings follow on lines
prefixed `warning: `.

Refusal reasons: no ledger key; no anchor (`config.ledger_anchor`); no retention connection
(`config.ledger_retention_connection`), another database, or the application's own role; no
checkpoint at `THROUGH`, naming the nearest below and above; the ledger does not verify INTACT
(its summary line follows); the boundary checkpoint does not check; neither `ARCHIVE` nor
`NO_ARCHIVE=1`; the archive path exists or cannot be written; another purge is running.

A rerun after an interruption, with the same boundary, prints `PURGED — … (resumed; N rows
removed this run)`.

## Verification

Break kind added: `retention_altered` (BROKEN, exit 1). A record signed by a key not configured:
`unknown_key` (UNVERIFIABLE, exit 2). Checkpoint status added: `purged`.

Every summary line that follows a walk carries the purge clause after the coverage:

```
reeve ledger: INTACT — sequences 6,001–10,000 verified (head at start: 10,000); 1–6,000 purged (retention record 0, 2025-11-01); 0 earlier entries not covered (5,000 when the chain started, 5,000 purged); anchored at #10,000 (checkpoint 2026-10-25 14:00 UTC), 0 entries after it
```

With rows awaiting purge, `; 120 entries awaiting purge` follows the purge clause. JSON gains
`retention` and `awaiting_purge`; checkpoint results may have status `purged`; existing keys are
unchanged.
