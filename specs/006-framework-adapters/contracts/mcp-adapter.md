# Contract: Official SDK Adapter

```ruby
require "reeve/mcp"
```

Supported: `mcp >= 1.0, < 2.0`, every Ruby the SDK and Reeve both support. Outside the range:
`Reeve::ConfigurationError` naming it. Library missing: `Reeve::ConfigurationError` naming
the gem and pointing to `Reeve.invoke`.

## Class tools

```ruby
class InvoiceSearchTool < MCP::Tool
  tool_name "invoice_search"
  input_schema(properties: { query: { type: "string" } }, required: ["query"])

  guard_with InvoicePolicy
  redact :customer_ssn

  def self.call(query:, server_context:)
    invoices = scoped(Invoice).where("number LIKE ?", "%#{query}%")
    MCP::Tool::Response.new([{ type: "text", text: invoices.pluck(:number).join("\n") }])
  end
end
```

- `guard_with`, `redact`, `scoped`, `authorize!` are class methods on every `MCP::Tool`
  subclass.
- `server_context:` is optional; a tool gets it only if it declares it, as without Reeve.
- Output without `scoped(...)` in the same call: denied `unscoped_derived_result`.

## Block tools

```ruby
server.define_tool(name: "list_invoices") do |server_context:|
  MCP::Tool::Response.new([{ type: "text", text: scoped(Invoice).pluck(:number).join("\n") }])
end
server.tools["list_invoices"].guard_with InvoicePolicy
```

Unguarded block tools are denied under `:deny`, like unguarded class tools.

## What the client receives

| Outcome | Response |
|---|---|
| allowed | the tool's own `Response` |
| denied | `{ content: [{ type: "text", text: "<denial message>" }], isError: true }` |
| tool raised | the SDK's JSON-RPC internal error, as without Reeve |

## Testing kit

`Reeve::Checks.run_all`, `deny_access_for`, `audit_every_call` and the Minitest assertions
take SDK tool classes directly. No `invoke:` needed. One ledger row per call.
