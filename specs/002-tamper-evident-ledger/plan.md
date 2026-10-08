# Implementation Plan: Tamper-Evident Audit Ledger

**Branch**: `002-tamper-evident-ledger` | **Date**: 2026-10-07 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/002-tamper-evident-ledger/spec.md`

## Summary

Link every ledger entry reeve writes to its predecessor with an HMAC-SHA256 digest. The
digest is computed with a key the database does not hold: by default it is derived from the
application's `secret_key_base`. Add a verifier that walks the chain in constant memory and
reports every break, in a form that cannot be mistaken for a pass when it does not cover
the whole ledger.

Writes serialize through a one-row chain record using "update first, then read", the one
locking pattern that behaves the same on SQLite, PostgreSQL and MySQL. Entries are
normalized before they are written, so what the database returns is what was digested, up
to key order and number formatting, which canonicalization absorbs.

The feature ships as audit-entry contract 3, through `reeve:upgrade`. It adds
`bin/rails reeve:verify_ledger` and a `LedgerChain` check in both compliance suites. No
runtime dependency is added. Target release: **0.6.0**.

## Technical Context

**Language/Version**: Ruby 3.0+ (CI 3.0 / 3.2 / 3.4), Rails 7.0+ for the generators,
Railtie and rake task
**Primary Dependencies**: none added. `openssl` (stdlib) for HMAC; ActiveRecord /
ActiveSupport already optional dependencies of `reeve/audit`
**Storage**: host-owned `reeve_audit_entries` (+3 nullable columns, +1 unique index) and new
host-owned `reeve_audit_chains` (one row)
**Testing**: RSpec in this repo. Every chain spec runs on SQLite, PostgreSQL and MySQL via the
existing `DB=` harness (`spec/support/optional/database.rb`); concurrency specs run on
PostgreSQL and MySQL. Testing-kit parity through the existing RSpec/Minitest front-end
specs.
**Target Platform**: Rails applications exposing MCP tools; verification also usable from
plain Ruby with ActiveRecord
**Project Type**: single library (rubygem)
**Performance Goals**: SC-004 (1M entries verified < 5 min, flat memory). SC-005 (≤ 5 ms
added to the median uncontended ledger write) is a target to confirm by benchmark first (T0);
revise it in the spec if 0.5.0's baseline makes it unrealistic, rather than miss it quietly.
**Constraints**: fail closed (`:fail` default); no reported pass beyond what was verified;
no update or delete of any ledger row; `require "reeve"` loads without Rails or ActiveRecord;
`require "reeve/testing"` loads without ActiveRecord
**Scale/Scope**: 10 new library files, about 12 modified, one new migration template;
estimated 700–1,000 LOC of library code and a similar volume of specs

## Constitution Check

*GATE: evaluated before Phase 0 and re-evaluated after Phase 1.*

| Principle | Gate | Status |
|---|---|---|
| I. Deny by Default | Every new uncertainty fails closed | ✅ No key, missing columns, lock timeout → `AuditWriteError` under `:fail` (R8). Verification never reports `intact` for what it did not check (data-model status rules). |
| II. Every Call Leaves a Trace | Chaining must not create a path where a call runs unrecorded by default | ✅ New failure modes go through `handle_write_failure`. `:warn` with no key still writes the row, unchained and flagged (R8), which keeps more of the trace than 0.5.0 keeps for a failed write. |
| III. Provable by Test (NON-NEGOTIABLE) | The guarantee is assertable from both frameworks; test-first | ✅ `LedgerChain` in `Checks::ALL` (R10). Every detected and every undetected class pinned by a spec (SC-001). Regression specs verified by reverting the fix. |
| IV. Extension Layer | No new dependency; positioning check | ✅ stdlib `openssl` only. Positioning check: no Ruby gem chains an ActiveRecord ledger (R13). |
| V. Clean-Room Provenance (NON-NEGOTIABLE) | Original names and schema; public prior art only | ✅ Hash-chained secure audit logs are long-published prior art. Table, column and class names are original to this repo. |
| VI. Boring DX | Adoption stays three steps; new config needs a demonstrated need | ✅ with justification: two settings and a Railtie (Complexity Tracking). The default key derivation keeps adoption at three steps with no new secret. |

**Post-design re-check** (after research.md, data-model.md, contracts/, quickstart.md): ✅
PASS. The design adds one table and a Railtie, both justified below. No NON-NEGOTIABLE
principle is touched by a trade-off.

## Spec amendments made during planning

Recorded in spec.md under "Amended during planning". The first three each remove a claim the
design could not back up honestly. The fourth removes a cost.

1. **Genesis is link 0 in the chain record, not a ledger row** (R4). A genesis row would give
   one invocation two rows and break `AuditCoverage`'s one-row-per-invocation guarantee.
2. **One `digest_mismatch` kind instead of "content altered" vs "link broken"** (R6). A failed
   digest cannot say which of content, position or predecessor changed; the report says so.
3. **A changed pre-chain count is reported, not a break** (R5). Rolling deploys legitimately
   add uncovered rows after the chain starts.
4. **Key derived from `secret_key_base` by default** (R7). Satisfies "outside the database" in
   every environment with no new secret. The cost is coupling to `secret_key_base` rotation,
   which is documented where the line is added.

## Project Structure

### Documentation (this feature)

```text
specs/002-tamper-evident-ledger/
├── spec.md
├── plan.md                    # this file
├── research.md                # R1–R13
├── data-model.md              # columns, chain record, canonical form, result
├── quickstart.md              # install, upgrade, verify, rotate
├── contracts/
│   ├── ledger-chain.md        # config, append!, verify, rake, check, errors
│   └── audit-entry-v3.md      # delta to 001's audit-entry contract
├── verification.md            # SC → spec map, as in 001 (written during implementation)
├── checklists/requirements.md
└── tasks.md                   # /speckit.tasks
```

### Source Code (repository root)

```text
lib/reeve.rb                                   # + require railtie when Rails::Railtie is defined
lib/reeve/configuration.rb                     # + ledger_key, retired_ledger_keys, ledger_key_id
lib/reeve/errors.rb                            # + LedgerKeyError
lib/reeve/ledger_key.rb                        # NEW: key validation + fingerprint (openssl loaded lazily, so
                                               #      `require "reeve"` keeps its stdlib allowlist)
