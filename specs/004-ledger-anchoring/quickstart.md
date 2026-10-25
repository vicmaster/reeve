# Quickstart: anchoring the ledger

Point the anchor at storage the database's users cannot change or delete, for example a mount
backed by an object-locked bucket. A file on the database host protects nothing.

```ruby
# config/initializers/reeve.rb, one anchor per environment
config.ledger_anchor = Reeve::Audit::FileAnchor.new("/mnt/ledger-anchor/#{Rails.env}.checkpoints")
```

Schedule a checkpoint (hourly, say) and keep verifying as before:

```bash
bin/rails reeve:checkpoint_ledger   # MADE — head #…, published to the anchor
bin/rails reeve:verify_ledger       # INTACT — …; anchored at #…, N entries after it
```

Entries after the latest checkpoint can still be removed without trace; the number on the summary
line says how many there are. Restoring a backup older than a checkpoint reads as BROKEN, because
the restored ledger lost entries that checkpoint saw.
