# Contract: Policy Adapter

**Stability**: public. Two methods. Hosts may supply their own adapter object.

```ruby
# Any object satisfying this protocol may be assigned to config.policy_adapter.
class MyAdapter
  # Returns MCP::Guardrails::Decision. Must never raise for an ordinary denial —
  # raising is treated as policy_error and fails closed.
  def authorize(principal:, policy:, action:, record: nil) = Decision.allow(rule: "...")

  # Returns a scoped relation for this principal. Must not return nil.
  def scope(principal:, policy:, relation:) = relation.where(...)
end
```

## Required semantics

- `authorize` decides whether the principal may invoke the action at all. A `Decision`
  must carry a `rule` string identifying what decided (FR-006, FR-009).
- `scope` narrows a relation to what the principal may see. Returning the relation
  unchanged is a valid answer only if the policy genuinely permits everything —
  adapters must not use it as a "don't know" fallback.
- Neither method may mutate the principal, the policy, or the relation.
- An exception from either is caught by the envelope, converted to a deny with rule
  `policy_error`, recorded, and re-raised as `DeniedError` with the original as `cause`.
  Exceptions are never swallowed (Constitution I).

## Built-in adapters

### `:plain` — always available

Calls `policy.authorize(principal, action, record)` and `policy.scope(principal, relation)`
on whatever object was passed to `guard_with`. Accepts a truthy/falsy return from
`authorize` and wraps it in a `Decision` with rule `"#{policy.class}##{action}"`. Missing
methods are a configuration error raised at declaration time, not at invocation time —
the developer learns immediately.

### `:pundit` — loaded only when `defined?(Pundit)`

- `authorize` → `policy_class.new(principal, record_or_class).public_send("#{action}?")`,
  rule `"InvoicePolicy#index?"`.
- `scope` → `policy_class::Scope.new(principal, relation).resolve`, rule
  `"InvoicePolicy::Scope"`.
- A policy class with no matching `Scope` is a declaration-time error.
- Pundit is a development dependency of this gem, never a runtime one (Constitution IV).

### `:auto` — the default

Uses `:pundit` when Pundit is defined **and** the declared policy answers to Pundit's
conventions; otherwise `:plain`. The chosen adapter is reported by
`MCP::Guardrails.config.resolved_policy_adapter` so the compliance suite can assert on it
and so the choice is never a mystery.