lib/reeve/railtie.rb                           # NEW: registers tasks only
lib/reeve/tasks.rb                             # NEW: reeve:verify_ledger (Ruby, not .rake — R9)
lib/reeve/audit.rb                             # CONTRACT_VERSION 3; "what it does not" rewritten
lib/reeve/audit/chain.rb                       # NEW: Chain#append!, Chain.verify
lib/reeve/audit/chain/keyring.rb               # NEW: fingerprints, lookup by key id
lib/reeve/audit/chain/normalizer.rb            # NEW: pre-write JSON/time normalization (R2)
lib/reeve/audit/chain/canonical.rb             # NEW: canonical form + digest (R1, R2)
lib/reeve/audit/chain/verifier.rb              # NEW: record, head, genesis and unchained checks (R6)
lib/reeve/audit/chain/walk.rb                  # NEW: the keyset row-by-row walk, split from the verifier
lib/reeve/audit/chain/verification.rb          # NEW: result, Break, to_s, as_json
lib/reeve/audit/chain_record.rb                # NEW: model for reeve_audit_chains
lib/reeve/audit/recorder.rb                    # writes through Chain; :warn/no-key path; column check
lib/reeve/audit/isolated_recorder.rb           # comment only: chain lock held for one insert
lib/reeve/testing/ledger.rb                    # + verify_chain (lazy, AR-free when absent)
lib/reeve/testing/checks.rb                    # + LedgerChain in ALL and GLOBAL
lib/reeve/testing/checks/ledger_chain.rb       # NEW
lib/reeve/testing/checks/contract_version.rb   # COLUMNS + EXPECTED_VERSION = 3
lib/generators/reeve/install/templates/create_audit_entries.rb.tt   # contract 3 + chain table
lib/generators/reeve/install/templates/initializer.rb.tt            # + ledger_key line
lib/generators/reeve/upgrade/upgrade_generator.rb                   # + contract-3 step, prints key line
lib/generators/reeve/upgrade/templates/add_ledger_chain_to_reeve_audit_entries.rb.tt  # NEW

spec/reeve/audit/chain/keyring_spec.rb
spec/reeve/audit/chain/canonical_spec.rb       # awkward-value corpus, all engines (SC-002)
spec/reeve/audit/chain/append_spec.rb          # sequencing, replay, rollback, genesis race
spec/reeve/audit/chain/concurrency_spec.rb     # 8 × 1,000 writers, PG/MySQL (SC-003)
spec/reeve/audit/chain/tamper_spec.rb          # every Detected and Not-detected class (SC-001)
spec/reeve/audit/chain/verifier_spec.rb        # statuses, wording, caps, head-at-start (SC-006)
spec/reeve/audit/chain/restore_spec.rb         # same-engine dump/restore with new ids
spec/reeve/audit/chain/benchmark_spec.rb       # tagged :benchmark, run on demand (SC-004/005)
spec/reeve/audit/recorder_spec.rb              # + key/no-key × fail/warn matrix
spec/reeve/generators/*_spec.rb                # + contract-3 step, idempotence, key line
spec/reeve/testing/checks_spec.rb              # + LedgerChain pass/fail/skip
spec/reeve/tasks_spec.rb                       # exit statuses, LIMIT, FORMAT=json
spec/reeve/testing/framework_neutrality_spec.rb  # + gemspec.files includes tasks.rb, railtie.rb, new template
spec/reeve/verification_spec.rb                # + covers specs/002-*/verification.md (SC-001..SC-007)

