# Research: Ledger Key Epochs

Findings of the three scout passes (codebase chain internals; contract versioning, upgrade
generator and tasks; prior art), recorded as decisions. References are to the tree at
`e0560ca`.

## R1 — What exists today

- **Decision**: build on `chain_key_id` and `Keyring`; do not replace them.
- **Findings**: Each chained row stores `chain_key_id`, the first 16 hex of
  HMAC(secret, "reeve-ledger-key-id") (`lib/reeve/ledger_key.rb:16-27`), and it is inside the
  digest (`canonical.rb:34-41`). `Keyring` maps fingerprints to secrets, signing key first
  (`keyring.rb:14-41`). The verifier looks up each row's key by fingerprint (`walk.rb:78-83`); an
  absent key is `unknown_key` → UNVERIFIABLE, exit 2 (`verification.rb:31-37`, `tasks.rb:15`).
  Rotation today: set `ledger_key` to the new key and `retired_ledger_keys` to the old
  (`configuration.rb:58-85`; a key cannot be both). Appends keep working after a rotation
  because the head is key-free after genesis (`head.rb:56-68`).
- **Gap**: no record of which keys signed which range — the cause of the known
  "rewritten key id reads as unverifiable" limitation (specs/002 verification.md:88-93).

## R2 — Contract versioning rule

- **Decision**: bump 3 → 4, MAJOR, and amend the rule's wording.
- **Findings**: The rule (specs/001 contracts/audit-entry.md:6-7; `lib/reeve/audit.rb:60-63`)
  says a nullable column is MINOR. Contract 3 nonetheless bumped for three nullable columns
  because "what an absence means changes" (audit-entry.md history; specs/002
  contracts/audit-entry-v3.md:9-12) — an exception that lives only in precedent. Separately,
  the canonical field list is keyed by contract (`canonical.rb:34-41, 60-66`): putting a column
  inside the digest *requires* a new contract number.
- **Alternatives**: (a) no entry column, registry only → contract stays 3, but the registry is
  deletable without trace (spec Clarifications); (b) entry column outside the digest → MINOR,
  but then the column is unprotected and an attacker can rewrite it freely.

## R3 — Identifying the key per record

- **Decision**: keep the existing fingerprint as the key id; add an ordinal epoch.
- **Prior art**: CloudTrail stores a public-key fingerprint per digest and verifiers select by
  it, failing when none matches; C2SP signed-note key ids are a hash of the *public* key;
  Rails ActiveRecord encryption stores a key reference in a header when `store_key_references`
  is on. A plain hash of a secret would be a guessing oracle for a weak secret; reeve's
  fingerprint is an HMAC keyed by the secret itself and keys are ≥ 32 bytes
  (`ledger_key.rb:32-45`), so it is not.
- **Cross-boundary linking**: CloudTrail links across key changes through the chain itself
  (each digest embeds the previous signature) with no rotation marker; reeve's chain already
  does the same (each row's digest covers the predecessor's). The epoch record adds the
  marker so the boundary is *attributable*, not to make it linked.

## R4 — Pitfalls designed against

- Key id must be inside the MAC (it already is) and so must the epoch number (FR-003).
- Fail closed on unknown key ids — reeve's equivalent is "never report intact": unknown keys
  stay UNVERIFIABLE, and become BROKEN once epochs say which key a row must carry.
- A retired HMAC key can forge its epoch (unlike a retired *public* key); unchanged from
  specs/002's "compromise of the key" non-guarantee.

## R5 — When an epoch opens

- **Decision**: at the first write with a not-yet-registered configured key, or by the task.
- **Rationale**: the generated initializer derives `ledger_key` from `secret_key_base`
  (`initializer.rb.tt:76-84`); a design that refuses writes until a task runs makes a
  `secret_key_base` rotation an outage of every guarded call. A rolling deploy necessarily runs
  old- and new-key processes side by side; stragglers must be legitimate.

## R6 — Conventions to follow

- Rake tasks are defined in `lib/reeve/tasks.rb` (a `.rb` so the gemspec packages it), as a
  module function taking `env:` and `out:` and returning the exit status, plus a `define`
  that registers the Rake task; specs call the function directly (`spec/reeve/tasks_spec.rb`).
- The upgrade generator's `STEPS` ladder: one entry per contract bump with `adds` and
  `creates`; applied-ness is asked of the table (`upgrade_generator.rb:39-54, 148-155`);
  `upgrade_generator_spec.rb` asserts convergence with a fresh install.
- Hand-maintained column lists to update: `Chain::COLUMNS` (`chain.rb:41`),
  `ContractVersion::COLUMNS`/`EXPECTED_VERSION` (`contract_version.rb:45-52`).
- CHANGELOG 0.6.0 shape: a problem paragraph, a bold contract line, bash and ruby blocks,
  "Behaviour changes worth reading before upgrading", then Added / Fixed.
