# Verification: which spec proves which criterion

**Date**: 2026-10-10 | **Feature**: 002-tamper-evident-ledger | **Task**: T053

Every success criterion in spec.md, mapped to the spec that proves it. Where a criterion is
only partly proven, that is stated here rather than left for a reader to discover.
`spec/reeve/verification_spec.rb` asserts that every file named below exists, as it does for
001's map.

Engines: every spec under `spec/reeve/audit/chain/` runs on SQLite locally and on
PostgreSQL and MySQL in CI, and on Rails 7.0 / sqlite3 1.7 in CI's Ruby 3.0 job.

## Success criteria

| ID | Criterion | Proven by | Status |
|----|-----------|-----------|--------|
| SC-001 | Every "Detected" tamper class is detected; every testable "Not detected" class is pinned as undetected | `spec/reeve/audit/chain/tamper_spec.rb` (one example per class, each verified red by disabling the check that catches it; the "Not detected" group labels each example NOT DETECTED), `spec/reeve/audit/chain/verifier_spec.rb` (rows past the head) | ✅ |
| SC-002 | An untampered ledger verifies intact on all three engines, including awkward values and after a same-engine dump and restore | `spec/reeve/audit/chain/roundtrip_spec.rb` (17 awkward values, plus a `jsonb` copy of the table on PostgreSQL), `spec/reeve/audit/chain/restore_spec.rb` (the engine's own dump tool, primary keys renumbered), `spec/reeve/audit/chain/append_spec.rb` (defaults and casts signed as stored) | ⚠️ Restore is pending where the engine's dump tool is missing or older than the server — see Known gaps |
| SC-003 | 8 writers × 1,000 invocations produce sequences 1–8,000, gap-free, no deadlock, intact | `spec/reeve/audit/chain/concurrency_spec.rb` (Recorder and IsolatedRecorder, PostgreSQL and MySQL) | ✅ |
| SC-004 | 1,000,000 entries verified in under 5 minutes, memory not growing more than 10% from 100k to 1M | `spec/reeve/audit/chain/benchmark_spec.rb` ("verifying a large ledger", tagged `:benchmark_large`) | ⚠️ Memory flat on both engines. Time met on SQLite (184 s), **missed on PostgreSQL (331 s against 300 s)** — see Measurements |
| SC-005 | Chaining adds no more than 5 ms to the median uncontended ledger write | `spec/reeve/audit/chain/benchmark_spec.rb` ("ledger write cost", tagged `:benchmark`, also run by CI's benchmark step) | ✅ +0.5 ms SQLite, +0.9 ms PostgreSQL (research R3) |
| SC-006 | No output says "intact" or "pass" without the coverage beside it; only an intact chain succeeds | `spec/reeve/audit/chain/verification_output_spec.rb` (every ledger state it builds, every line, text and JSON), `spec/reeve/tasks_spec.rb` (exit statuses), `spec/reeve/testing/checks_spec.rb` (LedgerChain) | ✅ |
| SC-007 | A 0.5.0 host reaches a verified chain in three steps, with no edit to existing rows and no new secret | `spec/reeve/audit/chain/upgrade_spec.rb` (rows byte-identical), `spec/reeve/generators/upgrade_generator_spec.rb` (convergence with a fresh install; the printed key line), `spec/reeve/quickstart_spec.rb` (the task, run in a booted app) | ✅ |

## Measurements

Developer laptop (Apple Silicon), local databases. MySQL's write cost comes from CI's
benchmark step; its large-ledger run was not made — see Known gaps.

| Engine | Write, median (0.5.0 → chained) | Verify 100k | Verify 1M | Peak RSS growth 100k → 1M |
|---|---|---|---|---|
| SQLite | 1.31 → ~1.8 ms | 15.1 s | 183.5 s | 1.8 MB → 0.0 MB |
| PostgreSQL | 1.60 → ~2.5 ms | 18.0 s | **330.7 s** | 4.3 MB → 0.4 MB |

**SC-004 is missed on PostgreSQL.** Memory holds: peak growth is flat from 100k to 1M on
both engines. Time does not: a million entries took 331 s on PostgreSQL against a 300 s
budget, and the time grew faster than the ledger did (10× the rows, 18× the time). The
suspected cause is the walk's keyset query, whose `OR` across `(chain_sequence, id)` likely
keeps PostgreSQL from scanning the index as a plain range; not yet confirmed. It is the next
change, measured again on both engines before release.

**SQLite's memory number needs the memory map off.** Rails sets `mmap_size` to 128 MB, so
the database file's pages count toward resident memory as the walk touches them. That is the
operating system's file cache, not memory reeve holds: with the map on, resident memory
grew steadily through a 300k walk while Ruby's live heap stayed flat; with it off, both
stayed flat. The benchmark measures with the map off on SQLite and says why.
| MySQL (CI) | 1.45 ms (0.5.0) | — | — | — |

## Functional requirements with a dedicated spec

| FR | Proven by |
|----|-----------|
| FR-001 / FR-004 sequence, key id, digest; gap-free | `spec/reeve/audit/chain/append_spec.rb`, `spec/reeve/audit/chain/concurrency_spec.rb` |
| FR-002 / FR-003 digest inputs, canonical form | `spec/reeve/audit/chain/canonical_spec.rb`, `spec/reeve/audit/chain/normalizer_spec.rb`, `spec/reeve/audit/chain/roundtrip_spec.rb` |
| FR-005 / FR-006 one chain, both recorders, three engines | `spec/reeve/audit/chain/concurrency_spec.rb`, `spec/reeve/audit/isolated_recorder_spec.rb` |
| FR-007 custom recorders | `spec/reeve/audit/chain/append_spec.rb` ("a host-supplied recorder") |
| FR-008 / FR-009 / FR-011 keys | `spec/reeve/configuration_spec.rb`, `spec/reeve/audit/chain/keyring_spec.rb`, `spec/reeve/audit/chain/verification_output_spec.rb` (no secret in any output) |
| FR-010 no key × failure mode | `spec/reeve/audit/failure_mode_spec.rb` |
| FR-012 – FR-015 verification | `spec/reeve/audit/chain/verifier_spec.rb`, `spec/reeve/audit/chain/tamper_spec.rb`, `spec/reeve/audit/chain/verification_output_spec.rb` |
| FR-017 Ruby entry point and rake task | `spec/reeve/tasks_spec.rb`, `spec/reeve/railtie_spec.rb`, `spec/load_safety_spec.rb` |
| FR-018 LedgerChain in both suites | `spec/reeve/testing/checks_spec.rb`, `spec/reeve/testing/minitest_front_end_spec.rb`, `spec/reeve/testing/rspec_front_end_spec.rb` |
| FR-019 – FR-022 contract 3, upgrade, initializer, genesis | `spec/reeve/audit/migration_spec.rb`, `spec/reeve/generators/upgrade_generator_spec.rb`, `spec/reeve/generators/install_generator_spec.rb`, `spec/reeve/audit/chain_record_spec.rb`, `spec/reeve/audit/chain/upgrade_spec.rb` |

## Known gaps, stated rather than buried

**Restore without a matching dump tool.** `restore_spec.rb` uses the engine's own dump tool,
because only a real dump sends every value through text. Where the tool is missing or older
than the server (pg_dump refuses a newer server), the example is pending with that reason,
never passed. Locally it needs `REEVE_PG_BIN` pointing at a matching client. Whether CI's
runners have a matching client is visible in the job log: pending there means SC-002's
restore half was not proven by that run.

**MySQL large-ledger measurement.** The local MySQL install does not start, and a
million-row build is too slow for a shared CI runner, so SC-004 was measured on SQLite and
PostgreSQL only.

**Integers beyond double precision on MySQL** do not survive MySQL's `JSON` type, so such a
row fails to verify. Pinned in `roundtrip_spec.rb`; a false alarm, never a false pass.

**Rails 7.0 with SQLite** cannot serialize concurrent writers in one process: sqlite3 1.x
waits for the write lock while holding the GVL. `concurrency_spec.rb` pins what reeve
promises there — contended writes fail closed and the chain that lands is intact — rather
than the gap-free 4 × 100 run it proves on newer Rails.

**A rewritten key id reads as "unverifiable", not as tampering** (code review, finding 3,
left as is). A row whose `chain_key_id` is changed to a fingerprint no configured key has
cannot be checked, so an edit made with it is reported as an entry signed by a key that is
not configured: exit 2, never a pass, but attributed to configuration rather than
tampering. Telling the two apart needs a record of which keys signed which range (a
rotation log), which does not exist yet.

**A ledger on its own database** (code review, finding 6). The chain record is written
through the ledger's connection and read through `ChainRecord`'s. If they point at
different databases, verification refuses with a `ConfigurationError` naming the fix
(connect `ChainRecord` the same way), instead of reading the wrong record and reporting
tampering. A host that moves the ledger must move `ChainRecord` with it.

**One extra read per write** (code review, finding 7, left as is). `Head#start!` looks for
the chain record before every chained write. That read is what keeps the genesis out of the
locked transaction on MySQL; a per-process cache would need invalidating whenever the record
vanishes. The cost is one indexed point read, inside the measured +0.5–0.9 ms.

**The genesis race on MySQL** (research R3) was found by a deadlock in CI and fixed by moving
the genesis out of the first write's transaction. The race is timing-dependent: CI has passed
since the fix, and passed once before it. The case rests on the mechanism, the `UPDATE` that
took the gap lock no longer preceding the insert, and that mechanism is what the fix removes.
