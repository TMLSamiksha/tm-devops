# DevSecOps Basics — Image Scanning, Secret Scanning & Beyond


---

## 1. What DevSecOps Is

DevSecOps extends the DevOps operating model (main guide, Sections 1–3) by making security a shared, automated, continuous responsibility instead of a separate gate at the end. The core idea is **"shift left"** — catch a vulnerable dependency, a leaked secret, or a misconfigured manifest as early and as cheaply as possible, rather than after it's already in production.

```mermaid
flowchart LR
    subgraph Old["Traditional: security at the end"]
        direction LR
        O1["Develop"] --> O2["Build"] --> O3["Deploy"] --> O4["Security review\n(weeks later, expensive to fix)"]
    end
    subgraph New["DevSecOps: security throughout"]
        direction LR
        N1["Develop\n(IDE linting,\npre-commit hooks)"] --> N2["Commit\n(secret scan)"] --> N3["Build\n(dependency/SCA scan)"] --> N4["Image\n(Trivy scan)"] --> N5["Manifest\n(IaC scan)"] --> N6["Deploy\n(policy gate)"] --> N7["Runtime\n(monitoring)"]
    end
```

This is the same "fail fast and cheap" principle from the CI/CD companion doc's quality gates (Section 2) — a hardcoded secret caught by a pre-commit hook costs seconds; the same secret found live in production after a breach costs an incident response.

---

## 2. Image Scanning with Trivy (Recap)

Trivy scans container images for known CVEs in OS packages and language dependencies. This is covered in full depth — install, commands, severity gating, remediation loop, SBOM generation — in the Docker companion doc's dedicated file: [`docker-image-optimization-security-trivy.md`](./docker-image-optimization-security-trivy.md), Section 4.

**Quick reference:**

```bash
# Scan a built image, fail the pipeline on HIGH/CRITICAL findings
trivy image --severity HIGH,CRITICAL --exit-code 1 orderflow-lite:1.5.0
```

In the Jenkins pipeline (Jenkins companion doc, Section 5.3), this is the `trivy fs`/`trivy image` line inside `stage('Security Scan')` — the gate that stops a vulnerable image from ever reaching the registry.

---

## 3. Secret Scanning with GitLeaks

GitLeaks scans Git history and working-tree files for accidentally committed secrets — API keys, passwords, tokens, private keys — by matching against regex/entropy-based detection rules. It's the other half of the "Security Scan" stage referenced throughout this training (Jenkins companion doc, Section 5.3; the seeded fake hardcoded secret in the OrderFlow-Lite training app exists specifically to demonstrate this).

```mermaid
flowchart LR
    Dev["Developer commits code"] --> Hook{"Pre-commit hook\n(gitleaks protect)"}
    Hook -->|"secret found"| Block["Commit blocked locally\n— fixed before it ever\nreaches Git history"]
    Hook -->|"clean"| Push["git push"]
    Push --> CI["CI pipeline:\ngitleaks detect\n(scans full history)"]
    CI -->|"secret found"| Fail["Pipeline fails,\nsecret must be rotated\n+ removed from history"]
    CI -->|"clean"| Continue["Pipeline continues"]
```

### 3.1 Install

```bash
# macOS
brew install gitleaks

# Linux — download the release binary
wget https://github.com/gitleaks/gitleaks/releases/latest/download/gitleaks_linux_x64.tar.gz
tar -xzf gitleaks_linux_x64.tar.gz && sudo mv gitleaks /usr/local/bin/

# Or run as a container — no install needed
docker run -v $(pwd):/repo zricethezav/gitleaks:latest detect --source /repo
```

### 3.2 Core Commands

```bash
# Scan the current repo (working tree + full git history)
gitleaks detect --source .

# Scan and exit non-zero if anything is found (the CI gate form)
gitleaks detect --source . --exit-code 1

# Scan only staged changes — this is what a pre-commit hook uses
gitleaks protect --staged

# Generate a report file (JSON, for parsing/dashboards)
gitleaks detect --source . --report-path gitleaks-report.json --report-format json
```

### 3.3 Example Finding

