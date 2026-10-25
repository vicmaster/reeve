# Quickstart: purging old ledger entries

Needs an anchor (specs/004) and a checkpoint schedule. Once, after upgrading reeve:

```bash
bin/rails generate reeve:upgrade && bin/rails db:migrate   # adds reeve_audit_retentions
```

Create a database role with `SELECT` on the four ledger tables, `DELETE` on
`reeve_audit_entries` and `INSERT` on `reeve_audit_retentions`; grant the application's role
`SELECT` on `reeve_audit_retentions`. Point reeve at the role:

```ruby
Reeve.config.ledger_retention_connection = LedgerRetentionRecord   # see contracts/retention.md
```

Then, monthly:

```bash
bin/rails reeve:purge_ledger OLDER_THAN=365d ARCHIVE=/mnt/archive/ledger-$(date +%F).jsonl            # dry run
bin/rails reeve:purge_ledger OLDER_THAN=365d ARCHIVE=/mnt/archive/ledger-$(date +%F).jsonl CONFIRM=1
bin/rails reeve:verify_ledger     # INTACT …; 1–N purged (retention record …)
```

Keep archives where they cannot be changed, and the keys that signed them for as long as they
must verify: `bin/rails reeve:verify_archive ARCHIVE=path`.
