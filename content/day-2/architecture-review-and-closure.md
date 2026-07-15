# Architecture Review & Closure


---

## 1. What Was Built — Full Architecture Recap

Across this training track, OrderFlow-Lite (a single-service Node.js/Express app with a MySQL backend and an internal background worker) moved from source code to a running, observable, security-gated Kubernetes deployment. Every arrow below is a concept covered in a companion doc.

```mermaid
flowchart TB
    Dev["Developer\n(trunk-based branching,\nCI/CD doc §1)"] -->|"git push"| Repo["Git Repo"]
    Repo -->|"webhook"| Jenkins["Jenkins\n(controller/agent,\nJenkins doc)"]

    Jenkins --> Build["Build + Unit Tests"]
    Build --> Sec["Security Scan\nTrivy fs + GitLeaks\n(DevSecOps doc)"]
    Sec --> DImg["docker build\n(multi-stage, optimized,\nDocker doc + image-security doc)"]
    DImg --> TrivyImg["trivy image scan\n(HIGH/CRITICAL gate)"]
    TrivyImg --> Reg["Local Docker Registry\n(provisioned by Terraform,\nTerraform doc §6)"]

    Reg -->|"kubectl set image /\nGitOps sync"| K8s["Kubernetes Cluster\n(kind, local)"]

    subgraph K8sObjs["Kubernetes Objects (K8s doc)"]
        DEP["Deployment\n(3 replicas, probes)"]
        SVC["Service"]
        CM["ConfigMap"]
        SEC2["Secret"]
    end
    K8s --> K8sObjs

    Ansible["Ansible\n(host prep,\nAnsible doc)"] -.->|"configures prerequisites"| K8s
    TF["Terraform\n(provisions registry,\nnetwork, kind prereqs)"] -.->|"provisions"| Reg
    TF -.-> K8s

    K8sObjs --> Health["Post-deploy health check\n(readiness/liveness probes)"]
    Health -->|"fail"| RB["Rollback\nkubectl rollout undo\n(CI/CD doc §3)"]
    Health -->|"pass"| Live["Live Service"]

    Live -->|"incident"| AIInc["AI-assisted incident analysis\n(local Gemma 4, incident doc)"]
    Repo -->|"pre-commit / PR review"| AIRev["AI-assisted pipeline review\n(local Gemma 4, review doc)"]
```

**What this demonstrates, mapped to the CALMS maturity dimensions (main guide, Section 3):** automated build-to-deploy pipeline (Automation), small trunk-based changes with fast feedback (Lean), Trivy/GitLeaks/health-check gates producing real pass/fail data (Measurement), reusable Terraform/Ansible/Jenkinsfile configuration checked into Git (Sharing), and a rehearsed, blameless failure scenario with AI-assisted incident triage (Culture).

---

## 2. Production-Readiness Gaps

Everything above works — and is deliberately scoped for a **training lab**: single-service, single-node, local registry, no cloud spend. Treating it as production-ready without addressing the following would be a mistake. This is the honest gap list, organized by the same layers as Section 1.

