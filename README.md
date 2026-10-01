# Reeve

**Authentication says who's at the door. Reeve decides what they can touch, and remembers
what they touched.**

A Ruby gem that makes it safe for a Rails application to expose MCP tools to AI agents:
declarative per-record authorization, an append-only audit ledger, and a testing kit that
proves both hold.

> **Status: 0.4.0.** Read the known limitations in
> [CHANGELOG.md](CHANGELOG.md) before adopting it — particularly the one about a
> transaction wrapped around an invocation, if your application wraps requests in one.

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

The error names the rule and never names the record. One caveat worth knowing: fetching
from the unscoped model still lets a caller tell "someone else's" (a denial) from "no such
record" (`nil`). If that distinction matters, fetch through `scoped`, where both answers
are `nil`:

```ruby
def call(id:)
  scoped(Invoice).find_by(id: id)
end
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

## Tools that write

A denial means nothing happened. Authorization runs before the tool, but with the model
class as its subject — for an index-style check there is no record yet — so the per-record
answer only arrives once the tool has returned something to scope. A write tool sits
between those two points:

```ruby
def call(id:, number:)
  invoice = Invoice.find(id)        # unscoped fetch
  invoice.update!(number: number)   # ...then a write
  invoice
end
```

The tool body runs in a transaction, and a scope denial rolls it back. Someone else's
record is refused *and* unchanged, and the ledger's `deny` is a true statement about the
database. A transaction the host opened around the invocation is untouched — the rollback
reaches the tool's work and stops there.

What a rollback cannot reach is anything that was never in the transaction. A tool that
sends an email, calls a webhook or writes a file before it knows whether it is allowed to
must ask first:

```ruby
def call(id:, to:)
  invoice = authorize!(Invoice.find(id))   # raises DeniedError if the policy says no
  InvoiceMailer.reminder(invoice, to).deliver_now
  invoice
end
```

`authorize!` asks the declared policy about one record and returns it, so it reads inline.
The denial carries the policy's own rule into the ledger, and names no record — a refusal
and a record that does not exist have to read the same.

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

If your application wraps invocations in a transaction — a controller that opens one per
request, a job runner — a rollback takes the ledger row with it, and exactly the calls
worth auditing are the ones that rolled back. Write on a connection the rollback cannot
reach:

```ruby
config.audit_recorder = Reeve::Audit::IsolatedRecorder
```

It needs a database with concurrent writers and refuses on SQLite, where an open
transaction holds the write lock; `IsolatedRecorder.available?` lets you branch if you
develop on one and deploy on the other. The default recorder warns when it detects the
case rather than failing silently.

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
what makes a shared record identifier proof of a leak.

**The suite walks every tool that included `Reeve::Guard`, not only the ones that declared
a guard.** A tool that forgot `guard_with` is the one worth finding, and it is absent from
the guard registry by definition — so a run that only inspected guarded tools reported
all-green on precisely the application that had a problem.

Mid-retrofit that means a red build, which is honest but unreadable if it stays red for
weeks. Say what you have certified so far, and grow the list:

```ruby
config.compliance_tools = -> { [InvoiceSearchTool, InvoiceShowTool] }
```

Reeve can only see tools that reached it. If your MCP server dispatches tools Reeve has
never been told about — a custom controller with its own registry — declare the server's
real inventory ([below](#every-tool-the-endpoint-dispatches)), or the run certifies the
subset Reeve happens to know. Until you do, the suite says so: `EndpointCoverage` is
reported as skipped, never as passed.

As a Rails rake task:

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

## Wrapping your own JSON-RPC server

Plenty of Rails apps expose `/mcp` from a controller they wrote themselves, with their own
tool registry and their own bearer-token authentication. There is no adapter to install
for that, and none is needed: `Reeve.invoke` is the adapter interface. An MCP integration
is a function from a JSON-RPC request to one `Reeve.invoke` call.

Keep the authentication you have. Reeve does not do connection auth (see [What you have
not gained](#what-you-have-not-gained)) — the controller still decides whether the caller
gets in the door, and Reeve decides what they may touch once inside.

**Dispatch through the envelope.** Map the JSON-RPC tool name to the class, then call:

```ruby
# app/controllers/mcp_controller.rb
def call_tool
  tool = McpServer.registry.fetch(params.dig(:params, :name))

  records = Reeve.invoke(
    tool: tool,
    arguments: params.dig(:params, :arguments).to_h.symbolize_keys,
    agent: { id: request.headers["X-MCP-Client"] || "unknown" },
    metadata: { headers: request.headers.to_h.slice(*AUDITED_HEADERS) }
  )

  render json: { jsonrpc: "2.0", id: params[:id], result: serialize(records) }
rescue Reeve::DeniedError => e
  render json: { jsonrpc: "2.0", id: params[:id],
                 error: { code: -32_003, message: e.message } }
