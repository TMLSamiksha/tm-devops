# Jenkins with a Local Git Repo — Setup, Triggers, and Secrets

How to run Jenkins entirely on your laptop against this repo's **local**
git history (no GitHub/GitLab required), how automatic build triggering
actually works when there's no hosted git server to send a webhook, and
how to store the credentials the `orderflow-lite/jenkins/Jenkinsfile.*`
pipelines need (Docker registry login, kubeconfig) without ever putting
them in a file that gets committed.

## 1. Run Jenkins locally

Two options. Recommended: install Jenkins directly on macOS via Homebrew,
so it runs as a normal process with unmediated access to your filesystem,
Docker Desktop, and `kubectl` — no extra plumbing needed for the pipelines
in this repo, which all assume `docker` and `kubectl` are just on PATH.

```bash
brew install jenkins-lts
brew services start jenkins-lts
```

Jenkins is now at <http://localhost:8080>. Get the initial admin password:

```bash
cat /opt/homebrew/var/lib/jenkins/secrets/initialAdminPassword
```

**Alternative: Jenkins in Docker.** Works, but adds real complexity for no
benefit in a local training setup: the container needs the host's Docker
socket bind-mounted (`-v /var/run/docker.sock:/var/run/docker.sock`) plus
a `docker` CLI binary inside the container (the official `jenkins/jenkins`
image doesn't ship one) to run this repo's `docker build`/`docker push`
steps, and it needs your repo directory bind-mounted separately to see
local git history at all. Only worth it if you specifically want Jenkins
itself containerized — otherwise prefer the Homebrew path above.

## 2. First-time setup

1. Open <http://localhost:8080>, paste the initial admin password.
2. Choose **Install suggested plugins**.
3. Additionally install (Manage Jenkins → Plugins → Available):
   - **Docker Pipeline** — provides the `docker.build()` / `docker.withRegistry()` DSL used in `Jenkinsfile.02-docker-build-push` onward.
   - **Kubernetes CLI** — provides `withKubeConfig`, referenced in `Jenkinsfile.03-kubernetes-deploy`'s header comment as the production-grade alternative to relying on the agent's ambient kubeconfig.
4. Create your first admin user when prompted.

## 3. Point Jenkins at this repo's local git history

No GitHub remote is required — `git` itself works fine over a plain
filesystem path. From the Jenkins UI:

1. **New Item** → name it `orderflow-lite-ci` → **Pipeline** → OK.
2. Under **Pipeline**, set **Definition** to `Pipeline script from SCM`.
3. **SCM**: `Git`.
4. **Repository URL**: the absolute local path to this repo, as a
   `file://` URL:

   ```text
   file:///Users/ramanuj/Documents/training-projects/tm-devops
   ```

5. **Branch Specifier**: `*/main` (or `*/capstone-seeded-failure` for the
   capstone lab job — see `CAPSTONE_FAILURE_GUIDE.md`).
6. **Script Path**: which numbered Jenkinsfile this job runs, e.g.

   ```text
   orderflow-lite/jenkins/Jenkinsfile.05-gitleaks-scan
   ```

7. No credentials needed for a `file://` URL — it's just a local path
   Jenkins reads directly, not an authenticated remote.
8. Save, then **Build Now** to confirm it can check out and run at all
   before wiring up automatic triggers.

Want multiple stages of the buildup runnable side by side? Create one
Jenkins job per numbered Jenkinsfile (`orderflow-lite-01-local-run`,
`orderflow-lite-02-docker-push`, etc.) — that's exactly why the files are
numbered and self-contained rather than one file you keep overwriting.

## 4. How automatic triggering works with only a local repo

This is the part that's genuinely different from a normal GitHub-backed
Jenkins setup, and worth understanding rather than cargo-culting.

**Webhooks don't apply here.** A webhook is GitHub/GitLab/etc. actively
pushing an HTTP request to Jenkins the moment someone pushes a commit.
That requires a hosted git server that knows how to send webhooks and a
Jenkins endpoint reachable from it. A local `file://` repo has neither —
there's no server process watching your local git history, so nothing can
proactively notify Jenkins of a new commit.

That leaves two real options for a local repo:

### Option A — Poll SCM (recommended for this course)

Jenkins periodically runs the local-repo equivalent of `git fetch` and
compares against the last build's commit. If it's different, it triggers
a build. Configure it on the job: **Build Triggers** → check **Poll SCM**
→ schedule using cron syntax, e.g.:

```text
H/2 * * * *
```

("roughly every 2 minutes" — the `H` spreads Jenkins' internal polling
load if you have many jobs; use a plain `*/2 * * * *` if you want it
literal). This is simple, requires no extra setup, and is the standard
answer for "how do I get near-automatic builds against a repo with no
hosted git server" — the tradeoff is a polling delay (up to your poll
interval) between pushing a commit and a build actually starting, versus
the near-instant trigger a real webhook gives you.

### Option B — Local git hook calling Jenkins directly

For genuinely instant triggering, add a `post-commit` (or `post-merge`)
hook in this repo's `.git/hooks/` that curls Jenkins' build trigger URL
the moment you commit:

```bash
# .git/hooks/post-commit (chmod +x this file)
#!/usr/bin/env bash
curl -s -X POST "http://localhost:8080/job/orderflow-lite-ci/build?token=YOUR_TRIGGER_TOKEN"
```