```
Finding:     AWS_SECRET_KEY = "AKIAIOSFODNN7EXAMPLE..."
Secret:      AKIAIOSFODNN7EXAMPLE...
RuleID:      aws-access-token
File:        src/config/database.js
Line:        14
Commit:      a1b2c3d
Author:      dev@example.com
Date:        2026-06-12
```

Exactly this kind of finding is what the "seeded fake hardcoded secret" in the OrderFlow-Lite training app is designed to trigger — a safe, deliberate example so trainees see a real GitLeaks failure without a real credential being at risk.

### 3.4 Remediation — the Part That's Easy to Get Wrong

**Deleting the secret from the current file is not enough** — it's still recoverable from Git history (`git log -p`, or a `git show <old-commit>:path`). Proper remediation:

1. **Rotate the credential immediately** — assume it's compromised the moment it was committed, regardless of whether the repo is public or private.
2. Remove it from history if the repo's exposure warrants it (`git filter-repo` or BFG Repo-Cleaner — a disruptive, rewrite-history operation, coordinate with the team first).
3. Move the real value to a secrets manager or a Kubernetes Secret (Kubernetes companion doc, Section 6) — never back in a config file.

### 3.5 Pre-Commit Hook (catches it before it's even a commit)

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.0
    hooks:
      - id: gitleaks
```

```bash
pip install pre-commit --break-system-packages
pre-commit install
# Now every `git commit` runs gitleaks protect --staged automatically
```

### 3.6 Ignoring a Known False Positive

```
# .gitleaksignore
# Test fixture, not a real credential — safe to ignore.
src/tests/fixtures/fake-api-key.js:aws-access-token:14
```

```bash
gitleaks detect --source . --gitleaks-ignore-path .gitleaksignore
```

---

## 4. Other Important DevSecOps Use Cases & Tools

Trivy (image/dependency CVEs) and GitLeaks (secrets) cover two categories. A fuller DevSecOps setup layers in several more, each catching a different class of issue at a different pipeline stage.

```mermaid
flowchart LR
    Src["Source Code"] -->|"SAST"| G1["Semgrep / SonarQube\n(code-level vulnerabilities:\nSQL injection, XSS, etc.)"]
    Src -->|"Secret scan"| G2["GitLeaks\n(Section 3)"]
    Src -->|"SCA"| G3["Trivy fs / Snyk /\nOWASP Dependency-Check\n(vulnerable dependencies)"]
    Build["Docker Build"] -->|"Image scan"| G4["Trivy image\n(Section 2)"]
    Manifest["Terraform / K8s YAML"] -->|"IaC scan"| G5["tfsec / Checkov /\nkube-linter\n(misconfigurations)"]
    Deploy["kubectl apply"] -->|"Policy gate"| G6["OPA Gatekeeper / Kyverno\n(admission control)"]
    Running["Running Cluster"] -->|"Runtime security"| G7["Falco\n(anomalous behavior detection)"]
    Running -->|"Compliance"| G8["kube-bench / Docker Bench\n(CIS benchmark checks)"]