| Area | Current state (this training) | Production gap | Risk if unaddressed | Priority |
|---|---|---|---|---|
| **Source control / branching** | Trunk-based, short-lived branches (CI/CD doc §1) | No branch protection rules, required reviewers, or signed commits enforced | Unreviewed changes reach `main` | Medium |
| **CI/CD pipeline** | Single Jenkins controller, builds run on "built-in node" or one agent | No Jenkins HA/backup, no agent pool for parallel builds, no pipeline-as-library reuse across projects | Single point of failure; pipeline changes not centrally governed | High |
| **Container registry** | Single local `registry:2` container, no auth, HTTP not HTTPS | No authentication, no TLS, no image retention/GC policy, no HA | Anyone on the network can push/pull; unbounded disk growth; registry outage blocks all deploys | High |
| **Image security** | Trivy HIGH/CRITICAL gate in pipeline (image-security doc) | No image signing/verification (cosign), no admission-time enforcement that only scanned images can run | A manually-pushed unscanned image can still be deployed directly via `kubectl` | Medium |
| **Secrets management** | Kubernetes Secrets, base64-encoded (K8s doc §6) | No external secrets manager (Vault, External Secrets Operator), no automatic rotation, no encryption-at-rest verification on etcd | Base64 is not encryption; secrets recoverable by anyone with cluster read access | High |
| **Infrastructure state** | Terraform with local `terraform.tfstate` (Terraform doc §7) | No remote backend with locking (S3+DynamoDB, Terraform Cloud) | Concurrent applies can corrupt state; state file (which may contain sensitive values) isn't backed up | High |
| **Deployment mechanism** | Push-based (`kubectl set image` from Jenkins) | No GitOps agent (Argo CD/Flux) reconciling desired state, despite it being documented (CI/CD doc §4) | Cluster can drift from Git without detection; Jenkins holds direct cluster credentials | Medium |
| **Kubernetes cluster** | Single-node `kind` cluster, local | No multi-node/multi-AZ resilience, no cluster autoscaler, no node pool separation | Any node failure is a full outage; no capacity headroom | High (for real prod) |
| **Networking / ingress** | `NodePort` Service, HTTP only | No Ingress controller, no TLS termination, no WAF/rate limiting | No HTTPS, no path-based routing for multiple services, exposed on arbitrary node ports | High |
| **Autoscaling** | Fixed `replicas: 3` | No Horizontal Pod Autoscaler, no resource-based or custom-metric scaling | Can't absorb traffic spikes; over-provisioned at idle, under-provisioned at peak | Medium |
| **Observability** | `kubectl logs`/`describe`/`get events` used manually (incident doc §3) | No centralized logging (Loki/ELK), no metrics stack (Prometheus/Grafana), no distributed tracing, no alerting rules | Incident detection depends on someone noticing; MTTR (DORA metric) stays high by design | High |
| **Runtime security** | Not implemented (mentioned in DevSecOps doc §4 as a category) | No Falco or equivalent runtime anomaly detection, no `kube-bench` CIS benchmark run against the cluster | Compromise inside a running container goes undetected | Medium |
| **Database** | Single MySQL container, no backups, no replication | No managed DB, no automated backup/restore tested, no read replica, no connection pooling at scale | Data loss on any MySQL container failure; no tested recovery path | High |
| **Rollback automation** | Manual `kubectl rollout undo`, human-triggered (CI/CD doc §3) | No automatic rollback on failed health check, no canary/blue-green in place despite being documented | MTTR depends on a human noticing and acting; no gradual rollout to limit blast radius | Medium |
| **AI-assisted tooling** | Local Gemma 4 model for pipeline review and incident triage (review + incident docs) | Not integrated into actual PR bots or alerting systems; entirely manual invocation today | Useful in the lab, but doesn't yet reduce real on-call toil until wired into the actual workflow | Low (nice-to-have, not a blocker) |
| **Compliance / audit** | None formalized | No CIS benchmark automation, no audit logging on `kubectl`/Jenkins actions, no access review cadence | Can't demonstrate compliance posture to auditors or leadership | Medium |
| **Disaster recovery** | None tested | No documented/rehearsed DR plan, no cross-region or cross-cluster failover | Unknown actual recovery time if the entire local environment is lost | High (for real prod) |

```mermaid
flowchart LR
    subgraph High["High Priority (blocks real production use)"]
        H1["Secrets management"]
        H2["Remote TF state + locking"]
        H3["Ingress + TLS"]
        H4["Observability stack"]
        H5["Database backup/HA"]
        H6["Registry auth + HA"]
        H7["Multi-node cluster"]
    end
    subgraph Medium["Medium Priority"]
        M1["GitOps cutover"]
        M2["HPA / autoscaling"]
        M3["Runtime security (Falco)"]
        M4["Automated rollback"]
        M5["Branch protection"]
        M6["Compliance automation"]
    end
    subgraph Low["Low Priority / Nice-to-Have"]
        L1["AI tooling integration\ninto real alerting/PR bots"]
    end
```

---

## 3. Team Walkthrough

A suggested structure for presenting this architecture to a team, stakeholders, or as a training capstone demo — sequenced so each layer builds on the one before it, mirroring how the training itself was structured.

```mermaid
flowchart TB
    S1["1. Operating model & maturity\n(5 min) — where are we on CALMS?"]
    S2["2. Live demo: commit → pipeline\n(10 min) — trigger a build, watch\nJenkins stages go green"]
    S3["3. Live demo: security gates\n(5 min) — show a deliberately\nvulnerable dep get blocked"]
    S4["4. Live demo: deploy to K8s\n(10 min) — kubectl get pods/svc,\nshow the running app"]
    S5["5. Live demo: induced failure + rollback\n(10 min) — ConfigMap typo scenario,\nkubectl rollout undo"]
    S6["6. AI-assisted tooling demo\n(5 min) — pipeline review +\nincident analysis walkthrough"]
    S7["7. Gap review\n(10 min) — Section 2 table,\nask: which gaps block us\nfrom going live?"]
    S8["8. Roadmap & next steps\n(10 min) — Section 4,\nassign owners"]

    S1 --> S2 --> S3 --> S4 --> S5 --> S6 --> S7 --> S8
```

