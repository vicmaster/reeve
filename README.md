# Reeve

**Authentication says who's at the door. Reeve decides what they can touch, and remembers
what they touched.**

A Ruby gem that makes it safe for a Rails application to expose MCP tools to AI agents:
declarative per-record authorization, an append-only audit ledger, and a testing kit that
proves both hold.

> **Status: 0.7.0.** Read the known limitations in
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
intended behaviour: the library is safe before it is configured. The initializer also
derives the key that chains the audit ledger from `secret_key_base`, so that works in
every environment with nothing to set up — see [Tamper-evident, within stated
limits](#tamper-evident-within-stated-limits).

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

## Tamper-evident, within stated limits

Every row Reeve writes is linked to the one before it by a keyed digest (HMAC-SHA256), with
a key the database does not hold. Someone who can write to the ledger table but does not
hold the key can still change it, but the change shows when the chain is checked:

```bash
bin/rails reeve:verify_ledger
```

```text
reeve ledger: INTACT — sequences 1–48,211 verified (head at start: 48,211); 5,000 earlier entries not covered (5,000 when the chain started); not anchored
```

It exits `0` when the chain is intact, `1` when it is broken, and `2` when it could not
verify (no chain, no key, or rows signed by a key it does not hold). Run it on a schedule
and alert on anything but `0`. `LIMIT=` caps the breaks it lists, never the totals;
`FORMAT=json` writes every break. The same answer from Ruby, or with an auditor's own copy
of the key:

```ruby
result = Reeve::Audit::Chain.verify
result.status   # => :intact, :broken, :unverifiable or :no_chain
result.covered  # => 1..48211
puts result     # the report above, with every break listed under it
```

In CI the compliance suite you already run includes `LedgerChain`, in both frameworks:
it writes entries of its own and fails on a broken chain, a missing key, or entries that
were not chained. "Not anchored" on the summary line is explained under **Anchoring the
chain** below.

**The key.** The generated initializer derives it from `secret_key_base`:

```ruby
config.ledger_key = Rails.application.key_generator.generate_key("reeve audit ledger", 32)
```

Rotating `secret_key_base` therefore rotates the ledger key. Keep the old one, or the
entries it signed become *unverifiable* — reported as such, never as tampered:

```ruby
config.retired_ledger_keys = [old_key]   # verify with these; new epochs never open with them
```

**Rotating the key.** Every key that signs the ledger opens a numbered *key epoch*, and every
entry records its epoch inside its digest. To rotate: set the new key as `ledger_key` and the
old one in `retired_ledger_keys` (in that order), deploy, then run

```bash
bin/rails reeve:rotate_ledger_key
```

It reports `ROTATED` or `CURRENT` (exit `0`), or `REFUSED` (exit `1`, nothing written) — for
instance when the current epoch's key is not configured where it runs, since that epoch's
entries would become unverifiable there. Writes never wait for it: the first write with the
new key opens its epoch, and servers still on the old key during the deploy keep writing
under theirs. From Ruby:

```ruby
rotation = Reeve::Audit::Chain.rotate_key!
rotation.status   # => :rotated, :current or :refused
rotation.epoch    # => 1
```

Verification then lists each epoch under its summary line, with the key fingerprint, where
it begins, and whether it verified. The CHANGELOG has the full procedure.

**Anchoring the chain.** The chain's own records live in the same database as the entries, so
someone who deletes the newest entries and rewinds the head to match, or deletes the whole
ledger, leaves nothing behind that verification can see. A *checkpoint* is a second witness:
one signed line saying how far the chain reached (its genesis, its head, its latest key
epoch), kept where the database's users cannot change it. It holds digests and counts only,
never entry content or a key.

Point an anchor at that storage. The line goes at the bottom of
`config/initializers/reeve.rb`, after `require "reeve/audit"` (which defines `FileAnchor`),
outside the `Reeve.configure` block, hence `Reeve.config`:

```ruby
require "reeve/audit"

Reeve.config.ledger_anchor =
  Reeve::Audit::FileAnchor.new("/mnt/ledger-anchor/#{Rails.env}.checkpoints")
```

Use one anchor per environment, on storage outside the database host, such as a mount backed
by an object-locked bucket; a file next to the database protects nothing. The hosts that make
checkpoints need to write the file (it is created on the first one), and the hosts that verify
need to read it. Any object with `publish(line)` and `checkpoints` works in its place.

Then make a checkpoint on a schedule, from one host (hourly, say), and keep verifying as
before. Alert on anything but `0` from either task. `reeve:checkpoint_ledger` exits `1` when
it refused (no key, or no chain until the first guarded call) or the anchor failed, and still
prints the line so it can be stored by hand. Two runs at once are safe.

```bash
bin/rails reeve:checkpoint_ledger   # exit 0 made and published
bin/rails reeve:verify_ledger       # checks the ledger against every checkpoint
```

```text
reeve ledger: INTACT — sequences 1–48,211 verified (head at start: 48,211); 5,000 earlier entries not covered (5,000 when the chain started); anchored at #48,000 (checkpoint 2026-10-25 14:00 UTC), 211 entries after it
```

Every checkpoint is checked: a ledger that no longer reaches one, holds another entry where it
saw one, or lost an epoch record it named, is BROKEN (exit `1`), and so is an emptied ledger,
which without a checkpoint reads only as "no chain". The newest entries deleted with the head
rewound read like this:

```text
reeve ledger: BROKEN — 1 break in sequences 1–46,211; 5,000 earlier entries not covered (5,000 when the chain started); anchored at #44,000 (checkpoint 2026-10-25 13:00 UTC), 2,211 entries after it
  totals: checkpoint_not_reached 1
  checkpoint #48,000 checkpoint_not_reached the head is at 46,211; entries the checkpoint saw were removed
```

What it does not cover: entries written after the latest checkpoint can still be removed
without trace. "211 entries after it" counts the entries still there past the checkpoint; it
cannot see ones that were deleted, so how often you checkpoint is the size of that window.
`reeve:rotate_ledger_key` makes a checkpoint itself after opening an epoch. Writes never touch
the anchor.

*Restores and resets.* Restoring a backup older than a checkpoint reads as BROKEN, truthfully:
the restored ledger lost entries that checkpoint saw. Resetting a database on purpose (a
staging rebuild) is the same, so start a new anchor file for the new ledger: change the path
(`staging-2026-10-25.checkpoints`, say), keep the old file as the record of the old ledger, and
make a checkpoint. Until then the run reads "not anchored". `CHECKPOINTS=` (empty) verifies
without any checkpoint, for a one-off check, never as the fix.

*Other sources, large ledgers.* `CHECKPOINTS=path` verifies against a file of checkpoint lines
instead of the anchor, say an auditor's copy. `FROM=latest` walks only what came after the
newest checkpoint: it first checks that checkpoint (its signature, the genesis and epoch it
names, and that its entry still has the digest it saw), then verifies every entry after it.
Entries before it are not re-verified by that run, and the summary says how many; keep a full
run on a slower schedule. With no checkpoint to start from it exits `2`. From Ruby:

```ruby
Reeve::Audit::Chain.checkpoint!.checkpoint.to_line            # => "{\"epoch\":1,…}"
Reeve::Audit::Chain.verify(checkpoints: lines).anchored_at    # the highest checkpoint that held
```

*In CI.* The `LedgerChain` check the compliance suite runs never reads the anchor, so
configuring one does not change it: a test database is emptied between runs, and old
checkpoints name ledgers that are gone. To prove the anchor works, run the anchored variant as
a test of its own, with the test environment's anchor pointed at a scratch file such as
`Rails.root.join("tmp/ledger.checkpoints")`. It makes a checkpoint, reads it back through the
anchor, and verifies against that one alone:

```ruby
# RSpec
it "anchors the ledger" do
  result = Reeve::Checks::LedgerChain.new(anchored: true).call
  expect(result).to be_passed, result.message
end

# Minitest
def test_anchors_the_ledger
  result = Reeve::Checks::LedgerChain.new(anchored: true).call
  assert result.passed?, result.message
end
```

A dedicated key decouples the two: `config.ledger_key = Rails.application.credentials.reeve_ledger_key`.
Keys must be at least 32 bytes and are only ever printed as 16-character fingerprints.
Without a key, every guarded call fails closed; under `audit_failure_mode = :warn` it is
recorded unchained instead, logged each time, and reported by verification.

**Detected**, provided the key has not leaked:

- a chained row whose recorded content was changed;
- a chained row removed from anywhere before the newest one;
- chained rows swapped, renumbered or moved, or a row inserted that Reeve did not write —
  including one numbered past the head;
- the newest rows removed while the chain record was left alone;
- the chain record removed while chained rows remain;
- an entry whose key id or key epoch was changed, or that names an epoch with no record, and
  an epoch record that was changed, or removed while entries name it (one forged under a key
  you do not hold reads as unverifiable, never intact);
- with checkpoints: any entry the latest checkpoint saw removed, even with the head rewound;
  the whole ledger deleted or replaced; an epoch record a checkpoint named, removed or changed;
  a checkpoint edited, or forged without a key you hold.

**Not detected** — stated plainly, because these are the limits of the guarantee:

1. **A leaked key.** Anyone holding it can rewrite the chain from any point forward. By
   default that is anyone holding `secret_key_base`. Not past a checkpoint made before the
   leak, though: rewriting an entry it saw changes the digest it names.
2. **The newest rows deleted by someone who also rewinds the chain record's head**, unless a
   checkpoint saw them. Rows after the latest checkpoint stay exposed; the summary line counts
   them.
3. **The whole ledger deleted, chain record included**, without a checkpoint. Reported as
   *no chain*, never as a pass, but indistinguishable from a ledger that was never chained.
   And checkpoints are only as safe as their store: one an attacker can delete protects nothing.
4. **Rows written before you upgraded.** They are counted as "not covered" and are exactly
   as trustworthy as they were before. Likewise, entries without a key epoch — chained by
   0.6.0, before or during the upgrade — are checked as 0.6.0 checked them: a rewritten key id
   on one of them reads as unverifiable, not as tampering.
5. **A key you no longer hold.** Entries it signed cannot be checked, by anyone. Epochs make
   that visible and name the epoch; they do not undo it.

And it prevents nothing: it detects a change after the fact. The `GRANT INSERT, SELECT` in
the generated migration is what prevents one. The chain record needs `UPDATE` as well,
which is why a role allowed to rewind it is limit 2.

**What it costs.** About half a millisecond per ledger write on SQLite and about one on
PostgreSQL. Every chained write locks the chain record, so writes serialize. Under the
default recorder inside a transaction your application opened, that lock is held until the
transaction ends, and every other guarded call waits behind it — up to the database's own
lock wait: indefinitely on PostgreSQL (`lock_timeout` is 0 by default), 50 seconds on MySQL
(`innodb_lock_wait_timeout`), and ActiveRecord's `timeout` on SQLite (5 seconds in a
generated `database.yml`). `IsolatedRecorder` holds it for the length of one insert. On
**Rails 7.0 with SQLite**, a thread waiting for SQLite's write lock holds Ruby's GVL
(sqlite3 1.x), so concurrent guarded calls in one process can fail closed after the busy
timeout. Rails 7.1+ or a server database avoids it.

