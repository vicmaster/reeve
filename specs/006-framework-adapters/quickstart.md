# Quickstart: Framework Adapters

Assumes `bundle add reeve`, `rails g reeve:install` and `db:migrate` are done.

## Official SDK

```ruby
# config/initializers/reeve.rb
require "reeve/mcp"

Reeve.configure do |config|
  config.principal_resolver = ->(context) { context.request[:server_context]&.dig(:user) }
end
```

```ruby
class InvoiceSearchTool < MCP::Tool
  guard_with InvoicePolicy

  def self.call(query:)
    numbers = scoped(Invoice).where("number LIKE ?", "%#{query}%").pluck(:number)
    MCP::Tool::Response.new([{ type: "text", text: numbers.join("\n") }])
  end
end

server = MCP::Server.new(name: "app", tools: [InvoiceSearchTool],
                         server_context: { user: current_user })
```

Check it: call `tools/call` as two users; each sees only their invoices, and
`Reeve::Audit::Entry.last` names the user and rule. Replace `scoped(Invoice)` with `Invoice`
and the call is refused `unscoped_derived_result`.

## ActionMCP

```ruby
# config/initializers/reeve.rb
require "reeve/action_mcp"

Reeve.configure do |config|
  config.principal_resolver = ->(_context) { ActionMCP::Current.user }
end
```

```ruby
class InvoiceSearchTool < ApplicationMCPTool
  property :query, type: "string", required: true
  guard_with InvoicePolicy

  def perform
    scoped(Invoice).where("number LIKE ?", "%#{query}%").each { |i| render(text: i.number) }
  end
end
```

## In CI, either library

```ruby
RSpec.describe InvoiceSearchTool do
  it { is_expected.to deny_access_for(stranger).with(query: "AC") }
  it { is_expected.to audit_every_call }
end
```

## What to know before deploying

- On these two libraries Reeve allows or refuses a tool's output; it does not narrow it.
  Read through `scoped(...)`, and `authorize!` anything fetched another way.
- Requiring an adapter under the default `:deny` refuses every tool of that library that has
  no `guard_with`, on its next call. Use `:allow_with_warning` while adopting.