**Suggested audience prompts for Section 7 (gap review) discussion:**
- Which High-priority gaps genuinely block a first production deployment, versus which ones are "should fix soon but not blocking"?
- Who owns each gap — is it a platform/DevOps team item, an app team item, or does it need a decision from leadership (e.g., budget for a managed database)?
- Does the team's current CALMS self-assessment (main guide, Section 3.6) match what this walkthrough revealed, or did the gap review surface weaknesses in a dimension the team thought was stronger?

**RACI sketch for closing the gaps** (fill in real names before using):

| Gap category | Responsible | Accountable | Consulted | Informed |
|---|---|---|---|---|
| Secrets management, TLS, registry auth | Platform/DevOps | Eng lead | Security | Whole eng team |
| Observability stack | Platform/DevOps | Eng lead | SRE/on-call | Whole eng team |
| Database HA/backup | Platform/DevOps or DBA | Eng lead | App team | Whole eng team |
| GitOps cutover, autoscaling | Platform/DevOps | Eng lead | App team | Whole eng team |
| Compliance automation | Security | Eng lead | Platform/DevOps | Leadership |

---

## 4. Next-Step Roadmap

Phased to close the High-priority gaps first, building directly on the adoption roadmap already defined in the main operating model guide (Section 5) — this is that roadmap's Phase 4 ("Optimize") made concrete for this specific architecture.

```mermaid
gantt
    title Production-Readiness Roadmap
    dateFormat  YYYY-MM-DD
    axisFormat  %b %d

    section Phase A: Foundation Hardening (0-30 days)
    Remote Terraform state + locking      :a1, 2026-07-15, 10d
    Secrets manager (Vault or ESO)         :a2, after a1, 10d
    Registry auth + TLS                    :a3, after a1, 7d
    Database backup/restore tested         :a4, 2026-07-15, 14d

    section Phase B: Resilience (30-60 days)
    Multi-node cluster / node pools        :b1, after a2, 14d
    Ingress controller + TLS termination   :b2, after a3, 10d
    Observability stack (Prometheus/Grafana/Loki) :b3, after a4, 14d
    HPA / autoscaling rollout              :b4, after b1, 7d

    section Phase C: Automation Maturity (60-90 days)
    GitOps cutover (Argo CD)               :c1, after b2, 14d
    Automated rollback on failed health check :c2, after b3, 10d
    Runtime security (Falco)               :c3, after b3, 10d
    kube-bench CIS automation in CI        :c4, after c3, 7d

    section Phase D: Operational Excellence (90+ days)
    Documented + rehearsed DR plan         :d1, after c1, 21d
    SLOs + error budgets formalized        :d2, after c2, 14d
    AI tooling wired into PR bot + alerting :d3, after d2, 14d
    Compliance/audit logging               :d4, after c4, 14d
```

| Phase | Timeframe | Focus | Closes these Section 2 gaps |
|---|---|---|---|
| **A — Foundation Hardening** | 0–30 days | Make the existing single-node setup safe to depend on | Remote TF state, secrets management, registry auth/TLS, DB backup |
| **B — Resilience** | 30–60 days | Remove single points of failure | Multi-node cluster, ingress/TLS, observability, autoscaling |
| **C — Automation Maturity** | 60–90 days | Reduce manual intervention, close the loop on security | GitOps cutover, automated rollback, runtime security, CIS automation |
| **D — Operational Excellence** | 90+ days | Prove it under real failure conditions, formalize targets | DR rehearsal, SLOs/error budgets, AI tooling integration, compliance |

**Exit criteria for calling this "production-ready"** — the roadmap is done when every High-priority row in Section 2's table has a checked-off Phase A/B item, a DR plan has been rehearsed at least once (Phase D), and the team's DORA metrics (main guide, Section 4) are being tracked automatically rather than manually — at that point, re-run the CALMS self-assessment (main guide, Section 3.6) and confirm the score has actually moved, not just the infrastructure.

---

## 5. Closing Summary

This training track built a complete, working DevOps pipeline end to end — operating model and maturity framing, branching/quality-gates/rollback, Docker and image security, Kubernetes deployment with Deployments/Services/ConfigMaps/Secrets, Jenkins automation, Terraform/Ansible infrastructure provisioning, DevSecOps scanning, and AI-assisted review/incident tooling — all runnable locally, all documented, all reusable as a reference. The gap list in Section 2 isn't a criticism of that work; it's the explicit, honest boundary between "a training lab that teaches the concepts correctly" and "a system trusted with real customer traffic and data." Closing that gap is the next project, not a flaw in this one.

---