```

| Category | What it catches | Example tools | Where it runs |
|---|---|---|---|
| **SAST** (Static Application Security Testing) | Vulnerabilities in your own source code — SQL injection, XSS, insecure deserialization, hardcoded crypto issues | Semgrep, SonarQube, CodeQL | On every commit/PR, before merge |
| **SCA** (Software Composition Analysis) | Known CVEs in third-party dependencies (npm/pip/maven packages) | Trivy `fs`, Snyk, OWASP Dependency-Check | Alongside SAST, or as part of the image scan |
| **DAST** (Dynamic Application Security Testing) | Vulnerabilities found by actually attacking a *running* app (fuzzing inputs, probing endpoints) — catches issues static analysis can't see | OWASP ZAP, Burp Suite | Against a staging environment, after deploy |
| **IaC Scanning** | Misconfigurations in Terraform/Kubernetes manifests before they're applied — open security groups, containers running as root, missing resource limits | tfsec, Checkov, kube-linter, Polaris | Alongside `terraform plan` (Terraform companion doc) or before `kubectl apply` (Kubernetes companion doc) |
| **Policy as Code / Admission Control** | Blocks non-compliant resources from ever being created in the cluster (e.g., reject any Pod without a resource limit, reject `:latest` tags) | OPA Gatekeeper, Kyverno | At the Kubernetes API server, on every `kubectl apply`/GitOps sync |
| **Runtime Security** | Anomalous behavior in already-running containers (unexpected shell spawned, unexpected outbound connection) | Falco, Sysdig | Continuously, in production |
| **CIS Benchmark / Compliance Checks** | Whether hosts/clusters/images follow published security hardening baselines | kube-bench (Kubernetes), Docker Bench for Security | Periodically, or as a pipeline/cron job |
| **Secrets Management** (prevention, not just detection) | Keeping secrets out of code entirely, rather than catching them after the fact | HashiCorp Vault, Kubernetes Secrets + External Secrets Operator/Sealed Secrets | Runtime — the app fetches secrets at deploy/start time instead of them ever existing in a repo |
| **SBOM** (Software Bill of Materials) | A full inventory of everything in an image/build, for audit and supply-chain traceability | Trivy `--format cyclonedx`, Syft | Generated at build time, stored alongside the image |

### 4.1 A Worked Mini-Example: IaC Scanning with tfsec

Extends the Terraform companion doc's local registry example with a security check before `apply`:

```bash
# Install
brew install tfsec

# Scan Terraform config for misconfigurations before applying
tfsec .
```

```
Result #1 HIGH Docker container running with excessive privileges
──────────────────────────────────────────────────────────
main.tf:15-20
  container "docker_container" "app_host" does not drop
  capabilities and may run privileged.

  Suggestion: add capabilities { drop = ["ALL"] } and only
  add back what's strictly needed.
```

Same "fail fast, fix before it ships" principle as Trivy and GitLeaks — just applied to infrastructure definitions instead of code or images.

---

## 5. Putting It Together: A Fuller DevSecOps Jenkinsfile

Extends the Jenkinsfile from the Jenkins companion doc (Section 5.3), which already had `trivy fs` and `gitleaks detect` in `stage('Security Scan')`:

```groovy
stage('Security Scan') {
    steps {
        sh 'gitleaks detect --source . --exit-code 1'
        sh 'trivy fs --severity HIGH,CRITICAL --exit-code 1 .'
        sh 'semgrep --config auto --error .'          // SAST
        sh 'tfsec ./terraform --soft-fail=false'       // IaC scan, if the repo has Terraform
    }
}

stage('Image Scan') {
    steps {
        sh "trivy image --severity HIGH,CRITICAL --exit-code 1 ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    }
}
```

Each added tool is another cheap, fast gate before the expensive one (a production incident) — the same "gates should get stricter/costlier as risk increases" ordering principle from the CI/CD companion doc, Section 2.

---

## 6. How This Fits the Bigger Picture

- **CI/CD companion doc, Section 2 (Quality Gates)**: every tool in Section 4's table above is a candidate quality gate — DevSecOps is really "how many of these gates does your pipeline actually have," not a separate discipline bolted on afterward.
- **Docker companion doc**: Trivy (Section 2) is the same tool, same commands, detailed there for image-specific optimization/security; this doc adds the *pipeline-wide* picture around it.
- **Kubernetes companion doc**: policy-as-code tools (Section 4, OPA/Kyverno) enforce constraints on exactly the Deployment/Service/ConfigMap/Secret objects introduced there — e.g., rejecting a Deployment that doesn't set `resources.limits` or that mounts a Secret insecurely.
- **Terraform companion doc**: IaC scanning (Section 4.1) slots in right after `terraform plan`, before `terraform apply` — reviewing the human-readable plan diff and the automated security scan together.
- **Main operating model guide, CALMS (Section 3)**: DevSecOps is CALMS's "Automation" and "Measurement" dimensions applied specifically to security — the goal is the same blameless, automated, continuously-measured posture, just for vulnerabilities and secrets instead of deployment frequency.

---

