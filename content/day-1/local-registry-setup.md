# Local Docker Registry + Kubernetes (Docker Desktop)

How to run a local, unauthenticated Docker registry on your laptop and use
it with Docker Desktop's built-in Kubernetes — this is the manual version
of what `orderflow-lite/jenkins/Jenkinsfile.02-docker-build-push` onward
automate (they default to `REGISTRY = 'localhost:5000'`).

## Why this is simpler on Docker Desktop than on kind/Minikube

`orderflow-lite/k8s/README.md` documents `kind load docker-image` and
`minikube image load` — both are necessary because kind runs each cluster
node as its **own** Docker container with its own separate image store,
and Minikube runs its cluster in its own VM/container with a separate
Docker daemon. Neither one can see images that only exist in your host's
local `docker build` cache without an explicit load step.

Docker Desktop's Kubernetes is different: the single Kubernetes node and
your regular `docker` CLI share the **same** underlying Docker Desktop VM
and the same Docker daemon. Anything reachable via `localhost` from that
daemon (including a registry container you started with `docker run -p
5000:5000 ...`) is already reachable from the Kubernetes node — no load
step needed. Push to `localhost:5000`, reference `localhost:5000/...` in
your manifests, done.

## Prerequisites

- Docker Desktop installed, with **Kubernetes enabled**: Docker Desktop →
  Settings → Kubernetes → check "Enable Kubernetes" → Apply & Restart.
- Confirm `kubectl` is pointed at it:

  ```bash
  kubectl config current-context
  # docker-desktop
  ```

  If it's not, switch to it explicitly — this matters, since it's easy to
  still be pointed at a kind/Minikube/remote context from earlier work:

  ```bash
  kubectl config use-context docker-desktop
  ```

## 1. Start a local registry

```bash
docker run -d \
  --restart=always \
  --name local-registry \
  -p 5000:5000 \
  -v local-registry-data:/var/lib/registry \
  registry:2
```

- `--restart=always` so it comes back after a Docker Desktop restart.
- The named volume (`local-registry-data`) persists pushed images across
  container restarts — drop `-v ...` if you'd rather it start empty every
  time.

Verify it's up:

```bash
curl http://localhost:5000/v2/_catalog
# {"repositories":[]}
```

### A note on HTTP vs HTTPS

`registry:2` serves plain HTTP, not HTTPS, and Docker normally refuses to
push/pull from an HTTP registry. You do **not** need to edit
`daemon.json` for this specific setup, though: Docker treats any registry
address on `127.0.0.0/8` (which includes `localhost`) as insecure-by-default,
no configuration required. This only applies to `localhost`/`127.0.0.1` —
if you ever point this at a registry over your LAN IP or a hostname
instead, you'll need to add it to Docker Desktop's Settings → Docker
Engine → `insecure-registries` list first.

## 2. Build and push OrderFlow-Lite to it

From `orderflow-lite/`:

```bash
docker build -t localhost:5000/orderflow-lite:latest .
docker push localhost:5000/orderflow-lite:latest
```

Confirm the push landed:

```bash
curl http://localhost:5000/v2/orderflow-lite/tags/list
# {"name":"orderflow-lite","tags":["latest"]}
```

(This is exactly what `Jenkinsfile.02-docker-build-push`'s Docker Build /
Docker Push stages do, just with `${IMAGE_TAG}` = the Jenkins build number
instead of `latest`.)

## 3. Apply the Deployment

`orderflow-lite/k8s/deployment.yaml` already defaults its image to
`localhost:5000/orderflow-lite:latest` with `imagePullPolicy: Always` —
no edits needed for the manual flow above:

```bash
kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml
kubectl rollout status deployment/orderflow-lite
```

Iterating locally: since the image is `Always`-pulled, re-running steps 2
and 3 (`docker build` + `docker push` to the same `:latest` tag, then
`kubectl rollout restart deployment/orderflow-lite`) is enough to pick up
a new build — no need to bump a tag for manual testing.

