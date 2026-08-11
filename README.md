# Reeve

**Authentication says who's at the door. Reeve decides what they can touch, and remembers
what they touched.**

A Ruby gem that makes it safe for a Rails application to expose MCP tools to AI agents:
declarative per-record authorization, an append-only audit ledger, and a testing kit that
proves both hold.

> **Status: unreleased.** The published `0.0.1` is a placeholder reserving the gem name.
> The implementation on `main` is complete and green but has not been released — don't
> `bundle add reeve` expecting the code below to be in the box yet.

*A reeve is an official who acts with delegated authority on behalf of someone else — the
root of "sheriff" (shire-reeve). That delegation is exactly what this gem governs: an agent
acting for a human, allowed to reach only what that human may reach.*

*Developed under the working name `mcp-guardrails`.*

## The problem

The Ruby MCP server stack — the official [`mcp`](https://github.com/modelcontextprotocol/ruby-sdk)
gem, [fast-mcp](https://github.com/yjacquin/fast-mcp), and
[ActionMCP](https://github.com/seuros/actionmcp) — is healthy and consolidating. All three
authenticate the *connection*. None of them scope what an authenticated agent may **see per
person**, none produce a compliance-grade audit trail, and none ship a way to prove either
in CI.

That's the gap Reeve fills. It's an extension layer, not a competitor — it rides all three.

## Three steps

```bash
bundle add reeve
bin/rails generate reeve:install
bin/rails db:migrate
```

**1. Say who the agent is acting for.** This is the only thing Reeve cannot work out for
itself, and the generated initializer leaves it as a TODO:

```ruby
# config/initializers/reeve.rb
Reeve.configure do |config|
  config.principal_resolver = lambda do |context|
    ApiToken.find_by(token: context.metadata.dig(:headers, "Authorization"))&.user
  end

  config.unguarded_tools  = :deny        # :deny | :allow_with_warning
  config.redact_arguments = %i[password token ssn]
end
```

Until that resolver is set, every guarded call denies with `no_principal`. That is the
intended behaviour: the library is safe before it is configured.

**2. Guard a tool.**

```ruby
class InvoiceSearchTool < FastMcp::Tool
  guard_with InvoicePolicy          # the only line you add
  redact :customer_ssn

  def call(query:)
    Invoice.where("number LIKE ?", "%#{query}%")
  end
end
```

**3. Prove it in CI.**

```ruby
RSpec.describe InvoiceSearchTool do
  it { is_expected.to deny_access_for(stranger).with(query: "AC") }
  it { is_expected.to audit_every_call }
end
```

Three things now hold, and each is a test you can run rather than a claim you have to
trust.

## Deny by default

A tool returns only the records its principal may see. No principal, no `guard_with`, or a
policy that raises means no records — never a silent pass. A single record outside the
principal's scope is refused in a way that does not reveal whether it exists:

```ruby
Reeve.invoke(tool: InvoiceShowTool, arguments: { id: 41 }, principal: alice)
# => Reeve::DeniedError: reeve denied invoice_show_tool for principal 1:
#    out_of_scope_record (the requested record is not within this principal's scope)
```

Anything that is not a record — a count, a sum, a summary — is safe only when it was
computed from `scoped`, because then the tool never held unscoped data:

```ruby
class OverdueTotalTool
  include Reeve::Guard
  guard_with InvoicePolicy

  def call
    scoped(Invoice).where(overdue: true).sum(:cents)   # safe by construction
  end
end
```

Reaching for `Invoice.sum(:cents)` there is denied with `unscoped_derived_result`. The
guarantee is structural, not a matter of remembering.

## Every call leaves a trace

One append-only row per invocation, allowed or denied, naming the agent, the principal, the
arguments (post-redaction), what came back, and the rule that decided:

```ruby
Reeve::Audit::Query
  .for_principal(user)
  .for_agent("claude-desktop")
  .between(1.week.ago, Time.current)
  .pluck(:occurred_at, :tool_name, :outcome, :rule, :record_type, :record_ids)
```

A call whose tool raised is still recorded — that trace is the one most worth having. A
call that cannot be recorded fails, unless the host has explicitly opted into
`audit_failure_mode = :warn`.

## Provable in CI, in whichever framework you already use

All the logic lives in framework-neutral checks. RSpec and Minitest are thin front-ends
over the same objects, emitting the same messages, so no guarantee is provable in one
framework only.

```ruby
# RSpec — require "reeve/rspec"
it { is_expected.to deny_access_for(stranger) }
it_behaves_like "a reeve-compliant server"
```

```ruby
# Minitest — require "reeve/minitest"
class ComplianceTest < ActiveSupport::TestCase
  include Reeve::Testing::Assertions
  include Reeve::Testing::ComplianceAssertions

  def test_search_denies_a_stranger
    assert_denies_access_for InvoiceSearchTool, stranger, query: "AC"
  end
end
```

A stock `rails new` application — Minitest, no RSpec — proves every guarantee without
adding a test framework. That is a spec in this repo, not an aspiration.

### Without a test framework at all

The checks are plain objects, so the same guarantees are assertable from a rake task, a CI
script, or a boot-time assertion in staging:

<!-- reeve:compliance-gate -->
```ruby
require "reeve/testing"

report = Reeve::Checks.run_all(principals: [alice, bob])
abort report.to_s unless report.passed?
```

`alice` and `bob` are two fixture principals with disjoint records — that disjointness is
what makes a shared record identifier proof of a leak. As a Rails rake task:

```ruby
# lib/tasks/reeve.rake
namespace :reeve do
  desc "Fail the build if any guarded tool leaks or goes unaudited"
  task compliance: :environment do
    require "reeve/testing"

    report = Reeve::Checks.run_all(principals: Reeve::Testing.compliance_principals)
    abort report.to_s unless report.passed?
    puts report
  end
end
```

A failing run names the check, the tool, and the records that leaked:

```text
reeve compliance: 13 checks, 12 passed, 1 failed

FAIL CrossPrincipalLeak
  expected InvoiceSearchTool to return no records belonging to another principal, but it
  returned 3 records to User#1 that also belong to User#2: Invoice#7, Invoice#8,
  Invoice#9 (guard: InvoicePolicy, decision: allow via InvoicePolicy#index)
```

## Without Rails, or without fast-mcp

The core needs neither. `Reeve.invoke` is the same envelope with the same guarantees:

```ruby
require "reeve"

Reeve.invoke(
  tool: InvoiceSearchTool,
  arguments: { query: "AC" },
  principal: current_user,
  agent: { id: "claude-desktop" }
)
```

Policies are plain objects unless you want Pundit (`authorize` and `scope`, two methods).
The ledger is an ActiveRecord table unless you supply your own recorder. Records are
ActiveRecord unless they are not — a plain object with an `id` works.

## What you have not gained

Rate limiting, prompt-injection defence, cost control, and connection authentication are
out of scope. This library governs *what an authenticated agent may touch* and *what it
touched*. Keep your existing auth.

Ruby 3.0+, Rails 7.0+. No runtime dependencies. The fast-mcp adapter needs Ruby 3.1+,
because fast-mcp does.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
