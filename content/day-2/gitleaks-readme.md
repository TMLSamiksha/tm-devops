# GitLeaks — What It Is, How to Set It Up and Use It, and How to Fix What It Finds

GitLeaks is a static secret-scanning tool: it greps git history (and,
optionally, the working tree) for patterns that look like credentials —
AWS keys, private keys, generic `api_key = "..."` assignments, Kubernetes
Secret manifests, auth headers in shell commands, and dozens of other
built-in rules — and reports each match with the exact commit, file, and
line it was introduced in. This repo wires it into
[`orderflow-lite/jenkins/Jenkinsfile.05-gitleaks-scan`](../orderflow-lite/jenkins/Jenkinsfile.05-gitleaks-scan)
as a pipeline gate, and ships intentionally seeded findings so the lab has
real material to scan — see
[`TRAINING_SEEDS.md`](../orderflow-lite/TRAINING_SEEDS.md).

## 1. Install it locally

You don't need this to run the Jenkins pipeline — `Jenkinsfile.05` pulls
`zricethezav/gitleaks:latest` via Docker on every run. Install it locally
when you want to iterate faster than a full Jenkins build, or to debug why
a scan found (or didn't find) something:

```bash
brew install gitleaks
gitleaks version
```

## 2. The two commands that matter

### `gitleaks detect` — scans committed git history

```bash
cd orderflow-lite
gitleaks detect --source . -v
```

This walks every commit reachable from `HEAD` and greps the diff each
commit introduced. This is what `Jenkinsfile.05-gitleaks-scan` runs, and
it's why a secret that's since been deleted from the working tree **still
shows up** — the commit that added it is still part of history. A finding
here always includes a `Commit:` and `Fingerprint:` line, which matters for
remediation (see §4).

### `gitleaks protect` — scans the working tree / staged changes

```bash
gitleaks protect --source . -v --staged=false   # working tree, uncommitted changes
gitleaks protect --source . -v                  # staged changes only (pre-commit use)
```

Use this to check a change *before* committing it — e.g. as a pre-commit
hook, or just to sanity-check a fix locally before pushing it into history
permanently. Nothing here shows up in `detect` until you actually commit
it.

### Useful flags

| Flag                                   | What it does                                                                                         |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `-v`                                   | Print each finding (`Finding`, `Secret`, `RuleID`, `File`, `Line`, `Commit`) instead of just a count |
| `--report-format json --report-path X` | Machine-readable output — what CI stages archive as a build artifact                                 |
| `--no-git`                             | Scan a plain directory as files, ignoring git history entirely                                       |
| `-c path/to/.gitleaks.toml`            | Use a custom config instead of the built-in default ruleset                                          |

## 3. How it's wired into this repo's pipeline

```groovy
// Jenkinsfile.05-gitleaks-scan
docker run --rm -v $(pwd):/repo zricethezav/gitleaks:latest \
    detect --source /repo -v --report-format json --report-path /repo/gitleaks-report.json
```

- Runs **before** `Test`/`Docker Build` — a secret finding blocks the whole
  pipeline, same principle as the Trivy scan running before `Docker Push`
  in `Jenkinsfile.04-trivy-scan`.
- The stage's `post { always { archiveArtifacts 'gitleaks-report.json' } }`
  keeps the JSON report attached to the build regardless of pass/fail, so a
  facilitator (or trainee) can inspect exact findings after the fact without
  re-running the scan.
- **Any finding fails the build** (`gitleaks detect`'s default exit code is
  `1` when leaks are found) — there's no severity threshold like Trivy's
  `--severity HIGH,CRITICAL`. Every rule hit is treated as blocking.

## 4. How to actually fix a flagged finding

There are three distinct remediation paths, and picking the wrong one is
the most common mistake trainees make:

### Path A — it's a real, live secret

1. **Rotate it first.** Assume it's compromised the moment it was
   committed, even if you delete it in the next commit — it's still
   readable in history by anyone with clone access.
2. Remove the hardcoded value from the file; read it from an environment
   variable, a Kubernetes Secret populated outside of git, or a secrets
   manager instead.
3. Purge it from history — see §6 below for exact commands and a verified
   worked example against this repo's own seeded secret.

### Path B — it's a placeholder/example value, not a real secret

This is what this repo's seeded findings are. Deleting the line doesn't
"fix" anything security-wise (there was nothing to compromise) — but the
finding still needs to be resolved so the pipeline gate stays meaningful
going forward. Two options:

- **Allowlist it explicitly**, with a comment explaining why, so the next
  real finding doesn't get lost in noise:

  ```toml
  # .gitleaks.toml
  [allowlist]
  regexes = [
    '''AKIATRAININGSEEDVALX''',   # fake, training-seeded value — see TRAINING_SEEDS.md
  ]
  ```

  Then point the pipeline at it: `gitleaks detect --source /repo -c /repo/.gitleaks.toml ...`

- **Or replace it with something GitLeaks won't match** — e.g. move
  `k8s/secret.yaml` to `k8s/secret.yaml.example`, `.gitignore` the real
  file, and generate it locally. This is closer to what a real environment
  should do anyway (a Secret manifest checked into git is itself the
  anti-pattern, independent of what value it holds).

### Path C — it's a false positive from documentation, not code

Worth calling out because it bit this repo directly: `TRAINING_SEEDS.md`
originally *described* the seeded secrets by quoting them verbatim, which
made GitLeaks flag the documentation file too, on top of the actual seeds.
Two fixes:

- Break up the literal string so it's not a contiguous regex match (e.g.
  reference `AKIA` and `TRAININGSEEDVALX` as separate fragments rather than
  one token).
