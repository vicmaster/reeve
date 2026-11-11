# Tasks: Framework Adapters

**Input**: spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md in
`specs/006-framework-adapters/`

Test-first per the constitution (III): each implementation task follows the spec that fails
without it. Every denial spec asserts no rendered content reached the client (SC-002); every
ledger spec searches the row for the request values the spec planted (SC-002). SDK specs skip
where `mcp` cannot load, ActionMCP specs where `action_mcp` cannot load, stating the reason, as
`spec/reeve/integrations/fast_mcp_spec.rb` does. `[P]`: different files, no dependency on an
unfinished task. `[US#]`: spec.md user story.

## Phase 1: Setup

- [x] T001 Spike, no commit of throwaway code: on Ruby 3.0 (`json < 3`, Rails 7.0 stack) check
  that `mcp` 1.0.0 and the latest 1.x resolve and `require "mcp"` loads (R13, `json_schemer`);
  on Ruby 3.2+ check whether `require "action_mcp"` plus `ActionMCP::Tool#call` works without a
  booted Rails app (`Rails.error.report`, engine load). Record both answers in research.md R13
  ("Open" becomes "Settled"); if the SDK cannot run on 3.0, amend FR-022 and SC-003 in spec.md
- [x] T002 Add `mcp` (`>= 1.0, < 2.0`) to the `Gemfile` on every Ruby T001 proved, and
  `actionmcp` (`>= 0.200.0, < 0.204`) in the `RUBY_VERSION >= "3.2"` branch only, with a comment
  in the style of the fast-mcp one; honor `MCP_VERSION` and `ACTIONMCP_VERSION` env pins for the
  floor job; `bundle install` and the full suite stays green
- [x] T003 [P] Not needed: T001 found ActionMCP loads and runs tools without a booted app.
  Was: if T001 found ActionMCP needs a booted app: a spec helper
  `spec/support/optional/action_mcp.rb` that boots `spec/dummy` with the ActionMCP engine for
  the ActionMCP specs only, and leaves every other spec's load path untouched

---

## Phase 2: Foundational (blocks every story)

**Purpose**: the pieces both adapters share. No adapter yet.

- [x] T004 [P] Failing specs in `spec/reeve/guard_spec.rb`: `scoped` and `authorize!` called as
  class methods on a guarded class behave exactly as the instance helpers (same scoper call,
  same `scoped_used?` flag, same denial); then extract the two helpers' bodies into one module
  `Guard::Helpers` in `lib/reeve/authorization/guard.rb`, included by `Guard` and extended
  onto a tool class by adapters that call tools as classes. Specs in
  `spec/reeve/authorization/class_helpers_spec.rb`
- [x] T005 [P] Failing specs in `spec/reeve/integrations_spec.rb` for `Reeve::Integrations`:
  `inside?(tool_name)` is true only while an envelope for that name is open on the current
  thread, false on another thread, false for a different name, false after the envelope ends
  (allowed, denied or raised); `require_version!(gem_name, requirement)` raises
  `ConfigurationError` naming gem, loaded version and range when outside it, passes inside it;
  then create `lib/reeve/integrations.rb` (module, `inside?`, `require_version!`)
- [x] T006 Generalize the fast-mcp install into `Reeve::Integrations.install!(base, extension,
  inheritance:)` in `lib/reeve/integrations.rb`: include `Guard`, mark base `reeve_abstract!`,
  prepend `inheritance` to the base's singleton, wrap existing subclasses (`subclasses`
  recursively on 3.1+, `ObjectSpace.each_object(base.singleton_class)` on 3.0), skip a class
  already wrapped. Make `lib/reeve/fast_mcp.rb` require `integrations.rb` instead of defining
  the module itself; `spec/reeve/integrations/fast_mcp_spec.rb` stays green unchanged
- [x] T007 Failing specs in `spec/reeve/integrations_spec.rb`: `Reeve.invoke(tool: K)` with no
  block calls `K.reeve_run(arguments)` when `K` responds to it, and falls back to
  `tool.new.call(**arguments)` otherwise (0.9.0 behavior, existing specs green); then add the
  hook to `run` in `lib/reeve/authorization.rb` (R11)

**Checkpoint**: full suite green on SQLite; fast-mcp behavior unchanged.

---

## Phase 3: User Story 5 - Resolve the principal without recording secrets (P1) 🎯 MVP part 1

**Goal**: an invocation carries request data the resolver can read and the ledger never sees.
**Independent test**: a resolver reads `context.request[:token]`; the row contains no trace of
the token; the next call on the thread sees `{}`.

- [x] T008 [P] [US5] Failing specs in `spec/reeve/context_spec.rb`: `request` defaults to `{}`,
  is frozen, absent from `to_h` and `inspect`; `clear_request!` empties it
