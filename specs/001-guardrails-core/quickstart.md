# Quickstart: mcp-guardrails

The whole adoption path, end to end. Target: under 15 minutes from an existing MCP server
to a guarded, audited, test-asserted tool (SC-004).

## 1. Install

```bash
bundle add mcp-guardrails
bin/rails generate mcp_guardrails:install
bin/rails db:migrate
```

The generator creates two files:

- `config/initializers/mcp_guardrails.rb` — with `principal_resolver` left as a TODO you
  must fill in, and `unguarded_tools` written explicitly with both options shown (FR-023).
- `db/migrate/xxxx_create_mcp_guardrails_audit_entries.rb` — the ledger table.

## 2. Say who the agent acts for

```ruby
# config/initializers/mcp_guardrails.rb
MCP::Guardrails.configure do |config|
  config.principal_resolver = ->(context) { User.find_by(id: context.metadata[:user_id]) }
  config.unguarded_tools    = :deny        # :deny (default) | :allow_with_warning
  config.redact_arguments   = %i[password token ssn]
end
```

Until this resolver is set, every guarded call denies with `no_principal`. That is the
intended behavior — the library fails closed before it is configured.

## 3. Guard a tool

```ruby
class InvoiceSearchTool < FastMcp::Tool
  guard_with InvoicePolicy          # ← the only line you add

  description "Search invoices"
  arguments { required(:query).filled(:string) }

  def call(query:)
    Invoice.where("number LIKE ?", "%#{query}%")
  end
end
```

The tool body does not change (SC-005). The relation it returns is merged with
`InvoicePolicy::Scope` for the invoking principal before it ever executes.

## 4. Prove it in CI

```ruby
# spec/spec_helper.rb
require "mcp/guardrails/rspec"
RSpec.configure { |c| c.include MCP::Guardrails::Testing::Matchers }

# spec/tools/invoice_search_tool_spec.rb
RSpec.describe InvoiceSearchTool do
  let(:owner)    { create(:user) }
  let(:stranger) { create(:user) }
  before { create(:invoice, owner: owner, number: "AC-1") }

  it { is_expected.to deny_access_for(stranger).with(query: "AC") }
  it { is_expected.to audit_every_call }
end

# spec/compliance_spec.rb — checks every guarded tool at once
RSpec.describe "MCP guardrails compliance" do
  it_behaves_like "an mcp-guardrails compliant server"
end
```

## 5. Answer the incident question

```ruby
MCP::Guardrails::Audit::Query
  .for_principal(user)
  .for_agent("claude-desktop")
  .between(1.week.ago, Time.current)
  .pluck(:occurred_at, :tool_name, :outcome, :rule, :record_type, :record_ids)
```

One query, allowed and denied calls both present, each row naming the rule that decided
it (SC-003).

## Without Rails, or without fast-mcp

The core needs neither. Use the plain interface:

```ruby
require "mcp/guardrails"

MCP::Guardrails.invoke(
  tool: InvoiceSearchTool,
  arguments: { query: "AC" },
  principal: current_user,
  agent: { id: "claude-desktop" }
)
```

Same envelope, same guarantees, same ledger entry. The fast-mcp adapter
(`require "mcp/guardrails/fast_mcp"`) is a convenience that builds the context for you.

## What you have not gained

Rate limiting, prompt-injection defense, cost control, and connection authentication are
out of scope. This library governs *what an authenticated agent may touch* and *what it
touched*. Keep your existing auth.