- Or just don't restate the exact value in prose — point at the file/line
  instead (`see scripts/legacy-webhook-notify.sh`).

## 5. Worked examples from this repo

### Example 1 — `aws-access-token`, a hardcoded credential-shaped value

```bash
gitleaks detect --source orderflow-lite -v
```

```text
Finding:     AWS_ACCESS_KEY_ID="AKIATRAININGSEEDVALX
Secret:      AKIATRAININGSEEDVALX
RuleID:      aws-access-token
File:        scripts/legacy-webhook-notify.sh
Line:        15
```

This is [`TRAINING_SEEDS.md` Seed 2](../orderflow-lite/TRAINING_SEEDS.md).
**Non-obvious gotcha, confirmed by testing both values directly**: the
original seed used AWS's own published example key,
`AKIAIOSFODNN7EXAMPLE` — and GitLeaks' default config has a *global*
allowlist regex for anything ending in `EXAMPLE`, specifically to suppress
that exact well-known placeholder. That version of the seed silently never
fired. Any `AKIA`-shaped value works for a lab except that one.

### Example 2 — `kubernetes-secret-yaml` / `generic-api-key`, placeholder Secret values

```text
Finding:     DB_PASSWORD: Y2hhbmdlbWU=
RuleID:      kubernetes-secret-yaml
File:        k8s/secret.yaml
Line:        17
```

`Y2hhbmdlbWU=` is just base64 for `changeme` — GitLeaks doesn't decode
base64 to check if it's "real," it flags the *shape* of a Kubernetes
Secret's `data:` block on principle, since that's exactly where real
credentials end up in practice. This is Seed 3 in `TRAINING_SEEDS.md`.

### Example 3 — `curl-auth-header`, a secret embedded in an example command

```text
Finding:     curl -H "x-api-key: changeme-api-key" http://localhost:30...
RuleID:      curl-auth-header
File:        README.md
Line:        104
```

Triggered by the specific `-H "x-api-key: ..."` shape, not just the
presence of the word `changeme-api-key` elsewhere in a file (confirmed by
testing: mentioning the bare word alone, outside that header syntax, does
**not** trigger this rule — useful to know when writing docs *about* a
finding without re-triggering it).

## 6. Rewriting git history to remove or edit a committed secret

`git commit --amend` only rewrites the **tip** commit (`HEAD`) — that's
what fixed `TRAINING_SEEDS.md`'s own doc-quoting problem in §4/Path C
above, since that commit hadn't been pushed and nothing was on top of it.
A real leaked secret is almost never that convenient — it's usually buried
several commits back, already pushed, maybe already pulled by someone
else. Three different tools apply depending on what "fixing" means:

| Situation                                                              | Tool                                           | What it does                                                                  |
| ---------------------------------------------------------------------- | ---------------------------------------------- | ----------------------------------------------------------------------------- |
| Edit the message/content of the **most recent** commit, not yet pushed | `git commit --amend`                           | Replaces `HEAD` in place with new content, same parent                        |
| Edit an **older** commit's message or content interactively            | `git rebase -i <parent>^`                      | Opens an editor to `pick`/`reword`/`edit` each commit from that point forward |
| Redact a specific **string** everywhere it appears, across all history | `git filter-repo --replace-text`               | Rewrites every commit's blobs, replacing the literal/regex match              |
| Remove a **whole file** from every commit that ever touched it         | `git filter-repo --path <file> --invert-paths` | Rewrites history as if the file never existed                                 |

**Anything below the tip commit gets a new hash for every commit from that
point forward** — this is unavoidable, since a commit hash is derived from
its content plus its parent's hash. That means:

- Every clone (including CI, and every collaborator) needs to re-clone or
  hard-reset to the new history — a normal `git pull` will not merge
  cleanly and will likely resurrect the old, secret-containing history.
- You need a **force-push** (`git push --force-with-lease`) to move a
  remote branch onto rewritten history — never do this on a shared branch
  without warning everyone with push/pull access first.
- **Back up first**: `git branch backup-before-rewrite` (or clone the repo
  to a second directory) before running any of the commands below, so you
  can recover if the rewrite wasn't what you intended.