- [x] T009 [P] [US5] Failing specs in `spec/reeve/invocation_spec.rb`: US5 scenarios 1–3; the
  resolver sees `request`; after allow, deny (each `DeniedError` kind) and a raising tool the
  next invocation on the thread sees `{}`; the recorded row, `DeniedError#message` and
  `Reeve::Testing` report output contain none of the planted values (a unique string, a user
  double, a nested token hash); `metadata:` still recorded and redacted as in 0.9.0
- [x] T010 [US5] Add `request` and `clear_request!` to `lib/reeve/context.rb`; clear it next to
  `clear_principal!` in the ensure of `lib/reeve/invocation.rb`
- [x] T011 [US5] `request:` keyword on `Reeve.invoke` in `lib/reeve/authorization.rb` and on
  `Inventory#dispatch` (and `dispatch_unbound`) in `lib/reeve/inventory.rb`, passed to the
  context; specs in `spec/reeve/inventory_spec.rb` for the dispatch path; contract
  contracts/request-data.md holds

**Checkpoint**: core change complete and releasable alone; every 0.9.0 spec green.

---

## Phase 4: User Story 1 - Guard a tool on the official SDK (P1) 🎯 MVP part 2

**Goal**: one require, `guard_with`, `scoped`; every SDK tool call goes through the envelope.
**Independent test**: a guarded tool on an `MCP::Server`, `tools/call` as two principals through
`server.handle_json`, responses and ledger checked.

