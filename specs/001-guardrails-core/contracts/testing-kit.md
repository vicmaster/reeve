# Contract: Testing Kit

**Stability**: public.

The kit is three layers: framework-neutral **checks** that hold all the logic, and thin
**front-ends** (RSpec, Minitest, plain Ruby) that adapt them. No guarantee is provable in
one framework only (FR-026).

```text
testing/checks/*.rb        ← all the logic; plain Ruby; no test framework loaded
testing/matchers/*.rb      ← RSpec front-end        (require "reeve/rspec")
testing/assertions.rb      ← Minitest front-end     (require "reeve/minitest")
                           ← plain Ruby: call the checks directly
```

## Layer 1 — Checks (the actual contract)

A check is an object with `#call` returning a `Result`. It loads no test framework and
raises nothing on failure.

```ruby
check = Reeve::Checks::CrossPrincipalLeak.new(
  tool: InvoiceSearchTool, principals: [alice, bob], arguments: { query: "AC" }
)
result = check.call

result.passed?  # => false
result.message  # => "InvoiceSearchTool returned 3 records to User#42 that ..."
result.details  # => { leaked: [[Invoice, 7], [Invoice, 8]], rule: "InvoicePolicy#index?" }
```

Checks shipped in v1:

| Check | Asserts | Requirement |
|-------|---------|-------------|
| `Checks::CrossPrincipalLeak` | a tool returns no records belonging to another principal | FR-016, FR-003 |
| `Checks::AuditCoverage` | every invocation produces exactly one ledger entry | FR-017, FR-008 |
| `Checks::GuardDeclared` | the tool has a `guard_with` declaration | FR-002, FR-004 |
| `Checks::RulePresent` | every entry carries a non-null `rule` | FR-009 |
| `Checks::RedactionHolds` | declared-sensitive values appear in no entry | FR-011 |
| `Checks::PrincipalRequired` | no resolvable principal denies without consulting the policy | FR-001 |
| `Checks::ContractVersion` | the recorded audit-entry contract version matches the gem | FR-015 |

`Checks::ALL` enumerates them; `Checks.run_all(principals:)` runs every check against every
registered guarded tool and returns a `Report`. That is the compliance suite's engine, and
it is callable with no test framework present at all.

**Because the checks are plain objects, the same guarantees are assertable outside a test
suite** — a rake task, a CI script, a deploy gate, or a boot-time assertion in staging:

```ruby
report = Reeve::Checks.run_all(principals: [alice, bob])
abort report.to_s unless report.passed?
```

## Layer 2 — RSpec front-end

```ruby
require "reeve/rspec"
RSpec.configure { |c| c.include Reeve::Testing::Matchers }

RSpec.describe InvoiceSearchTool do
  it { is_expected.to deny_access_for(stranger).with(query: "AC") }
  it { is_expected.to audit_every_call }
end

RSpec.describe "reeve compliance" do
  it_behaves_like "a reeve-compliant server"
end
```

## Layer 3 — Minitest front-end

Equivalent coverage, same checks, same messages.

```ruby
require "reeve/minitest"

class InvoiceSearchToolTest < ActiveSupport::TestCase
  include Reeve::Testing::Assertions

  test "does not leak across principals" do
    assert_denies_access_for InvoiceSearchTool, stranger, query: "AC"
  end

  test "is audited" do
    assert_audits_every_call InvoiceSearchTool
  end
end

class ComplianceTest < ActiveSupport::TestCase
  include Reeve::Testing::ComplianceAssertions   # one method per check
end
```

A stock `rails new` application — Minitest, no RSpec — must be able to prove every
guarantee without adding a test framework. That is the acceptance bar for this layer, not a
nice-to-have.

## Failure messages

Built by the check, not the front-end, so both frameworks and the plain-Ruby path emit the
identical string (FR-019):

```text
expected InvoiceSearchTool to deny access for User#42, but it returned 3 records
that principal may not see: Invoice#7, Invoice#8, Invoice#9
(guard: InvoicePolicy, decision: allow via InvoicePolicy#index?)
```

```text
expected every call to be audited, but InvoiceExportTool produced 0 audit entries
for 1 invocation — it is invoked outside Reeve.invoke
```

## Constraints

- Checks load no test framework; RSpec and Minitest are both development-only dependencies
  of this gem and neither is required at runtime.
- No MCP client, no network, no running server (FR-020).
- The kit is verified against deliberately-broken fixtures in this repo — a cross-principal
  leaker and an envelope-bypassing tool. Green on the control, red with the right message on
  each (SC-007).
- The same fixtures run through all three front-ends and must produce identical outcomes
  and identical messages (SC-009). One shared example table drives all three, so a check
  cannot silently work in one and not another.
- Host setup for the compliance suite is two fixture principals with disjoint records
  (`config.compliance_principals = -> { [alice, bob] }`) and nothing else.