specs/001-guardrails-core/contracts/audit-entry.md   # apply audit-entry-v3.md
specs/001-guardrails-core/contracts/configuration.md # + two settings
specs/001-guardrails-core/contracts/testing-kit.md   # + LedgerChain
README.md, CHANGELOG.md                              # guarantees section, verbatim in substance
```

**Structure Decision**: same single-gem layout as 001. Chain logic lives under
`lib/reeve/audit/chain/` because it is part of the opt-in ledger boundary
(`require "reeve/audit"`). The testing kit reaches it only through `Testing::Ledger`, which
keeps the kit's load-safety guarantee.

## Delivery Order

Story-by-story with a commit checkpoint after each, per the constitution. `/speckit.tasks`
expands these.

0. **Benchmark first.** Measure 0.5.0's ledger write on each engine, then fix or revise
   SC-005 before writing chain code.
1. **Foundation**: configuration and keyring; normalizer and canonical form with the
   awkward-value corpus green on all three engines. This is the highest-risk piece, so it is
   proven before anything depends on it. Then the schema (install template, chain record
   model), and the initializer's `ledger_key` line plus the spec harness and quickstart keys,
   so every checkpoint from the first chained write onward is green.
2. **US1 (P1)**: `Chain#append!`, then `Recorder` and `IsolatedRecorder` through it;
   sequencing, replay and rollback specs; concurrency spec; the verifier's walk; tamper spec
   for the Detected list.
3. **US2 (P1)**: status rules, the output wording and SC-006's "no intact without coverage"
   assertion; tamper spec for the Not-detected list; unknown and retired keys.
4. **US3 (P2)**: upgrade step and template; missing-column error; `:warn` with no key;
   rolling-deploy spec (contract-2 rows written after genesis).
5. **US4 (P2)**: `LedgerChain` check and parity across both front-ends; Railtie, rake task and
   exit statuses; the `gemspec.files` assertion extended, plus one `gem build` and a grep of
   the packaged file list before release.
6. **Docs and release prep**: the 001 contract documents, the README guarantees section, the
   CHANGELOG with upgrade steps and the key-rotation warning. `verification.md` mapping each
   success criterion to its spec, enforced by `verification_spec.rb` as 001's is.
   `/code-review` before merge,
   reviewing `canonical.rb` and `chain.rb` the way `scoper.rb` was reviewed in 0.1.0.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Canonical form misses a database normalization, so untampered rows report as broken | Medium. This is where the feature will be wrong first. | Normalize before writing (R2); corpus on all three engines; a false break is loud, never a false pass |
| Chain lock serializes a host's guarded calls inside long host transactions | Medium for hosts with request-wide transactions | Documented next to the existing warning; `IsolatedRecorder` is the answer; benchmark shows the cost |
| Hosts rotate `secret_key_base` and lose verifiability of old entries | Low–medium | Warning at the initializer line, in the upgrade output, in the README; entries become unverifiable, never "tampered" |
| A regression spec that passes vacuously | Known from 0.1.0 | Each tamper spec verified red by disabling the check it covers |
| Rake task or template missing from the built gem | Known trap (`spec.files`) | Task in `.rb` (R9); `gemspec.files` assertion; grep of the built `.gem` before release |

## Complexity Tracking

| Addition | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| New table `reeve_audit_chains` | One serialization point that works the same on all three engines, and a home for the genesis that is not an invocation row | A genesis row gives one invocation two rows (breaks `AuditCoverage`); `MAX(seq)+1` races; advisory locks are three dialects (R3, R4) |
| `Reeve::Railtie` | The rake task the spec requires (FR-017) | A documented `Rake::Task` snippet to paste: un-boring, and it drifts from the gem |
| Two settings (`ledger_key`, `retired_ledger_keys`) | The key must come from outside the database (FR-008), and rotation needs verification-only keys (FR-011) | Host-named key IDs or a key hash: more surface and an extra way to orphan history (R7) |