- [x] T012 [P] [US1] Failing specs in `spec/reeve/integrations/mcp_spec.rb` driving a real
  `MCP::Server` via `handle_json`: US1 scenarios 1–5 (scoped allow; unscoped deny
  `unscoped_derived_result` with no invoice data in the response; `authorize!` deny with the
  rule, no record id, writes rolled back; `no_principal` with the body not run; raising tool
  recorded `tool_error` and the SDK's internal error unchanged); denial shape is
  `{content: [{type: "text", text: ...}], isError: true}` (contracts/mcp-adapter.md)
- [x] T013 [P] [US1] Failing specs in `spec/reeve/integrations/mcp_spec.rb` for FR-020: tools
  declaring `server_context:`, not declaring it, and taking `**rest` each receive exactly what
  they receive with the adapter absent (compare against an unwrapped twin defined on a plain
  class with the same `call`)
- [x] T014 [P] [US1] Failing specs in `spec/reeve/integrations/mcp_spec.rb` for US1 scenario 7
  and FR-004/FR-011/FR-012/FR-013: a tool defined before `require "reeve/mcp"` is guarded;
  requiring twice (and calling `install!` again) writes one row per call; ledger `tool_name` is
  the published `tool_name`; agent from `client_info` (`name version`), `unknown` when absent;
  metadata holds only `client`; `server_context` and `auth_info` reach the resolver via
  `request` and appear in no row; a loaded version outside the range raises naming it (stub
  `Gem.loaded_specs`)
- [x] T015 [US1] Create `lib/reeve/integrations/mcp/context_builder.rb`: from the tool class and
  `server_context`, build `tool:` name, `agent:`, `metadata:` (`client` only) and `request:`
  (`server_context`, `auth_info`) per data-model.md
- [x] T016 [US1] Create `lib/reeve/integrations/mcp/tool_extension.rb`: singleton-prepended
  `call(*args, **kwargs, &block)` that pops `server_context`; runs `super` directly when
  `Integrations.inside?(name)`; else `Reeve.invoke(**ContextBuilder...) { super(...) }`,
  forwarding `server_context` only when `method(:call).super_method` would have received it
  under the SDK's rule (cache per class); rescues `DeniedError` into an error `Response`;
  re-raises everything else. Define `reeve_run(arguments)` and extend `Guard::ClassHelpers`
- [x] T017 [US1] Create `lib/reeve/mcp.rb`: require `mcp` (missing: `ConfigurationError`
  naming the gem and pointing to `Reeve.invoke`, FR-002), `require_version!("mcp", ">= 1.0",
  "< 2.0")`, require the two files, `Integrations.install!(MCP::Tool, ...)`
- [x] T018 [US1] In `spec/reeve/integrations/mcp_spec.rb` (subprocesses, as fast-mcp's load
  check does): a tool defined before the require is guarded; the version gate; a missing gem;
  a clear error when fast-mcp loaded first and hid the SDK's classes (see research R13). Was: `require "reeve/mcp"` alone loads; the core
  and `reeve/fast_mcp` load without `mcp` present; with both adapters loaded neither wraps the
  other's tools (spec edge case)

**Checkpoint**: Stories 1 and 5 pass on Ruby 3.0 (if T001 allowed), 3.2, 3.4.

---

## Phase 5: User Story 4 - Guard a block-registered SDK tool (P3)

**Goal**: block tools are denied until guarded, and guarded on the class the server holds.
**Independent test**: `server.define_tool` block called before and after `guard_with`.

- [x] T019 [US4] Specs in `spec/reeve/integrations/mcp_spec.rb`: US4 scenarios 1–2 for both
  `server.define_tool` and `MCP::Tool.define`; the block runs with the class as `self`, so
  `scoped` works inside it; unguarded under `:allow_with_warning` is allowed with the warning.
  No lib change expected; if one is needed, it goes in `lib/reeve/integrations/mcp/tool_extension.rb`

**Checkpoint**: block tools and class tools behave the same.

---

## Phase 6: User Story 3, SDK half - Prove it in CI (P2)

**Goal**: the testing kit runs SDK tools with the lines a fast-mcp host writes.
**Independent test**: `Reeve::Checks.run_all`, `deny_access_for`, `audit_every_call` and the
Minitest assertions against a guarded and an unguarded SDK tool.

- [x] T020 [P] [US3] Failing specs in `spec/reeve/testing/adapter_parity_spec.rb` (SDK section):
  US3 scenarios 1–3 without a custom `invoke:`; exactly one row per kit call (pass-through
  holds); RSpec matchers and Minitest assertions give identical results (FR-052, reuse the
  harness in `spec/reeve/testing/minitest_front_end_spec.rb`); `MCP::Tool` itself is not
  reported by `GuardDeclared`
- [x] T021 [US3] Make whatever T020 shows failing pass, in `lib/reeve/testing/checks/base.rb` or
  the SDK `reeve_run`; tool enumeration for the suite picks up `MCP::Tool` descendants like
  fast-mcp's

**Checkpoint**: SC-004 holds for the SDK.

---

## Phase 7: SDK documentation (releasable as a minor version)

- [x] T022 [P] README: an "Official MCP SDK" section per quickstart.md and
  contracts/mcp-adapter.md: require, resolver examples (`server_context`, `auth_info`), class
  and block tools, "`guard_with` plus `scoped`", the one-flag weakness in the words of "Not
  guaranteed" item 2 (FR-060), verified version and range, Ruby support (FR-061), what the
  client receives; a "Request data" subsection for `request:`; keep `spec/readme_spec.rb` green
- [x] T023 [P] CHANGELOG "Unreleased": the SDK adapter, `request:` on `Reeve.invoke` and
  `dispatch`, the `reeve_run` runner hook, and in plain words that requiring `reeve/mcp` under
  `:deny` refuses every unguarded SDK tool, block tools included (R3), with
  `:allow_with_warning` as the migration path. No consumer project named

**Checkpoint**: Stories 1, 3 (SDK), 4, 5 shippable.

---

## Phase 8: User Story 2 - Guard a tool on ActionMCP (P2)

**Goal**: one require, `guard_with`, `scoped` in `perform`; principal from `Current.user`.
**Independent test**: an ActionMCP tool with `guard_with`, `ActionMCP::Current.user` set, called
through `Tool#call` as the server does.

- [x] T024 [P] [US2] Failing specs in `spec/reeve/integrations/action_mcp_spec.rb`: US2
  scenarios 1–5 (scoped allow returns rendered content; unscoped deny renders nothing and
  names `unscoped_derived_result`; raising `perform` recorded `tool_error` before ActionMCP's
  generic message, which is unchanged; `authorize!` denial shows the rule, not "unexpected
  error"; `ToolExecutionJob` path with no user denied `no_principal` and recorded); every
  denial asserts the response has no content the tool rendered before denying (FR-031)
- [x] T025 [P] [US2] Failing specs in `spec/reeve/integrations/action_mcp_spec.rb` for edge
  cases and shared FRs: `request_input!` recorded `tool_error`, nothing leaks; a halting
  `before_perform` writes no row; `abstract!` subclass not a tool to `GuardDeclared`; a tool
  defined before the require is guarded; double install records once; ledger arguments are the
  tool's attributes with `redact` applied; agent from the session, session id not recorded (research R7); `session`
  and `execution_context` only in `request`; tool error reported by the tool itself (not
  raised) survives the buffer merge; outside-range version refused
- [x] T026 [US2] Create `lib/reeve/integrations/action_mcp/context_builder.rb` (name, agent,
  `metadata` with `client` only, `request` with `session` and `execution_context`)
- [x] T027 [US2] Create `lib/reeve/integrations/action_mcp/tool_extension.rb`: prepended
  protected `perform` per research R8 (buffer, envelope inside the rescue, merge on allow,
  denial reported on the real response, restore in `ensure`); pass-through when `inside?`;
  wrap `abstract!` to also mark `reeve_abstract!` (R12); `reeve_run(arguments)` per R11
- [x] T028 [US2] Create `lib/reeve/action_mcp.rb`: require `action_mcp` (missing:
  `ConfigurationError`, FR-002), `require_version!("actionmcp", ">= 0.200.0", "< 0.204")`,
  `Integrations.install!(ActionMCP::Tool, ...)`, mark existing abstract subclasses; load checks
  in `spec/reeve/integrations/action_mcp_spec.rb` as T018 did for the SDK

**Checkpoint**: Story 2 passes on Ruby 3.2 and 3.4.

---

## Phase 9: User Story 3, ActionMCP half - Prove it in CI (P2)

- [x] T029 [US3] ActionMCP section of `spec/reeve/testing/adapter_parity_spec.rb`: as T020, plus
  `reeve_run` raises `ArgumentError` naming the tool on invalid input; fix in
  `lib/reeve/integrations/action_mcp/tool_extension.rb` what fails. SC-004 across all three
  adapters with the same host-written lines. Found: fast-mcp opened a second envelope under the
  kit (no principal there); fixed with the same pass-through in its wrapper

**Checkpoint**: SC-004 holds everywhere.

---

## Phase 10: Polish & cross-cutting

- [x] T030 [P] CI floor job in `.github/workflows/ci.yml`: Ruby 3.4 with `MCP_VERSION=1.0.0`
  and `ACTIONMCP_VERSION=0.200.0` (R13); confirm the matrix skips ActionMCP on 3.0 with the
  stated reason
- [x] T031 [P] README "ActionMCP" section per contracts/action-mcp-adapter.md: resolver,
  background tasks and `no_principal`, halted callbacks write no row, `request_input!`, version
  range and Rails 8.1 / Ruby 3.2+ (FR-061); the comparison of the three adapters states
  per-record narrowing is fast-mcp only; keep `spec/readme_spec.rb` green
- [x] T032 [P] CHANGELOG: the ActionMCP adapter and its version ceiling policy (a Reeve patch
  per verified ActionMCP minor)
- [x] T033 Full suite on SQLite and PostgreSQL (`bundle exec rspec`, `DB=postgresql DB_HOST=/tmp
  bundle exec rspec`) on Ruby 3.3 locally (no 3.0 installed), `bundle exec rubocop`; MySQL
  and 3.2 through CI (SC-003)
- [x] T034 Build the gem, unpack it to the OS temp dir, and check the packaged files: both
  adapters and their `integrations/` files are present, the README's adapter claims match
  "What this feature guarantees" (SC-005)
- [x] T035 Cold read of the two README sections: set up each adapter and predict what a denied
  and an unscoped call return from those alone (SC-001); fold the findings back into the docs. Done: verdict "yes with
  scars"; folded in one row per call, nil resolver means `no_principal`, what
  `:allow_with_warning` does, Ruby support, the error class. Found: per-request servers that
  call `define_tool` grow the registry; documented (define block tools once at boot)

---

## Dependencies & execution order

- **Setup (T001–T003)**: T001 first; it decides T002's Gemfile shape and whether T003 exists.
- **Foundational (T004–T007)** blocks every story. T006 needs T005's module file.
- **US5 (T008–T011)** before US1: the SDK resolver needs `request`.
- **US1 (T012–T018)** → **US4 (T019)** → **US3 SDK (T020–T021)** → **SDK docs (T022–T023)**.
- **US2 (T024–T028)** needs only Foundational and US5; it can start after Phase 3, but shares
  `spec/load_safety_spec.rb` and the parity spec with the SDK work, so run it after Phase 7.
- **US3 ActionMCP (T029)** after US2. **Polish** after the stories it documents.

Within a story: the failing spec first, then the implementation, then the story's checkpoint.

## Parallel opportunities

- Phase 2: T004 and T005 together; T007 alongside either.
- Phase 3: T008 and T009 written together; T010 → T011.
- Phase 4: T012, T013, T014 written together (one file, independent examples); T015 → T016 →
  T017 one at a time.
- Phase 7: T022 and T023 together. Phase 8: T024 and T025 together.
- Phase 10: T030, T031, T032 together.

## Implementation strategy

- **MVP**: US5 + US1 (Phases 1–4). Not released alone: US4 (block tools) and the CHANGELOG
  warning about unguarded tools being refused must ship with it, or a host upgrades into
  denied block tools with no word of why.
- **First release**: Phases 1–7, a minor version: the SDK adapter, request data, testing-kit
  parity, docs.
- **Second release**: Phases 8–10, ActionMCP. Its ceiling (`< 0.204`) is rechecked against the
  latest ActionMCP right before release.
- One builder at a time: the stories share `mcp_spec.rb`, the parity spec and
  `load_safety_spec.rb`. Commit at each checkpoint.
