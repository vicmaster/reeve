# Contract: Request Data (core)

Additive. Every 0.9.0 call keeps working unchanged.

```ruby
Reeve.invoke(tool:, arguments: {}, principal: :unset, agent: nil, metadata: {}, request: {})
inventory.dispatch(name, arguments: {}, principal: :unset, agent: nil, metadata: {}, request: {})

context.request   # => Hash, read-only, inside the principal resolver
```

| | `metadata:` | `request:` |
|---|---|---|
| Purpose | which request a row came from | what the resolver needs to identify the human |
| Recorded | yes, redacted | never |
| Visible to the resolver | yes | yes |
| After the call | kept on the row | cleared |

Resolver examples:

```ruby
# Official SDK with its OAuth middleware
config.principal_resolver = ->(context) {
  token = context.request[:auth_info]
  token && User.find_by(id: token.subject)
}

# Official SDK, server built per request with the user in server_context
config.principal_resolver = ->(context) { context.request[:server_context]&.dig(:user) }

# ActionMCP
config.principal_resolver = ->(_context) { ActionMCP::Current.user }
```

Rule for adapter authors (and hosts writing their own dispatcher): anything that can hold a
credential, a user object or arbitrary client input goes in `request:`. Only attribution goes
in `metadata:`.