### Worked example 1 — redact a secret string across all of history

Verified against a scratch clone of this exact repo, targeting the seeded
AWS key in `scripts/legacy-webhook-notify.sh`:

```bash
brew install git-filter-repo

# Work on a disposable clone, never your only copy
git clone /path/to/repo history-rewrite-scratch
cd history-rewrite-scratch

# One "find==>replace" pair per line
echo 'AKIATRAININGSEEDVALX==>REDACTED_AWS_KEY' > /tmp/replacements.txt

git filter-repo --replace-text /tmp/replacements.txt --force
```

Confirmed results from actually running this:

```text
NOTICE: Removing 'origin' remote; see 'Why is my origin removed?'
Parsed 12 commits
HEAD is now at d59533d Update training seeds and legacy webhook script for clarity and accuracy
```

```bash
# The secret is gone from EVERY commit that ever contained it, not just the tip
git log --all -p -S"AKIATRAININGSEEDVALX" --oneline   # → no output at all

# Working tree reflects the redaction too
grep AWS_ACCESS_KEY_ID orderflow-lite/scripts/legacy-webhook-notify.sh
# AWS_ACCESS_KEY_ID="REDACTED_AWS_KEY"

# Re-scanning confirms the finding is gone (8 findings → 7)
gitleaks detect --source . -v
# leaks found: 7   (was 8 before the rewrite)
```

`git filter-repo` removed its own idea of `origin` as a safety measure
(it doesn't want you to accidentally push rewritten history back to where
you cloned from without thinking about it first) — re-add it explicitly
once you're ready to push:

```bash
git remote add origin <url>
git push --force-with-lease origin main
```

### Worked example 2 — remove a whole file from every commit

Also verified, targeting `k8s/secret.yaml` (this repo's Seed 3 findings):

```bash
git clone /path/to/repo history-rewrite-scratch2
cd history-rewrite-scratch2

git filter-repo --path orderflow-lite/k8s/secret.yaml --invert-paths --force
```

Confirmed results:

```bash
# Gone from the working tree
ls orderflow-lite/k8s/ | grep secret        # → no output

# Gone from every commit in history, not just HEAD
git log --all --oneline -- orderflow-lite/k8s/secret.yaml   # → no output

# The 3 findings that lived in this file (kubernetes-secret-yaml +
# 2x generic-api-key) are gone; the other findings are untouched
gitleaks detect --source . -v
# leaks found: 5   (was 8 before the rewrite)
```

### Editing an older commit's message or content interactively

For anything more surgical than "redact this string" or "delete this
file" — e.g. reword a commit message, or hand-edit a specific line in a
specific older commit — use an interactive rebase instead:

```bash
git log --oneline                 # find the commit BEFORE the one you want to change
git rebase -i <that-commit>^      # or a commit hash, or e.g. HEAD~5
```

In the editor that opens, change `pick` to:

- `reword` — stop only to edit that commit's message
- `edit` — stop with the working tree at that commit, so you can
  `git add`/amend the content, then `git rebase --continue`

This rewrites every commit from that point forward, exactly like the
`filter-repo` examples above — same force-push and re-clone requirements
apply.

### Alternative: BFG Repo-Cleaner

`brew install bfg` — a faster, more limited alternative to `filter-repo`
for the two most common cases:

```bash
bfg --replace-text /tmp/replacements.txt   # same shape as above
bfg --delete-files secret.yaml
```

`filter-repo` is the actively-maintained, git-recommended tool going
forward (`git filter-branch`, the older built-in command, is officially
deprecated in git's own docs in favor of it) — reach for BFG only if
you specifically want its simpler CLI for one of those two cases.

## 7. Quick troubleshooting checklist

- **Finding count doesn't match what you expect** — check
  `git branch -a` / `git for-each-ref` for stale remote-tracking refs
  (e.g. an `origin/main` that still points at an old commit because you
  haven't pushed). `gitleaks detect --source .` scans *all* reachable refs,
  which can include stale ones your own working repo carries but a fresh
  clone wouldn't. Simulate what CI actually sees with:

  ```bash
  git clone file:///path/to/this/repo /tmp/ci-sim
  cd /tmp/ci-sim && gitleaks detect --source . -v
  ```

- **A finding you fixed still shows up** — `detect` scans history, not the
  working tree. Editing the file doesn't erase the commit that introduced
  it. If that commit is still unpushed and is your current `HEAD` (check
  `git log --oneline -1`), `git commit --amend` folds the fix into it
  cleanly. Otherwise you need `git filter-repo`/BFG or an allowlist entry.
- **A secret you're sure is there isn't being flagged** — check it's not
  hitting a default allowlist pattern (the `EXAMPLE`-suffix case above is
  the one that's bitten this repo already), and double check the exact
  rule's expected shape/context requirements (`curl-auth-header` needs the
  header syntax, not just the token in isolation).