This needs the job configured with **Build Triggers** → **Trigger builds
remotely** → set an **Authentication Token** (that's the `YOUR_TRIGGER_TOKEN`
above — treat it as a secret; see Section 5, it shouldn't be hardcoded in
a script you might ever share). This is effectively a hand-rolled webhook
for a repo that has no server to send a real one. `.git/hooks/` isn't
version-controlled by default (it lives outside what `git clone` copies),
so this only fires on your machine — fine for local dev, not something
that "just works" for a teammate who clones the repo.

For this course, Option A (Poll SCM) is enough to demonstrate the concept
of automatic triggering without the extra setup — mention Option B as
what a real "instant trigger, no hosted git server" solution looks like.

## 5. Secrets and credentials: best practices

The golden rule, and the whole reason `TRAINING_SEEDS.md`'s GitLeaks seed
exists as a lab: **credentials never go in a file that gets committed** —
not in a `Jenkinsfile`, not in a script, not in a `.env` that accidentally
loses its `.gitignore` entry. Anything committed is in git history
forever unless you rewrite it, even after you "remove" it in a later
commit.

### Use Jenkins' built-in Credentials store, not environment variables in the job config

Manage Jenkins → Credentials → (a scope, e.g. "System" → "Global
credentials") → **Add Credentials**. Relevant types for this repo's
pipelines:

| Type | Used for |
| --- | --- |
| Username with password | Docker registry login (`DOCKER_CREDENTIALS_ID` in `Jenkinsfile.02` onward — the real Jenkins credential ID this points at, e.g. `dockerhub-creds`, is created here) |
| Secret file | A kubeconfig file, for the `withKubeConfig` approach `Jenkinsfile.03`'s header comment describes as the production-grade alternative to an ambient kubeconfig |
| Secret text | A single token/API key, e.g. a registry auth token that isn't a username+password pair |

Every credential gets an **ID** you reference by name from a Jenkinsfile —
that ID is not secret itself (it's fine to see `dockerhub-creds` in a
Jenkinsfile, as this repo's already does), only the value behind it is.

### Reference credentials from Jenkinsfiles like this repo already does

`Jenkinsfile.02-docker-build-push` (and every file after it) already
demonstrates the pattern:

```groovy
environment {
    DOCKER_CREDENTIALS_ID = 'dockerhub-creds'
}
...
docker.withRegistry("https://${REGISTRY}", DOCKER_CREDENTIALS_ID) {
    docker.image("${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}").push()
}
```

`docker.withRegistry(url, credentialsId)` looks up the credential, logs
in for the duration of the block, and logs back out afterward — the
actual username/password never appears in the pipeline script or console
log. The general-purpose equivalent for a plain shell command is
`withCredentials`:

```groovy
withCredentials([usernamePassword(
    credentialsId: 'dockerhub-creds',
    usernameVariable: 'REG_USER',
    passwordVariable: 'REG_PASS'
)]) {
    sh 'echo "$REG_PASS" | docker login -u "$REG_USER" --password-stdin ${REGISTRY}'
}
```

Jenkins automatically masks any value bound this way in the console log
output (it shows as `****`) — but only for values it knows came from a
credential binding. It cannot protect you from your own `echo
$SOME_SECRET_VAR` if you assigned that secret to a plain variable outside
a `withCredentials`/`credentials()` binding. Don't do that.

### Don't put real secret values in files this repo tracks

This repo's own `orderflow-lite/k8s/secret.yaml` is a live example of the
right and wrong way to do this at the same time: it's committed (so
`kubectl apply -f k8s/` works out of the box for training), but every
value in it is an explicitly-labeled placeholder, with a comment stating
real deployments must generate their own and never commit the real
values. Follow the same pattern for anything Jenkins-related you're
tempted to check in — a `.env` file, a sample kubeconfig, a registry auth
config — either don't commit it at all, or make very sure what's
committed is a placeholder, not the value you actually use.

### Least privilege and scope

- Scope credentials to the narrowest folder/job that needs them (Jenkins
  Credentials supports folder-level scoping, not just global) rather than
  making everything a global credential every job can see.
- For a registry login used only for pushing this app's image, a token
  scoped to just that repository (if your registry supports scoped
  tokens) beats a full account password.
- Rotate anything that's ever been pasted into a chat, a screen-share, or
  a now-deleted commit — "I removed it in the next commit" does not mean
  it stopped being valid; treat it as compromised and rotate it.

## Quick verification checklist

- [ ] `brew services list` shows `jenkins-lts` running (or your Docker
      container is up).
- [ ] A Pipeline job with **Repository URL** = `file://...` and the
      correct **Script Path** builds successfully via **Build Now**.
- [ ] **Poll SCM** (or your `post-commit` hook) actually triggers a new
      build after you make a commit — verify by watching Jenkins' build
      history, not just assuming it worked.
- [ ] `docker.withRegistry(...)`/`withCredentials(...)` blocks reference a
      credential ID that actually exists in Manage Jenkins → Credentials
      — a missing ID fails the build with a clear error, not a silent
      no-op, so this is easy to catch early.
- [ ] Nothing you just configured — token, password, kubeconfig — is
      sitting in a file `git status` shows as tracked or staged.
