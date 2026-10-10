# Quickstart: Tamper-Evident Audit Ledger

This is the walkthrough the README section and the CHANGELOG entry are written from. Every
command here is run against `spec/dummy` before the release (the existing
`quickstart_spec.rb` pattern).

## New install

```text
bundle add reeve
bin/rails generate reeve:install
bin/rails db:migrate
```

The generated initializer already contains:

```ruby
config.ledger_key = Rails.application.key_generator.generate_key("reeve audit ledger", 32)
```

The first guarded call starts the chain. Nothing else to do.

## Upgrading from 0.5.0

```text
bundle update reeve
bin/rails generate reeve:upgrade
bin/rails db:migrate
```

`reeve:upgrade` prints one line to add to `config/initializers/reeve.rb`, the `ledger_key`
line above. Until it is there, guarded calls fail with an error that names that line
(`audit_failure_mode = :fail`, the default).

Existing rows are not touched. They are reported as "not covered" from now on: they are
exactly as trustworthy as they were yesterday, and no more.

**Rolling deploys** are fine: servers still on 0.5.0 keep writing uncovered rows until they
are replaced. Verification counts them and does not call them tampering.

## Check it

```text
bin/rails reeve:verify_ledger
```

```text
reeve ledger: INTACT — sequences 1–312 verified (head at start: 312); 5,000 earlier entries not covered (5,000 when the chain started)
```

Exit status 0 intact, 1 broken, 2 could not verify. Use it in a scheduled job and alert on
anything but 0.

In CI, the compliance suite you already run now includes `LedgerChain`. No new test code.

## What this protects against, and what it does not

**Detected**: a chained entry edited, removed, reordered or inserted by someone with database
access but not the key; the newest entries removed while the chain record was left alone;
the chain record removed while chained entries remain.

**Not detected**:
- someone who has the key: by default that is anyone with `secret_key_base`;
- someone who deletes the newest entries *and* rewinds the chain record;
- deletion of the whole ledger (reported as "no chain", never as a pass);
- anything about entries written before the upgrade.

This feature *detects* changes. It does not prevent them; the database grant in the
migration comment is what prevents.

## Rotating the key

```ruby
config.ledger_key          = new_key
config.retired_ledger_keys = [old_key]   # keep for as long as you need to verify old entries
```

If the key is derived from `secret_key_base`, rotating `secret_key_base` rotates it. Put the
old derived key in `retired_ledger_keys`, or entries signed with it become *unverifiable*.
Verification does not report them as tampered, but they lose the guarantee. Existing entries
are never re-signed.
