---
description: Run the function-staged sub-agent pipeline on a task — spec frozen first, scouts fan out to read, a single builder writes, verifiers fan out to check, an integration pass closes. Tracks spend per phase.
---

Run the sub-agent pipeline for: $ARGUMENTS

You (this session) are the **orchestrator and the only builder**. Sub-agents read and verify; only you write. These rules are the system — when in doubt, the rule wins over speed.

## Hard rules

1. **One writer per file set.** Only this session edits files. A second writer is allowed only for a genuinely disjoint file set (no shared files, contracts already frozen), in its own worktree session — and that buys wall-clock only, never quality.
2. **Scouts and verifiers never write.** If a sub-agent reports something fixable, the fix comes back here.
3. **Artifacts are the handoff.** Between phases — and across any repo/session boundary — what travels is a complete artifact (spec, brief, report, issue), never "the context so far". A brief must stand alone: objective, where to look, what's known/ruled out, output format.
4. **No phase is skipped**, Integrate least of all. A task too small for the pipeline is a task you do directly — say so and skip the whole ceremony, not individual phases.

## Phases

**0 · Spec — freeze before anyone builds.**
Use the spec-kit flow already in this repo (`/speckit.specify` → `/speckit.clarify` → `/speckit.plan`). The spec must pin the *contracts*: public API, schema/data shapes, error behavior, what "done" verifies. Unknowns that block the spec go to scouts first. The frozen spec is the ground truth every later phase verifies against — changing it mid-build means stopping and re-freezing, not drifting.

**1 · Scout — read wide, bring back conclusions.**
Fan out `scout` agents in parallel, one per independent unknown (codebase area, upstream docs, ecosystem/prior art). Heavy reading belongs here even when you're curious — every long doc read in this session is context the builder drags around for the rest of the task. Fold conclusions into the plan; cite them, don't re-read.

**2 · Build — single-threaded, against the frozen spec.**
You build, in this session, with continuous context. Updating affected docs (README, CHANGELOG, upgrade notes) is part of each change's "done" — the writer of the code change is the writer of its doc change. Record decisions the spec didn't cover as you go; they feed the verify briefs.

**3 · Verify — fan out, falsifiable briefs only.**
Launch `verifier` agents in parallel, one per independent claim set: spec conformance (each acceptance criterion), test adequacy (do the tests fail without the change?), and a review pass on the diff. Launch a `cold-reader` on every doc a stranger must act on (upgrade notes especially), with tasks derived from the doc's claims. Briefs must be falsifiable — "review this" is not a brief; "verify these N claims against these files/commands" is.
Then **re-verify before acting**: a CONFIRMED finding gets checked against source by you before it changes code; PLAUSIBLE findings are triaged, not auto-fixed.

**4 · Integrate — mandatory, always last.**
Full test suite, docs/spec reconciliation (does the spec still describe what shipped?), and a final diff read end-to-end in one sitting. If parallel builders existed, this is where their work merges — conflicts resolved here, deliberately, never by whoever pushed last.

## Budget

Before phase 0, write a budget line per phase (rough token caps; scouts and verifiers per-agent counts — default ≤3 scouts, ≤4 verifiers). After each phase, record actual spend (sub-agent usage is reported on completion) next to the estimate. Crossing 2× the task's total: stop, report where it went, and ask whether to continue — overruns are data, silent overruns are the failure mode.

## Closing report

End with: what shipped vs the spec, per-phase spend table (budgeted/actual), verifier findings by verdict (confirmed/refuted/plausible) and what each changed, what the integration pass caught, and the one thing the pipeline itself got wrong this run (for the next iteration of this command).