end
```

Note what is *not* passed: `principal:`. Omit it and the resolver in your initializer runs,
which is what you want when the controller has already set `Current.user` — one place
decides who the principal is, and the ledger records the same answer the guard used.
Passing `principal:` explicitly overrides the resolver for that call, which is useful in
tests and in scripts.

**`metadata:` is transport detail, and it is recorded.** It reaches the resolver as
`context.metadata` and is written to the ledger's `metadata` column, so it is what a
reviewer has to reconstruct *which request* a row came from. It goes through the same
redactor as the arguments, so `Authorization` and friends are replaced by name — but pass
the headers you would want in an audit rather than all of them.

**Resolve the principal from whichever the controller established:**

```ruby
Reeve.configure do |config|
  config.principal_resolver = lambda do |context|
    Current.user || ApiToken.find_by(
      token: context.metadata.dig(:headers, "Authorization").to_s.delete_prefix("Bearer ")
    )&.user
  end
end
```

A resolver that returns nil — or raises — denies with `no_principal` and still writes a
row. There is no configuration in which an unidentified caller reaches a tool.

**Adopt one tool at a time.** A registry of thirty tools does not need thirty policies
before any of this is worth turning on:

```ruby
config.unguarded_tools = :allow_with_warning   # migrating
```

Tools with `guard_with` are authorized and scoped normally. Tools without one still run —
unscoped, which is the entire point of the warning — and are recorded with `guard: "none"`
and rule `unguarded_tool`, so the ledger itself is your worklist:

```ruby
Reeve::Audit::Entry.where(guard: "none").distinct.pluck(:tool_name)
```

Flip to `:deny` when that comes back empty, and the mode stops being reachable by accident.

The compliance checks work here too, and they take an `invoke:` argument precisely so they
run against your dispatcher rather than a synthetic call:

```ruby
Reeve::Checks.run_all(
  principals: [alice, bob],
  invoke: ->(tool:, principal:, arguments:) { McpServer.dispatch(tool, principal, arguments) }
)
```

That is the whole integration: one call site, your auth untouched, and the same three
guarantees the fast-mcp adapter gets.

## Every tool the endpoint dispatches

Reeve protects the tools routed through it, and only those. A server that registers tools
as names and handler blocks can send some through `Reeve.invoke` and run the rest directly
— and the direct ones are not unguarded, they are invisible: no denial, no scope, no ledger
row, and nothing that says so. Deny-by-default cannot deny a call it never sees.

`Reeve::Inventory` makes the server's own list of names the thing that gets checked:

```ruby
# config/initializers/reeve.rb
McpInventory = Reeve::Inventory.new(
  registered: -> { McpServer.tool_names },
  routed: -> { { "search_invoices" => InvoiceSearchTool, "get_invoice" => InvoiceShowTool } },
  exemptions: { "healthcheck" => { reason: "returns no application data" } }
)

Reeve.configure { |config| config.inventory = McpInventory }
```

Each part takes a value or a callable. Callables are read when asked, so the initializer
neither autoloads application constants nor runs before the server has registered its
tools.

```text
reeve inventory: 4 registered
  2 protected and guarded
  0 routed through reeve but unguarded
  1 bypasses reeve
  1 exempted
coverage: incomplete

BYPASS export_invoices
  registered with the server but neither routed through reeve nor exempted — route it to
  a guarded tool, or exempt it with a reason

EXEMPT healthcheck
  returns no application data
```

The report names tools, classes and exemption reasons — never an argument, a principal or
a record — so it is safe to print in CI. An exemption without a reason is refused, and one
with a reason is listed every time, complete or not.

**Fail boot or CI on a gap:**

```ruby
McpInventory.verify!   # raises Reeve::IncompleteInventoryError, carrying the report
```

**Dispatch through it, and a bypass stops being possible:**

```ruby
def call_tool
  name = params.dig(:params, :name)
  arguments = params.dig(:params, :arguments).to_h.symbolize_keys

  result = McpInventory.dispatch(name, arguments: arguments,
                                       agent: { id: request.headers["X-MCP-Client"] }) do
    McpServer.handlers.fetch(name).call(arguments)
  end

  render json: { jsonrpc: "2.0", id: params[:id], result: serialize(result) }
rescue Reeve::DeniedError => e
  render json: { jsonrpc: "2.0", id: params[:id],
                 error: { code: -32_003, message: e.message } }
end
```

- A **routed** name runs through `Reeve.invoke` under its class's guard, with the handler
  block as the body. A registry of blocks needs one guarded class per tool to name its
  policy, and nothing else — the block still does the work, and what it returns is scoped.
  Handlers dispatched this way should not call `Reeve.invoke` themselves.
- An **exempt** name runs the block as written.
- **Any other name** is a tool with no guard, and `unguarded_tools` decides: refused with
  `unbound_tool` under `:deny`, the default; run unscoped and recorded with `guard: "none"`
  under `:allow_with_warning`. Recorded either way, so a name the inventory missed lands on
  the same ledger worklist as an unguarded class.

**In the compliance suite,** `EndpointCoverage` compares the run against the inventory. It
passes only when every registered tool is guarded or exempt and the run covered all of
them. It fails when the run claimed the whole endpoint and something bypasses Reeve. A run
narrowed by `compliance_tools` is reported as a subset — skipped, naming what it left out —
so a retrofit stays green without passing for complete coverage.

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
