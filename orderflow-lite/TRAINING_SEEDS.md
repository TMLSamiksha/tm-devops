# Training Seeds

This repository intentionally contains **three seeded findings** so the
DevOps training course has real material for the Trivy (dependency/image
scanning) and GitLeaks (secret scanning) labs. All three are documented here
so they are easy to find, explain, and remove once the labs are done.

**Do not "fix" these findings without updating or removing this document.**
Trainees fixing them as part of the lab exercise is expected and fine —
just don't let a well-meaning cleanup PR silently remove the training
material outside of the lab context.

---

## Seed 1 — Trivy: known-vulnerable npm dependency

- **What**: `jest-junit` is pinned to an exact version, `16.0.0` (no `^`),
  instead of a caret range. That version depends on a vulnerable version of
  `uuid` (`<11.1.1`), which has a moderate-severity advisory:
  [GHSA-w5hq-g745-h8pq](https://github.com/advisories/GHSA-w5hq-g745-h8pq)
  — "Missing buffer bounds check in v3/v5/v6 when `buf` is provided."
- **Where**:
  - [`package.json`](package.json) — the `"//jest-junit-seeded-for-training"`
    comment key sits directly above the `devDependencies` block and marks
    the pin as `SEEDED FOR TRAINING — DO NOT UPDATE`.
  - [`package-lock.json`](package-lock.json) — locks `jest-junit` at
    `16.0.0` and `uuid` at a vulnerable `<11.1.1` version accordingly.
  - Introduced in the same commit as this file (see `git log
    TRAINING_SEEDS.md package.json`).
- **Why this one**: it's a real, currently-flagged advisory (confirm with
  `npm audit` or a Trivy filesystem/image scan), moderate severity, and
  fully contained to `devDependencies` — `jest-junit` is never installed in
  the production Docker image (the `Dockerfile`'s `builder` stage runs
  `npm ci --omit=dev`), so this carries no runtime risk. It was chosen over
  pinning a vulnerable `express` version because that cascaded into
  several unrelated high-severity transitive findings (`body-parser`,
  `path-to-regexp`, `qs`), which is more noise than a single clean lab
  finding needs.
- **How to see it flagged**:
  - `npm audit` from `orderflow-lite/`
  - `trivy fs orderflow-lite/` or `trivy image <built-image>` (the
    `node_modules` layer only exists in a `builder`-stage scan or an image
    built without `--omit=dev`; for a realistic "this shipped to prod" scan
    scenario, point Trivy at the repo filesystem/lockfile instead of the
    final runtime image)
- **Expected remediation**: change `"jest-junit": "16.0.0"` back to a caret
  range (e.g. `"^17.0.0"` or later, whichever resolves the `uuid` advisory),
  run `npm install`, confirm `npm audit` is clean, and confirm `npm test`
  still passes and still produces `junit.xml`. Then remove the
  `"//jest-junit-seeded-for-training"` comment key and this section of this
  file.

---

## Seed 2 — GitLeaks: hardcoded secret

- **What**: A hardcoded AWS-style access key ID committed into a shell
  script that simulates a legacy integration hardcoding credentials instead
  of reading them from the environment.
- **Where**:
  - [`scripts/legacy-webhook-notify.sh`](scripts/legacy-webhook-notify.sh)
    — the `AWS_ACCESS_KEY_ID` line (see the script for the exact value; it's
    deliberately not repeated in full here — see the note below on why).
  - Introduced in the same commit as this file (see `git log
    scripts/legacy-webhook-notify.sh`), so it is present in git history as
    well as the working tree — GitLeaks' default detect (history) mode will
    find it either way.
