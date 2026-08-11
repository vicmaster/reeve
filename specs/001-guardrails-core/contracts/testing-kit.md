# Contract: Testing Kit

**Stability**: public. Opt-in via `require "mcp/guardrails/rspec"` — RSpec is never a
runtime dependency.

```ruby
# spec/spec_helper.rb
require "mcp/guardrails/rspec"
RSpec.configure { |c| c.include MCP::Guardrails::Testing::Matchers }
```

## `deny_access_for` (FR-016)

```ruby
RSpec.describe InvoiceSearchTool do
  let(:owner)    { create(:user) }
  let(:stranger) { create(:user) }
  before { create(:invoice, owner: owner) }

  it { expect(described_class).to deny_access_for(stranger) }

  # narrow form: assert about specific records
  it { expect(described_class).to deny_access_for(stranger).to_see(Invoice.all) }

  # with arguments the tool requires
  it { expect(described_class).to deny_access_for(stranger).with(query: "AC") }
end
```

Passes when invoking the tool as that principal returns none of the records in question —
whether by denial or by empty scoping; both are correct outcomes for a stranger.

Failure message names the tool, the principal, and **the leaked record identifiers**:

```text
expected InvoiceSearchTool to deny access for User#42, but it returned 3 records
that principal may not see: Invoice#7, Invoice#8, Invoice#9
(guard: InvoicePolicy, decision: allow via InvoicePolicy#index?)
```

## `audit_every_call` (FR-017)

```ruby
it { expect(MyMcpServer).to audit_every_call }
it { expect(InvoiceSearchTool).to audit_every_call }
```

Drives every registered tool (or the one given) through the envelope with generated
arguments and asserts exactly one ledger entry per invocation. Detects tools that bypass
the envelope entirely.

```text
expected every call to be audited, but InvoiceExportTool produced 0 audit entries
for 1 invocation — it is invoked outside MCP::Guardrails.invoke
```

## Shared compliance suite (FR-018)

```ruby
RSpec.describe "MCP guardrails compliance" do
  it_behaves_like "an mcp-guardrails compliant server"
end
```

One include; every registered guarded tool is checked. The suite asserts:

| Check | Source requirement |
|-------|--------------------|
| Every registered tool has a `guard_with` declaration | FR-002, FR-004 |
| No tool returns records outside the invoking principal's scope, over the fixture principals | FR-003, SC-001 |
| Every invocation produces exactly one ledger entry, allow and deny | FR-008, SC-002 |
| Every entry carries a non-null `rule` | FR-009 |
| Declared-sensitive argument values are absent from every entry | FR-011 |
| An invocation with no resolvable principal denies without consulting the policy | FR-001 |
| A tool with no declaration denies (or records `guard: "none"` if configured permissive) | FR-023 |
| The recorded audit-entry contract version matches the installed gem's | FR-015 |

The suite requires the host to define two fixture principals with disjoint records
(`config.compliance_principals = -> { [alice, bob] }`) and nothing else.

## Constraints

- No MCP client, no network, no running server (FR-020).
- Every failure message states tool, principals, expected vs actual (FR-019).
- The kit itself is verified against deliberately-broken fixtures in this repo: a
  cross-principal leaker and an envelope-bypassing tool. Green on the good fixture, red
  with the right message on each bad one (SC-007).
