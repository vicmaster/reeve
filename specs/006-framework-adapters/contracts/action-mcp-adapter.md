# Contract: ActionMCP Adapter

```ruby
require "reeve/action_mcp"
```

Supported: `actionmcp >= 0.200.0, < 0.204` (Rails 8.1, Ruby 3.2+). Outside the range:
`Reeve::ConfigurationError` naming it. The ceiling moves with each verified ActionMCP release.

## Tools

```ruby
class InvoiceSearchTool < ApplicationMCPTool
  property :query, type: "string", required: true

  guard_with InvoicePolicy

  def perform
    scoped(Invoice).where("number LIKE ?", "%#{query}%").each do |invoice|
      render(text: invoice.number)
    end
  end
end
```

- `guard_with`, `redact` are class methods; `scoped`, `authorize!` are instance methods,
  callable from `perform`.
- Classes marked `abstract!` (such as `ApplicationMCPTool`) are not tools to the compliance
  suite.
- Content rendered before the call is allowed is held, and discarded on denial.

## Principal

```ruby
config.principal_resolver = ->(_context) { ActionMCP::Current.user }
```

The adapter does not set a principal. Background-task calls (`ToolExecutionJob`) have no
`Current.user`; they are denied `no_principal` unless the resolver identifies the user from
`context.request[:session]`.

## What the client receives

| Outcome | Response |
|---|---|
| allowed | the content and structured content the tool rendered |
| denied | tool error, text = denial message |
| tool raised | ActionMCP's own error message, as without Reeve |
| `before_perform` halted, invalid input | as without Reeve; no ledger row (the tool never ran) |

## Testing kit

As for the SDK: tool classes go to the kit directly, one row per call.
