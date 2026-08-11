# Reeve

**Authentication says who's at the door. Reeve decides what they can touch, and remembers
what they touched.**

A Ruby gem that makes it safe for a Rails application to expose MCP tools to AI agents:
declarative per-record authorization, an append-only audit ledger, and a testing kit that
proves both hold.

> **Status: 0.0.1 is a placeholder release reserving the gem name. There is no working
> code yet.** Development is in progress — don't install this expecting it to do anything.

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

## The shape of it

```ruby
class InvoiceSearchTool < FastMcp::Tool
  guard_with InvoicePolicy          # the only line you add

  def call(query:)
    Invoice.where("number LIKE ?", "%#{query}%")
  end
end
```

Three things then hold:

1. **Deny by default.** The tool returns only invoices the acting principal may see. No
   principal, no guard, or a policy error means no records — never a silent pass.
2. **Every call leaves a trace.** One append-only ledger row per invocation, allowed or
   denied, naming the agent, the principal, the arguments, what came back, and the rule
   that decided.
3. **Provable in CI.** `expect(tool).to deny_access_for(stranger)` in RSpec,
   `assert_denies_access_for` in Minitest, or the checks called directly from a rake task.

## Proving it without a test framework

The checks are plain objects, so the same guarantees are assertable outside a test suite —
from a rake task, a CI script, or a boot-time assertion in staging. Neither RSpec nor
Minitest needs to be installed:

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

A failing run prints the offending check, the offending tool, and the records that leaked:

```text
reeve compliance: 13 checks, 12 passed, 1 failed

FAIL CrossPrincipalLeak
  expected InvoiceSearchTool to return no records belonging to another principal, but it
  returned 3 records to User#1 that also belong to User#2: Invoice#7, Invoice#8,
  Invoice#9 (guard: InvoicePolicy, decision: allow via InvoicePolicy#index)
```

## Planned for v1

- Per-record authorization bridging Pundit or plain policy objects
- Append-only audit ledger with a query interface and an install generator
- Testing kit: framework-neutral checks with RSpec, Minitest, and plain-Ruby front-ends
- fast-mcp adapter, plus a plain interface for everyone else

Ruby 3.0+, Rails 7.0+. No runtime dependencies.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