**Your own recorder.** A recorder that writes to Reeve's table chains its rows through the
same door the built-in ones use, or verification reports them as unchained:

```ruby
Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry).append!(row)
```

**Upgrading from 0.7.0:** no migration and nothing to configure; anchoring is opt-in. Every
summary line now ends with its anchoring (`; not anchored` until you set one up), so anything
that matches the whole text line should read `FORMAT=json` instead, whose existing keys are
unchanged.

**Upgrading from 0.6.0:** `bin/rails generate reeve:upgrade && bin/rails db:migrate` before
the new code serves traffic, and grant `INSERT, SELECT` on `reeve_audit_chain_epochs`. The next guarded call opens epoch 0;
earlier entries are listed as "before epoch 0" and checked as before.

**Upgrading from 0.5.0:**

```bash
bin/rails generate reeve:upgrade
bin/rails db:migrate
```

Then add the `config.ledger_key` line the generator prints. Existing rows are not touched;
the next guarded call starts the chain. Servers still on 0.5.0 during a rolling deploy keep
writing unchained rows, which are counted as not covered rather than reported as tampering.

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
abort report.to_s if report.failed? || report.nothing_checked?
```

`alice` and `bob` are two fixture principals with disjoint records — that disjointness is
what makes a shared record identifier proof of a leak. `passed?` only means nothing failed,
so a run over no tools at all passes; `nothing_checked?` is what stops this gate when the
registry is empty, since a script has no pending test to show it.

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
    abort report.to_s if report.failed? || report.nothing_checked?
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
out of scope, and the ledger's chain detects tampering rather than preventing it. This library governs *what an authenticated agent may touch* and *what it
touched*. Keep your existing auth.

Ruby 3.0+, Rails 7.0+. No runtime dependencies. The fast-mcp adapter needs Ruby 3.1+,
because fast-mcp does.

## Who built this

Built by [Victor Velázquez](https://victorvelazquez.dev) — COO at [MagmaLabs](https://www.magmalabs.io) and author of [*The Agentic Engineer*](https://leanpub.com/theagenticengineer). Reeve guards MCP tools in production at MagmaLabs.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
