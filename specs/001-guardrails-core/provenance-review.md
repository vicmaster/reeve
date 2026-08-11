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

**Status: RESOLVED in git, with one residual noted below.** On the maintainer's
instruction (2026-08-11) the names were redacted from history:

- Every historical blob was rewritten: the possessive phrase became "any employer or
  client codebase", the bare employer name became "an employer", and an early gemspec
  carrying a work email had it replaced with the maintainer's personal address. The
  redacted sentences still read correctly at each historical commit.
- Backup refs were dropped, the reflog expired and the object store repacked, then every
  remaining object was scanned: no blob contains the employer name, and none contains the
  product name as a whole word.
- `main`, `001-guardrails-core` and the `kernel-frozen` tag were force-pushed. Every
  commit SHA from before the rewrite is therefore obsolete; the tag now points at the
  rewritten kernel commit.
- A full backup of the pre-rewrite history is kept outside the repository, so nothing was
  destroyed irrecoverably.

**Residual: GitHub still serves the old objects by SHA.** A force-push makes the old
commits unreachable, but GitHub retains unreachable objects until it garbage-collects, and
until then anyone holding an old commit or blob SHA can still fetch it through the API or
the web UI. Verified as still resolvable immediately after the push. Two ways to finish
the job, both the maintainer's call:

1. **Ask GitHub Support to garbage-collect the repository** — the documented remedy for
   removing sensitive data, and it keeps the repository's identity, history of issues and
   any external links intact.
2. **Delete and recreate the repository**, pushing only the rewritten history. Immediate
   and complete. Cheap here specifically: at the time of writing the repository has 0
   stars, 0 forks, 0 watchers and no issues or pull requests, so nothing is lost but the
   creation date.

Until one of those is done, treat the redaction as complete for anyone browsing the
repository normally, and incomplete against anyone who already recorded a SHA.

## Everything else: PASS

Subject to the finding above, this repository satisfies Principle V. No code, class or
method names, database schemas, migration structures, configuration shapes, or copied
documentation from any employer or client system entered it.
