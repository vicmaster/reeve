# Contract: Configuration

**Stability**: public. Additive changes only within a major version.

```ruby
Reeve.configure do |config|
  # REQUIRED. Returns the human the agent acts for, or nil to deny.
  # Receives a Reeve::Context. Raising is treated as nil (fail closed).
  config.principal_resolver = ->(context) { User.find_by(id: context.metadata[:user_id]) }

  # Pre-existing tools with no guard_with declaration. FR-023.
  # :deny (default) | :allow_with_warning
  config.unguarded_tools = :deny

  # Ledger write failure behavior. FR-012.
  # :fail (default — the invocation fails) | :warn (log and continue; opt-in only)
  config.audit_failure_mode = :fail

  # Argument names redacted in every ledger entry, recursively. FR-011.
  config.redact_arguments = %i[password token secret ssn]

  # Cap on recorded record identifiers before truncation. FR-014.
  config.max_recorded_ids = 1000

  # Policy adapter. :auto detects Pundit, else falls back to plain objects.
  # :auto (default) | :pundit | :plain | <object responding to authorize/scope>
  config.policy_adapter = :auto

  # Default policy action checked when a tool does not override it.
  config.default_action = :index

  # Where entries are written. Swappable for a non-ActiveRecord ledger;
  # must respond to #record(entry_attributes) and raise on failure.
  # Defaults to nil, which resolves to Reeve::Audit::Recorder at invocation time —
  # the default cannot be the constant itself, since the core loads without ActiveRecord.
  config.audit_recorder = Reeve::Audit::Recorder

  # Optional sink for warnings (unguarded tools, degraded audit mode).
  config.logger = Rails.logger

  # Test-environment only: two fixture principals with disjoint records, the sole host
  # setup the compliance suite needs (contracts/testing-kit.md). A callable, because in a
  # Rails test suite the fixtures do not exist when the helper is loaded.
  config.compliance_principals = -> { [users(:alice), users(:bob)] }
end
```

## Guarantees

- Reading `Reeve.config` before `configure` returns defaults; the library is
  usable with zero configuration except that **every** call denies with `no_principal`
  until `principal_resolver` is set. Failing loudly at first invocation, not at boot, keeps
  the library loadable in contexts that never invoke a tool (SC-008).
- `configure` may be called more than once; later calls override individual settings.
- Unknown setting names raise `NoMethodError` at configure time, not silently no-op.
- Every setting is readable at runtime (`config.unguarded_tools`) for the compliance suite
  to assert against.
- `audit_recorder` has two built-in values. `Reeve::Audit::Recorder` (the default) writes
  in a savepoint on the host's connection: the trace survives a rollback by the *tool*,
  and it warns when it detects a transaction the *host* wrapped around the invocation,
  which it cannot survive. `Reeve::Audit::IsolatedRecorder` writes the same rows on a
  connection of its own, which no rollback on the host's connection can reach; it requires
  a database with concurrent writers and raises `ConfigurationError` on SQLite, where an
  open transaction holds the write lock. `IsolatedRecorder.available?` answers whether it
  can be used here, so a host can branch in an initializer.
- A custom `audit_recorder` receives the same attributes the built-in one does and owns
  what it writes. If it writes to `Reeve::Audit::Entry`, it must set `contract_version`
  from `Reeve::Audit::CONTRACT_VERSION` — the model rejects a row that does not name its
  own shape (contract 2). It is also responsible for redaction: the attributes reach a
  recorder unredacted, which is what makes `Checks::RedactionHolds` a real check rather
  than a formality.

## Validation

| Setting | Rejected values | Behavior |
|---------|-----------------|----------|
| `unguarded_tools` | anything but the two symbols | `ArgumentError` at assignment |
| `audit_failure_mode` | anything but the two symbols | `ArgumentError` at assignment |
| `max_recorded_ids` | `< 1`, non-integer | `ArgumentError` at assignment |
| `principal_resolver` | non-callable | `ArgumentError` at assignment |
| `policy_adapter` | symbol other than the three, or object missing `authorize`/`scope` | `ArgumentError` at assignment |
