# Clean-room provenance review

**Date**: 2026-08-11 | **Task**: T067 | **Constitution**: Principle V (NON-NEGOTIABLE)

Reviewed before publication: the working tree, the packaged gem, and the full git history
of both public branches.

## What was checked

| Check | Method | Result |
|-------|--------|--------|
| Employer or client names in tracked files | case-insensitive `git grep` for the employer and product names | Clean — only false positives on an English word containing one of them |
| Employer names anywhere in history | `git log --all -S<term>` for each term | **One finding**, below |
| The local planning brief | `git log --all --diff-filter=A -- PROJECT-BRIEF.md` | Absent from history (purged 2026-08-11); gitignored; never tracked |
| Launch/strategy notes (token budgets, launch plans) | `git log --all -S` per term | Clean — zero commits |
| What the built gem ships | unpacked `reeve-0.0.1.gem` | `lib/` + README, CHANGELOG, LICENSE only. No specs, no `specs/`, no `.specify/`, no dummy app |
| Schema and API naming | manual review | Original: `reeve_audit_entries`, `Guard`, `Registry`, `Scoper`, `Recorder`, `Redactor`, `Decision`, `ScopeResult`. Policy objects, scopes and ledger tables are publicly-known patterns, independently expressed |
| Third-party code | manual review | None vendored. Pundit and fast-mcp are spoken to by convention, never copied |

## Finding: an employer's internal system is named in git history

Commit `c7061d9` ("chore: initialize spec-kit scaffolding and project brief") contains, in
the then-current `.specify/memory/constitution.md`:

> copied documentation from proprietary systems (**including <employer>'s <product>**) may
> enter this repository.

(The names are elided here on purpose: this document is published, and reproducing them
would defeat the removal it describes.)

Commit `ada8793` generalised that wording to "any employer or client codebase" before the
repository was published, so **the current tree is clean**. The earlier text remains
reachable in history from both `main` and `001-guardrails-core`, which are public.

**Assessment.** No proprietary code, schema, or documentation was ever committed — this is
a clean-room *commitment* that happens to name the system it was written about. The
disclosure is the existence of a named internal system at the author's employer, and the
author's association with it. That is mild, and in one reading it is evidence of
diligence rather than a leak.

It is nonetheless the same class of disclosure that motivated purging `PROJECT-BRIEF.md`
from history, so consistency argues for removing it too.

**Status: OPEN — the maintainer's decision.** Removing it means rewriting the history of
two already-pushed public branches and force-pushing, which is outward-facing and cannot
be undone for anyone who has already cloned. Not to be done without an explicit
instruction. The options:

1. **Purge and force-push** — `git filter-branch`/`filter-repo` over the one file, as was
   done for the brief, then force-push `main` and `001-guardrails-core`. Consistent with
   the earlier decision; invalidates existing clones and any commit SHAs referenced
   elsewhere.
2. **Leave it** — the current tree is clean, no proprietary material was ever committed,
   and the naming is a diligence note rather than a disclosure of substance.

Until this is decided, Principle V's publication gate is **not** signed off.

## Everything else: PASS

Subject to the finding above, this repository satisfies Principle V. No code, class or
method names, database schemas, migration structures, configuration shapes, or copied
documentation from any employer or client system entered it.
