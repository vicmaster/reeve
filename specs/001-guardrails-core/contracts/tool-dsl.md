# Contract: Tool DSL

**Stability**: public. The whole tool-side surface is three macros.

```ruby
class InvoiceSearchTool < FastMcp::Tool   # or any class including Reeve::Guard
  include Reeve::Guard          # implicit in the fast-mcp adapter

  guard_with InvoicePolicy                # required — absence means deny (FR-002, FR-004)
  guard_with InvoicePolicy, action: :read # optional action override

  redact :customer_ssn                    # per-tool redaction, merged with global (FR-011)

  def call(query:)
    Invoice.where("number LIKE ?", "%#{query}%")   # returns a relation — scoped automatically
  end
end
```

For anything that is not a record — a count, a sum, a summary string — ask for the scoped
relation instead of returning one:

```ruby
def call(**)
  scoped(Invoice).where(overdue: true).count      # safe by construction
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

## `scoped(model_or_relation)` — instance method, not a macro

- Returns the relation narrowed to what the invoking principal may see, via the tool's
  declared policy. Available inside `call`.
- **This is how a guarded tool returns anything that is not a record.** Counts, sums,
  grouped summaries, and rendered strings are all safe when computed from `scoped(...)`,
  because the tool never held unscoped data.
- The envelope tracks whether `scoped` was used during the invocation. A guarded tool that
  returns a non-record value **without** having called `scoped` is denied with
  `unscoped_derived_result` — the tool had unscoped data in hand and we cannot prove what
  it did with it.
- `scoped` on a model with no policy for that type denies with `unknown_record_type`.
- Resulting ledger entry: `derived: true`, `record_ids: []`, and `record_count` set to the
  size of the scoped source when countable.

*Design note*: this replaces an earlier `derives_from :invoices` declaration. Asking the
developer for the scoped relation is strictly better than asking them to promise they used
one — it is enforceable by construction, it removes a macro from the public surface, and it
guides toward the safe path instead of documenting it.

## Return-value handling

| What `call` returns | Envelope behavior |
|---------------------|-------------------|
| ActiveRecord::Relation | Merged with the policy scope before execution; scoped relation is returned |
| Array of records | Each re-checked against the scope; out-of-scope entries removed |
| A single record | Denied with `out_of_scope_record` if not in scope — never returned. See the existence-disclosure note below |
| Mixed record types | Each type scoped by its own policy; an unpoliced type denies the whole call |
| Anything else (count, sum, string, hash) | Allowed only if `scoped(...)` was used during the call; otherwise denied with `unscoped_derived_result` |
| `nil` / empty | Allowed, recorded with `record_count: 0` — distinct from a denial |

## Fetching one record by identifier (FR-006, corrected 2026-08-11)

An earlier version of this contract said an out-of-scope record is "never differentiated
from not found". That is true of the **error text**, and it is true end-to-end only when
the tool fetches through `scoped`:

```ruby
def call(id:)
  scoped(Invoice).find_by(id: id)    # nil whether it is missing or simply not yours
end
```

Fetching from the unscoped model leaves an existence oracle that the envelope cannot
close: `Invoice.find_by(id:)` returns `nil` for a record that does not exist, and raises
`DeniedError` for one that exists and belongs to someone else. By the time the envelope
sees a `nil` it cannot know whether the tool meant a lookup or an empty collection, so it
cannot make the two answers identical.

Both behaviours are pinned by specs in `spec/reeve/edge_cases_spec.rb`. The denial is
still the right outcome for the unscoped case — it is loud, audited, and names the rule —
but a tool that must not disclose existence has to use `scoped`.

## Errors

`Reeve::DeniedError` carries `#tool_name`, `#principal_id`, `#rule`, and
`#detail`. Its message names all four (FR-006, Constitution VI) and never reveals whether
an out-of-scope record exists.