To deploy a **specific, immutable tag** instead of floating `:latest`
(what the Jenkinsfiles do, tagging each build with `${BUILD_NUMBER}` — see
`Jenkinsfile.03-kubernetes-deploy`'s Kubernetes Deploy stage):

```bash
kubectl set image deployment/orderflow-lite \
  orderflow-lite=localhost:5000/orderflow-lite:42
kubectl rollout status deployment/orderflow-lite
```

## 4. Verify the pull actually came from the registry

```bash
kubectl describe pod -l app=orderflow-lite
```

Look for an Events line like:

```text
Normal  Pulled  ...  Successfully pulled image "localhost:5000/orderflow-lite:latest" ...
```

If you instead see `ErrImagePull` / `ImagePullBackOff`, see Troubleshooting
below.

## imagePullPolicy matters here

`k8s/deployment.yaml` explicitly sets `imagePullPolicy: Always` (rather
than relying on Kubernetes' tag-based default, which is `Always` for
`:latest` and `IfNotPresent` for anything else) — deliberately, since this
Deployment's default image is a mutable `:latest` tag in a registry you'll
keep re-pushing to while iterating. That means:

- Re-running steps 2 and 3 (`docker build` + `docker push` to `:latest`,
  then `kubectl rollout restart deployment/orderflow-lite`) always
  re-pulls — good for iterating manually.
- If you switch to per-build tags instead (like the Jenkinsfiles'
  `${BUILD_NUMBER}`, via `kubectl set image`), `Always` is unnecessary
  overhead but harmless — each build gets a new, distinct tag, so there's
  never a stale-cache problem either way.
- If you manually push a new image to the **same** non-`latest` tag (e.g.
  overwriting `localhost:5000/orderflow-lite:dev` repeatedly), `Always`
  is what makes the cluster actually notice — without it, the node would
  keep serving whatever it cached the first time it pulled that tag.

## Troubleshooting

### `ImagePullBackOff` / `ErrImagePull`

- Run `kubectl describe pod -l app=orderflow-lite` and check the exact
  error in Events — it's almost always one of the two below.
- Confirm you're actually on the `docker-desktop` context (`kubectl
  config current-context`) — if you're accidentally still on a kind or
  Minikube context, `localhost:5000` means something different there (or
  isn't reachable at all), and this whole "no load step needed" shortcut
  doesn't apply.
- Confirm the tag actually exists in the registry: `curl
  http://localhost:5000/v2/orderflow-lite/tags/list`.

### `error getting credentials - err: exec: "docker-credential-desktop": executable file not found in $PATH`

This is not a registry-auth problem — `local-registry-data`'s `registry:2`
container has no auth configured, and `localhost`/`127.0.0.0/8` never needs
credentials. What's happening: the Docker CLI always consults whatever
`credsStore` is set in `~/.docker/config.json` before *any* push or pull,
regardless of target registry. On a machine with Docker Desktop, that's
usually `"credsStore": "desktop"`, backed by a helper binary
(`docker-credential-desktop`) that Docker Desktop installs to
`/usr/local/bin` — if whatever shell or process is running `docker push`
doesn't have `/usr/local/bin` on its `PATH`, the lookup fails with this
error even though the registry itself needs no credentials at all.

- In your own terminal: `which docker-credential-desktop` — if empty, add
  `/usr/local/bin` to your shell's `PATH`.
- In Jenkins: the agent's `PATH` is whatever's configured in Manage
  Jenkins → System → Global properties → Environment variables, which
  does **not** inherit your interactive shell's `PATH` — make sure
  `/usr/local/bin` is included there too.

### Registry container won't start / port already in use

- Something else is bound to 5000 (macOS's AirPlay Receiver uses 5000 on
  some versions — Settings → General → AirDrop & Handoff → turn off
  AirPlay Receiver, or just run the registry on a different host port,
  e.g. `-p 5001:5000`, and update `REGISTRY` accordingly everywhere you
  reference it).

### Registry has stale data you want to clear

```bash
docker rm -f local-registry
docker volume rm local-registry-data
```

then redo step 1.

## Tearing it down

```bash
docker rm -f local-registry
docker volume rm local-registry-data   # only if you want to drop pushed images too
```

Removing the registry container doesn't affect anything already deployed
to the cluster — running pods keep whatever image they already pulled
until something triggers a new pull (a rollout, a pod restart on a node
that evicted the cached layer, etc).
