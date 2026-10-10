# Quickstart: reeve

The whole adoption path, end to end. Target: under 15 minutes from an existing MCP server
to a guarded, audited, test-asserted tool (SC-004).

## 1. Install

```bash
bundle add reeve
bin/rails generate reeve:install
bin/rails db:migrate
```

The generator creates two files:

- `config/initializers/reeve.rb` — with `principal_resolver` left as a TODO you
  must fill in, and `unguarded_tools` written explicitly with both options shown (FR-023).
- `db/migrate/xxxx_create_reeve_audit_entries.rb` — the ledger table, and the record that
  holds its chain (specs/002).

## 2. Say who the agent acts for

```ruby
# config/initializers/reeve.rb
Reeve.configure do |config|
  config.principal_resolver = ->(context) { User.find_by(id: context.metadata[:user_id]) }
  config.unguarded_tools    = :deny        # :deny (default) | :allow_with_warning
  config.redact_arguments   = %i[password token ssn]
  # Already in the generated initializer: the key that chains the ledger (specs/002).
  config.ledger_key = Rails.application.key_generator.generate_key("reeve audit ledger", 32)
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

If your tool returns a number or a summary rather than records, ask for the scoped
relation instead of building your own:

```ruby
def call(**)
  scoped(Invoice).where(overdue: true).count
end
```

The tool body does not change (SC-005). The relation it returns is merged with
`InvoicePolicy::Scope` for the invoking principal before it ever executes.

## 4. Prove it in CI

```ruby
# spec/spec_helper.rb
require "reeve/rspec"
RSpec.configure { |c| c.include Reeve::Testing::Matchers }

# spec/tools/invoice_search_tool_spec.rb
RSpec.describe InvoiceSearchTool do
  let(:owner)    { create(:user) }
  let(:stranger) { create(:user) }
  before { create(:invoice, owner: owner, number: "AC-1") }

  it { is_expected.to deny_access_for(stranger).with(query: "AC") }
  it { is_expected.to audit_every_call }
end

# spec/compliance_spec.rb — checks every guarded tool at once
RSpec.describe "reeve compliance" do
  it_behaves_like "a reeve-compliant server"
end
```

## 5. Answer the incident question

```ruby
Reeve::Audit::Query
  .for_principal(user)
  .for_agent("claude-desktop")
  .between(1.week.ago, Time.current)
  .pluck(:occurred_at, :tool_name, :outcome, :rule, :record_type, :record_ids)
```

One query, allowed and denied calls both present, each row naming the rule that decided
it (SC-003).

## 6. Check that nobody rewrote the ledger

```bash
bin/rails reeve:verify_ledger
```

Exit status `0` means the chain verified intact over the range it prints, `1` that it is
broken, `2` that it could not verify. The limits of that guarantee are in the README's
"Tamper-evident, within stated limits" and specs/002-tamper-evident-ledger/spec.md.

## Without Rails, or without fast-mcp

The core needs neither. Use the plain interface:

```ruby
require "reeve"

Reeve.invoke(
  tool: InvoiceSearchTool,
  arguments: { query: "AC" },
  principal: current_user,
  agent: { id: "claude-desktop" }
)
```

Same envelope, same guarantees, same ledger entry. The fast-mcp adapter
(`require "reeve/fast_mcp"`) is a convenience that builds the context for you.

## What you have not gained

Rate limiting, prompt-injection defense, cost control, and connection authentication are
out of scope. This library governs *what an authenticated agent may touch* and *what it
touched*. Keep your existing auth.
