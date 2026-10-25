# Agent Instructions

Brief, direct: explain only when asked. No platitudes, no em dashes, no AI slop. Simple terms; less text is better.

## Commits (only when asked; atomic)
- Title: imperative, <= 72 chars.
- Body only if the title lacks the why; wrap <= 100 chars; constraint, change, why.
- Squash: bullets only for distinct logical changes; drop trivial ones.
- Never amend, force-push, hard-reset, or rewrite history without explicit approval.

## PRs
Short and non-technical: what changed, not how. No file lists, class/token names, test counts, or implementation notes (those go in commits). No empty template sections. Don't hard-wrap: each paragraph or bullet on one line.
- Changes: a few plain sentences, including whether behavior changed. Deferred items and side changes: one line each.
- Testing: one line on automated checks, then numbered manual verification steps.

## Code
Simple, idiomatic, short descriptive names. KISS, Law of Demeter, SRP, least astonishment. Blank line between logical blocks and after guard clauses. Review the final diff for accidental or unrelated changes.

## Operations
- Calculations: always run a script, never mental arithmetic.
- Temp files: OS temp dir.
- SSH: don't quote whole commands; quote arguments.
- Remote edits: write locally, then `scp`.

## Secrets (never violate)
- `~/.secrets` (and symlinks): write-only. Never read, list, or print.
- `~/.env`, `~/.envrc`, `.env`, `.env.*` (and symlinks): never read, source, or execute.
- Never run `env`, `printenv`, or `dotenvx`, or dump process environment.
- Never expose secret values in logs, diffs, errors, or responses.
