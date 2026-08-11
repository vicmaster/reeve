# Contract: Tool DSL

**Stability**: public. The whole tool-side surface is three macros.

```ruby
class InvoiceSearchTool < FastMcp::Tool   # or any class including MCP::Guardrails::Guard
  include MCP::Guardrails::Guard          # implicit in the fast-mcp adapter

  guard_with InvoicePolicy                # required — absence means deny (FR-002, FR-004)
  guard_with InvoicePolicy, action: :read # optional action override

  redact :customer_ssn                    # per-tool redaction, merged with global (FR-011)

  derives_from :invoices                  # only for aggregate returns (R4)

  def call(query:)
    Invoice.where("number LIKE ?", "%#{query}%")   # returns a relation — scoped automatically
  end
end
```

## `guard_with(policy, action: config.default_action)`

- Registers a `GuardDeclaration` for this tool class in the registry at class-definition
  time. The compliance suite and `audit_every_call` enumerate that registry.
- `policy` is a class or object resolved through the configured policy adapter. It is
  **not** required to be a Pundit policy.
- Declared once per class. A second call replaces the first and emits a warning.
- Subclasses inherit their parent's declaration and may override it.
- **Absence is not neutral**: invoking a tool with no declaration through the envelope
  denies with `no_guard_declared`, unless `config.unguarded_tools == :allow_with_warning`,
  in which case it allows and records `guard: "none"`.

## `redact(*argument_names)`

- Names are redacted in the ledger entry for this tool, in addition to
  `config.redact_arguments`. Recursive into nested hashes. Argument names always survive;
  only values are replaced.

## `derives_from(source)`

- Declares that this tool returns a computed value (count, sum, string, hash) derived from
  the named scoped source rather than records.
- Required for any non-record return from a guarded tool. Without it, the envelope denies
  with `undeclared_derived_result` (R4) — a guarded tool cannot quietly return an
  unscoped aggregate.
- The resulting ledger entry has `derived: true`, `record_ids: []`, and `record_count`
  set to the size of the scoped source when it is countable.

## Return-value handling

| What `call` returns | Envelope behavior |
|---------------------|-------------------|
| ActiveRecord::Relation | Merged with the policy scope before execution; scoped relation is returned |
| Array of records | Each re-checked against the scope; out-of-scope entries removed |
| A single record | Denied with `out_of_scope_record` if not in scope — never returned, never differentiated from "not found" (FR-006) |
| Mixed record types | Each type scoped by its own policy; an unpoliced type denies the whole call |
| Anything else | Requires `derives_from`; otherwise denied |
| `nil` / empty | Allowed, recorded with `record_count: 0` — distinct from a denial |

## Errors

`MCP::Guardrails::DeniedError` carries `#tool_name`, `#principal_id`, `#rule`, and
`#detail`. Its message names all four (FR-006, Constitution VI) and never reveals whether
an out-of-scope record exists.
