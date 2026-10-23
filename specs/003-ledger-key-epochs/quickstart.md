# Quickstart: rotating the ledger key

```bash
bin/rails generate reeve:upgrade && bin/rails db:migrate   # once, from 0.6.0
```

```ruby
# config/initializers/reeve.rb — order matters: ledger_key first
config.ledger_key = NEW_KEY
config.retired_ledger_keys = [OLD_KEY]
```

Deploy everywhere, then:

```bash
bin/rails reeve:rotate_ledger_key   # ROTATED (or CURRENT if a write already opened the epoch)
bin/rails reeve:verify_ledger       # INTACT, epochs 0 and 1 listed
```

Keep `OLD_KEY` in `retired_ledger_keys` for as long as entries it signed must verify.
