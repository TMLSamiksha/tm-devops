# OrderFlow-Lite on Kubernetes (Docker Desktop / kind / Minikube)

Manifests for running OrderFlow-Lite on a local single-node Kubernetes
cluster — Docker Desktop, kind, or Minikube. Not production-hardened —
see the tradeoff notes in `mysql.yaml` and `service.yaml` for what's
deliberately simplified and why.

## Files

| File | Purpose |
|---|---|
| `configmap.yaml` | Non-secret app/DB config (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `PORT`, `WORKER_POLL_INTERVAL_MS`) |
| `secret.yaml` | Placeholder credentials (`DB_PASSWORD`, `API_KEY`, `MYSQL_ROOT_PASSWORD`) — **replace before using outside this training course** |
| `mysql.yaml` | MySQL Deployment + PVC + ClusterIP Service, with `sql/init.sql` mounted as an init script |
| `deployment.yaml` | OrderFlow-Lite Deployment, 2 replicas, defaults to the `localhost:5000` registry image |
| `service.yaml` | NodePort Service exposing the app |

## Build and get the image into the cluster

`k8s/deployment.yaml` defaults to `localhost:5000/orderflow-lite:latest`
— a local, unauthenticated registry — which is the recommended path.

### Docker Desktop (recommended for this course)

Docker Desktop's Kubernetes node shares the same Docker daemon as your
`docker` CLI, so anything pushed to a `localhost` registry is immediately
visible to the cluster — no separate load step. Full setup (starting the
registry container, verifying it, troubleshooting) is in
[`content/local-registry-setup.md`](../../content/local-registry-setup.md);
the short version:

```bash
# one-time: docker run -d --restart=always --name local-registry -p 5000:5000 registry:2

# from the orderflow-lite/ repo root
docker build -t localhost:5000/orderflow-lite:latest .
docker push localhost:5000/orderflow-lite:latest
```

Then `kubectl apply` as normal (below) — the Deployment's default image
already points at this registry.

### kind / Minikube (alternative)

kind runs each node as its own container with its own separate image
store, and Minikube runs in its own VM/daemon — neither can see your
host's local `docker build` cache (or a `localhost:5000` registry) without
an explicit load step:

```bash
docker build -t orderflow-lite:local .

# kind:
kind load docker-image orderflow-lite:local

# Minikube (either approach):
minikube image load orderflow-lite:local
# — or, build directly into Minikube's Docker daemon instead of loading after:
# eval $(minikube docker-env)
# docker build -t orderflow-lite:local .
```

If you go this route, also change `k8s/deployment.yaml`'s `image:` field
to `orderflow-lite:local` (and drop `imagePullPolicy: Always`, which only
makes sense for a mutable registry tag) before applying it.

## Apply order

MySQL must be up and have run its init script **before** the app's
readiness probe (`/ready`, which checks DB connectivity) will pass. Apply
config and MySQL first, wait for it to be ready, then apply the app:

```bash
kubectl apply -f k8s/configmap.yaml -f k8s/secret.yaml
kubectl apply -f k8s/mysql.yaml

# wait for the MySQL pod to be Ready (readiness probe = mysqladmin ping)
kubectl rollout status deployment/mysql

kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml
kubectl rollout status deployment/orderflow-lite
```

Applying everything at once (`kubectl apply -f k8s/`) also works — the
app's `readinessProbe` on `/ready` will just keep failing and Kubernetes
will hold it out of the Service's endpoints until MySQL and the schema
init script have finished. It just takes a bit longer to become reachable
and produces more transient "not ready" noise while you wait, so applying
MySQL first is the cleaner path for a live demo.

## Reaching the service

**Docker Desktop**: NodePorts are reachable directly at `localhost` —
no port-forward or tunnel needed:

```bash
curl -H "x-api-key: changeme-api-key" http://localhost:30080/orders
```

**kind**: kind's default network setup does not expose NodePorts on
`localhost` automatically unless the cluster was created with `extraPortMappings`. The simplest path on kind is `port-forward`:

```bash
kubectl port-forward svc/orderflow-lite 3000:3000
curl -H "x-api-key: changeme-api-key" http://localhost:3000/orders
```

**Minikube**: Minikube can resolve the NodePort directly via its own IP, or
open a local tunnel for you:

```bash
minikube service orderflow-lite --url
# then curl the printed URL, e.g.:
curl -H "x-api-key: changeme-api-key" http://192.168.49.2:30080/orders
```

## Verifying the Service selector matches

`service.yaml`'s selector (`app: orderflow-lite`) must match
`deployment.yaml`'s pod template labels (also `app: orderflow-lite`) — this
version of the manifests does match. Confirm at any time with:

```bash
kubectl get endpoints orderflow-lite
# should list 2 pod IPs:3000 once the Deployment's pods are Ready — an
# empty ENDPOINTS column with a healthy Deployment is the classic symptom
# of a selector/label mismatch.
```

## Discussion point: one worker loop per replica

`deployment.yaml` runs **2 replicas** of OrderFlow-Lite, and each replica
independently starts its own `setInterval` background worker loop
(`src/worker/processOrders.js`) on boot — there is no leader election or
locking between replicas. With 2 replicas polling the same `orders` table
on the same interval, both pods will regularly race to pick up the same
batch of pending orders.

This isn't something to fix as part of standing up these manifests — it's
flagged here deliberately as a discussion point for the architecture-review
module: what actually happens when two workers grab the same pending order
(hint: there's no row locking in the current `SELECT ... WHERE status =
'pending'` query), what a fix might look like (e.g. `SELECT ... FOR UPDATE
SKIP LOCKED`, a dedicated worker Deployment separate from the API replicas,
a leader-election sidecar, or an external queue), and what tradeoffs each
option brings for a service that's meant to also demonstrate horizontal
scaling of the API itself.