- **The value used is not a real credential** — it's a made-up value shaped
  like a real AWS Access Key ID (`AKIA` + 16 alphanumeric characters) so it
  matches GitLeaks' default `aws-access-token` rule. (Not repeated in full
  here, on purpose — see below.)
  **Do not swap this for AWS's own published example key
  (`AKIAIOSFODNN7EXAMPLE`, used throughout AWS's docs)** — GitLeaks' default
  config includes a global allowlist regex for anything ending in
  `EXAMPLE`, specifically to suppress that well-known placeholder. An
  earlier version of this seed used that value and the lab silently never
  fired because of it; confirmed by testing AWS's example key against
  `gitleaks detect` directly and seeing it produce no finding, unlike the
  value currently in the script.
  **Note on this document itself**: earlier drafts of this section quoted
  the seeded value in full (e.g. `AKIA` + `TRAININGSEEDVALX` written as one
  contiguous string), which caused GitLeaks to flag *this file* as
  additional findings on top of the actual seed in the script — a
  self-inflicted false positive from documentation describing a secret
  rather than containing one. Avoid writing the full contiguous value
  anywhere in this file going forward.
- **Why this one**: a single, unambiguous, high-confidence finding for one
  of GitLeaks' built-in rules, isolated to one file with no other side
  effects (the script is not called from anywhere else in the app).
- **How to see it flagged**:
  - `gitleaks detect --source orderflow-lite -v` (scans history)
  - `gitleaks protect --source orderflow-lite -v` (scans working tree /
    staged changes)
- **Expected remediation**: remove the hardcoded key, read it from an
  environment variable instead (consistent with every other credential in
  this repo — see `.env.example`), and — since GitLeaks flags git
  *history*, not just the current file — either rewrite history to purge it
  (`git filter-repo` / BFG) or, more realistically for a training exercise,
  add the finding's fingerprint to a `.gitleaks.toml` allowlist with a
  comment explaining it's a rotated/placeholder value, and discuss with
  trainees why "delete the line" alone doesn't fully remediate a secret
  that's already been committed.

---

## Seed 3 — GitLeaks: `changeme` placeholder secrets in k8s manifests + docs

- **What**: The literal placeholder value `changeme` (and
  `changeme-api-key`), used consistently across this repo's Kubernetes
  Secret manifest and its accompanying docs, trips several of GitLeaks'
  built-in rules even though it's an intentionally-obvious placeholder, not
  a real credential.
- **Where** (all pre-existing content, not added alongside this file):
  - [`k8s/secret.yaml`](k8s/secret.yaml) — `DB_PASSWORD`, `API_KEY`, and
    `MYSQL_ROOT_PASSWORD` are all base64-encoded `changeme`/`changeme-*`
    values. Flagged under three different rule IDs:
    `kubernetes-secret-yaml`, and two `generic-api-key` hits.
  - [`README.md`](README.md) and [`k8s/README.md`](k8s/README.md) — several
    example curl commands passing the `changeme-api-key` placeholder as an
    `x-api-key` header value, flagged under `curl-auth-header`. (Written
    here without the actual `curl -H "x-api-key: ..."` header syntax, on
    purpose — reproducing that exact structure is what trips the rule, so
    doing it here would flag this doc too, same as the note in Seed 2.)
  - Total: 7 findings across these files as of this writing.
- **Why this is a useful (if accidental) second lab finding**: it's a
  realistic, common real-world pattern — placeholder secrets checked into a
  repo's example manifests/docs and never rotated to real
  Kubernetes-native secret management before going further. It also gives
  trainees more than one GitLeaks rule type to triage in the same scan
  (`aws-access-token` from Seed 2, plus `generic-api-key`,
  `kubernetes-secret-yaml`, and `curl-auth-header` from this seed).
- **How to see it flagged**: same as Seed 2 —
  `gitleaks detect --source orderflow-lite -v`.
- **Expected remediation**: discuss with trainees that `k8s/secret.yaml`
  checked into git is itself the anti-pattern being demonstrated (a real
  environment would generate Secrets from a vault/external-secrets
  operator, or at minimum keep them out of version control entirely);
  remediation here is either an allowlist entry (since these are
  intentional placeholders, not live credentials) with a comment explaining
  why, or replacing `k8s/secret.yaml` with a `.example` file plus
  `.gitignore` entry and generating the real one locally per
  `k8s/README.md`'s instructions.

---

## Removing all three seeds

1. Revert `package.json` / `package-lock.json` to a non-pinned, non-vulnerable
   `jest-junit` range and reinstall.
2. Delete `scripts/legacy-webhook-notify.sh` (and, if you want history fully
   clean rather than just the working tree, rewrite history to purge it).
3. Replace the `changeme`/`changeme-api-key` values in `k8s/secret.yaml`,
   `README.md`, and `k8s/README.md` with either real generated values (kept
   out of git) or an allowlisted, clearly-labeled placeholder convention.
4. Delete this file.
5. Re-run `npm audit`, a Trivy scan, and a GitLeaks scan to confirm all
   three labs' findings are gone.
