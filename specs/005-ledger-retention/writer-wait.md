# Writer-wait during a purge, measured out of process

Follow-up to SC-004 of this spec. Frozen before build; changes are recorded below, never drifted.

## Problem

The SC-004 benchmark measured writer latency during a 1,000,000-entry purge with a writer
*thread* in the purge's own process. That thread shares Ruby's GVL with the purge's HMAC work,
so its slowest writes (441 ms SQLite, 1,774 ms PostgreSQL) mix GVL waits with database waits.
The claim under test, "the purge holds no lock writers queue on longer than one batch", needs a
writer that only the database can slow down.

## Contracts

- **C1** The example "purges 1,000,000 entries while writes continue, and verifies only the
  rest" in `spec/reeve/audit/chain/benchmark_spec.rb` keeps its tag (`:benchmark_large`), its
  name, and `REEVE_PURGE_SIZE`. Its in-process writer thread is removed.
- **C2** The writer is a separate OS process started with `Process.spawn` (not fork, not a
  thread): its own Ruby VM, the same bundle, the same database configuration as the spec's
  `ActiveRecord::Base` (SQLite: the same file; server engines: the application role, not the
  retention role), the spec ledger key, and writes through `Chain#append!` as before.
- **C3** Order: start the writer; wait until it has made its first write (fail after 60 s);
  let it write alone for a baseline of at least 3 s; run the purge; stop the writer with a
  signal; wait for it to exit (fail after 30 s, killing it).
- **C4** The writer records, per write, its start on `CLOCK_MONOTONIC` and its duration. Writes
  are classed by start time: *baseline* (before the purge started), *during* (from purge start
  to purge end), *after* (counted, not reported).
- **C5** One report line: engine, size, purge seconds; for baseline and for during: count,
  median, p99 and max in ms.
- **C6** Assertions only on correctness, never on latency (benchmark policy, spec_helper):
  writer exited 0 with no error; the purge result is `purged`; at least one write started
  during the purge; verification afterwards is INTACT and covers exactly
  `(size + 1)..(size + every write the writer made)`.
- **C7** A write that raises in the writer is recorded with its message, the writer exits
  non-zero, and the example fails showing that message.
- **C8** SC-004's note in `spec.md` is replaced by the out-of-process figures for SQLite and
  PostgreSQL at 1,000,000 entries; MySQL is stated as unmeasured (no local server; CI does
  not run `:benchmark_large`).

## Inputs the work must cover (hard rule 6)

- Engines: SQLite (run), PostgreSQL (run), MySQL (unmeasured, stated).
- Sizes: `REEVE_PURGE_SIZE` small (smoke) and 1,000,000 (recorded).
- Writer states: never ready, raising, refusing to stop, exiting early.
- Write classes: baseline, during, after; a run with zero writes during the purge.
- Clock: child and parent timestamps on the same monotonic clock.

## Out of scope

Changing the purge. If the out-of-process figures contradict SC-004 (a writer waiting longer
than one delete batch, beyond baseline noise), stop and report; a fix is a separate decision.

## Done

The example passes at a small `REEVE_PURGE_SIZE` on SQLite and PostgreSQL; the 1,000,000 runs
are recorded in SC-004; rubocop clean; the default suite unchanged.

## Spec changes

- **2026-11-05, after the first review (C3, C4):** the writer's first write opens its connection
  and reads the schema, so it is left out of the baseline (still counted for coverage). A writer
  that fails before or during the baseline fails the example before the purge starts, with its
  own error.
- **2026-11-05, after the second round (C3, C6):** a writer that has exited by the time the purge
  ends, with any status, fails the example; an exit 0 mid-purge had passed with a fraction of
  the purge measured. The writer loads the repository's `lib` itself, not only through Bundler.
