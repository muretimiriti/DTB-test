# DTB Banking Portal

A production-grade, cloud-native banking web application built on a full Kubernetes CI/CD stack. It demonstrates secure microservices architecture with automated image builds, vulnerability scanning, GitOps deployment, and full observability.

---

## Table of Contents

- [What the Application Does](#what-the-application-does)
- [Architecture](#architecture)
- [Stack at a Glance](#stack-at-a-glance)
- [Repository Layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Quick Start — Local Development](#quick-start--local-development-docker-compose)
- [Full Kubernetes Stack](#full-kubernetes-stack--step-by-step)
- [Teardown](#teardown)
- [CI/CD Pipeline](#cicd-pipeline)
- [Security Controls](#security-controls)
- [Observability](#observability)
- [Health Checks](#health-checks)
- [Troubleshooting](#troubleshooting)
- [Running Tests Locally](#running-tests-locally)
- [Further Reading](#further-reading)

---

## What the Application Does

The DTB Banking Portal is a full-stack web banking system with:

- **Account management** — create accounts, look up by account number, edit profiles
- **Transactions** — deposit, withdraw, transfer between accounts
- **Transaction history** — paginated per-account transaction log
- **JWT-authenticated REST API** — all endpoints protected, secrets stored in Vault

---

## Architecture

```
Browser
  └── React Frontend (Nginx, port 80)
        └── Node.js Backend API (Express, port 5000)
              └── MongoDB 7.0 (StatefulSet, port 27017)
```

All three tiers run in the `banking` namespace on Kubernetes. MongoDB uses a headless service for stable DNS, the backend exposes a ClusterIP, and the frontend is served via an Nginx Ingress at `banking.local`.

---

## Stack at a Glance

| Layer | Technology | Version |
|-------|------------|---------|
| App | Node.js + React | — |
| Database | MongoDB | 7.0 |
| Container runtime | Docker + minikube | — |
| CI/CD | Tekton Pipelines | v0.68.0 |
| GitOps | ArgoCD | v2.14.6 |
| Secrets | HashiCorp Vault + ESO | chart 0.30.0 |
| Policy enforcement | Kyverno | — |
| Image signing | Cosign | — |
| Vulnerability scanning | Trivy | — |
| Observability | Prometheus + Grafana + Loki + OTel | chart 69.8.2 |
| OPA policies | Conftest + Rego | — |

---

## Repository Layout

```
.
├── backend/                  Node.js Express API
│   └── src/
│       ├── controllers/      accountController.js
│       ├── routes/           accountRoutes.js
│       ├── models/           Account, Transaction schemas
│       ├── middleware/        auth, validation, error handling
│       └── server.js
├── frontend/                 React SPA
│   └── src/
│       ├── components/       AccountDashboard, CreateAccount, TransactionModal, ...
│       └── services/         API client
├── manifests/
│   ├── k8s/                  Kubernetes manifests (kustomize base)
│   │   ├── mongodb/          StatefulSet, headless service, init ConfigMap
│   │   ├── backend/          Deployment, Service, ConfigMap, Secret template
│   │   └── frontend/         Deployment, Service, Ingress
│   ├── tekton/               CI pipeline tasks, pipeline, triggers, RBAC, PVC
│   ├── argocd/               ArgoCD Application CRD (application.yaml)
│   └── security/             Kyverno ClusterPolicies, network policies
├── policies/                 OPA/Rego security policies (k8s-security.rego)
├── scripts/
│   ├── bootstrap.sh          Master bootstrap — runs all 6 stages end-to-end
│   ├── teardown.sh           Master teardown  — removes all stages in reverse order
│   ├── prerequisites.sh      Tools, cluster, namespaces, Helm repos
│   ├── teardown-compose.sh   Tear down Docker Compose stack (containers, volumes, networks)
│   └── k8s/
│       ├── vault-credentials.sh        Load all secrets into Vault
│       ├── security-init.sh            Kyverno, Cosign, ESO, OPA, network policies
│       ├── tekton-init.sh              Tekton components + pipeline + PipelineRun
│       ├── argocd-init.sh              ArgoCD install + Application + polling
│       ├── observability-init.sh       Prometheus, Grafana, Loki, OTel + dashboards
│       ├── teardown-credentials.sh     Remove Vault KV paths + k8s secrets
│       ├── teardown-security.sh        Remove Kyverno policies, NetworkPolicies, Cosign, OPA
│       ├── teardown-tekton.sh          Cancel runs, delete tasks/pipelines/triggers/PVCs
│       ├── teardown-argocd.sh          Delete Application, disable sync, optionally uninstall
│       └── teardown-observability.sh   Helm-uninstall Prometheus, Loki, OTel; delete namespaces
├── doc/                      Architecture, API reference, pipeline walkthrough
└── docker-compose.yml        Local development (no Kubernetes required)
```

---

## Prerequisites

| Tool | Minimum Version | Install |
|------|-----------------|---------|
| Docker | 20.x | [docs.docker.com](https://docs.docker.com/engine/install/) |
| minikube | 1.32+ | [minikube.sigs.k8s.io](https://minikube.sigs.k8s.io/docs/start/) |
| kubectl | 1.28+ | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| Helm | 3.x | [helm.sh](https://helm.sh/docs/intro/install/) |
| Git | any | system package |

> **Note:** Internet access is required — Helm charts, Tekton releases, and container images are pulled at install time.

---

## Quick Start — Local Development (Docker Compose)

No Kubernetes required. Runs MongoDB, backend, and frontend locally.

```bash
git clone https://github.com/muretimiriti/DTB-test.git
cd DTB-test

# Copy and fill in env vars
cp backend/.env.example backend/.env

# Start all three services
docker compose up -d
```

| Service | URL |
|---------|-----|
| Frontend | http://localhost:3000 |
| Backend | http://localhost:5000 |
| MongoDB | localhost:27017 |

```bash
# Tail logs
docker compose logs -f

# Tear down (containers, volumes, networks)
./scripts/teardown-compose.sh

# Tear down and also remove built images
./scripts/teardown-compose.sh --remove-images
```

---

## Full Kubernetes Stack — Step-by-Step

### Overview of Stages

```
1. Prerequisites    tools, minikube cluster, namespaces, Helm repos
2. Credentials      Vault secrets, regcred, git-credentials
3. Security         Kyverno, Cosign, ESO, Vault policies, OPA, network policies
4. Tekton           pipelines, tasks, triggers, initial PipelineRun
5. ArgoCD           GitOps Application, 30-min polling, Image Updater
6. Observability    Prometheus, Grafana, Loki, OTel, dashboards
```

Each stage must succeed before the next begins. The master bootstrap script handles this automatically.

---

### Step 1 — Clone and Configure

```bash
git clone https://github.com/muretimiriti/DTB-test.git
cd DTB-test
```

Log in to Docker Hub (required for image push in the Tekton build step):

```bash
docker login
```

---

### Step 2 — Run the Master Bootstrap

The single command that provisions the entire stack:

```bash
./scripts/bootstrap.sh
```

This runs all 6 stages sequentially, waits for each to succeed, and writes a per-stage log to `logs/bootstrap/`.

**Options**

```bash
# Skip stages already provisioned
./scripts/bootstrap.sh --skip-prerequisites

# Resume after a failure at a specific stage
./scripts/bootstrap.sh --resume-from security

# Preview all steps without making cluster changes
./scripts/bootstrap.sh --dry-run

# Skip a specific component
./scripts/bootstrap.sh --skip-observability
```

**Stage Flags**

| Flag | Skips |
|------|-------|
| `--skip-prerequisites` | Stage 1 |
| `--skip-credentials` | Stage 2 |
| `--skip-security` | Stage 3 |
| `--skip-tekton` | Stage 4 |
| `--skip-argocd` | Stage 5 |
| `--skip-observability` | Stage 6 |
| `--resume-from <stage>` | All stages before the named one |

---

### Step 3 — Run Each Stage Manually (optional)

If you prefer to run stages one at a time:

```bash
# Stage 1 — tools, cluster, namespaces
./scripts/prerequisites.sh

# Stage 2 — Docker Hub regcred, GitHub token, app secrets into Vault
./scripts/k8s/vault-credentials.sh

# Stage 3 — Kyverno policies, Cosign keys, ESO sync, OPA checks, network policies
./scripts/k8s/security-init.sh

# Stage 4 — Tekton components, tasks, pipeline, triggers, initial PipelineRun
./scripts/k8s/tekton-init.sh

# Stage 5 — ArgoCD install, Application CRD, 30-min polling
./scripts/k8s/argocd-init.sh

# Stage 6 — Prometheus, Grafana, Loki, OTel, Grafana datasources + dashboards
./scripts/k8s/observability-init.sh
```

---

### Step 4 — Access the Services

After the bootstrap completes, open port-forwards to reach the UIs:

```bash
./scripts/k8s/port-forward.sh
```

Or open them individually:

```bash
# Tekton Dashboard
kubectl port-forward svc/tekton-dashboard -n tekton-pipelines 9097:9097 &

# ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Grafana
kubectl port-forward svc/prometheus-grafana -n monitoring 3001:80 &

# Prometheus
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090 &

# Vault UI
kubectl port-forward svc/vault -n vault 8200:8200 &
```

| Service | URL | Credentials |
|---------|-----|-------------|
| Banking App (frontend) | http://banking.local | — |
| Backend API | http://banking.local/api | JWT required |
| Tekton Dashboard | http://localhost:9097 | no auth |
| ArgoCD | https://localhost:8080 | admin / see below |
| Grafana | http://localhost:3001 | admin / see below |
| Prometheus | http://localhost:9090 | no auth |
| Vault UI | http://localhost:8200 | token: `root` |

**Retrieve generated passwords:**

```bash
# ArgoCD
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Grafana
kubectl get secret prometheus-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

**Add the banking app Ingress to `/etc/hosts`:**

```bash
echo "$(minikube ip) banking.local" | sudo tee -a /etc/hosts
```

---

## Teardown

Teardown mirrors the bootstrap in reverse order (6 → 1). Each component has its own script so you can remove only what you need.

### Master Teardown

The single command that tears down the entire stack:

```bash
./scripts/teardown.sh
```

The script prompts for confirmation, then runs all six teardown stages in reverse order writing per-stage logs to `logs/teardown/`.

**Common flags:**

```bash
# Preview what would be removed — no changes made
./scripts/teardown.sh --dry-run

# Full wipe: uninstall all components + delete the minikube cluster
./scripts/teardown.sh --nuke

# Keep the cluster running but remove everything inside it
./scripts/teardown.sh --uninstall-tekton --uninstall-argocd --uninstall-kyverno --uninstall-eso

# Only remove observability and ArgoCD, leave everything else
./scripts/teardown.sh --skip-tekton --skip-security --skip-credentials --skip-compose

# Remove Docker Compose stack and also delete built images
./scripts/teardown.sh --skip-argocd --skip-tekton --skip-security --skip-credentials --remove-images
```

**Flag reference:**

| Flag | Effect |
|------|--------|
| `--skip-observability` | Skip stage 6 (Prometheus, Grafana, Loki, OTel) |
| `--skip-argocd` | Skip stage 5 (ArgoCD Application + namespace) |
| `--skip-tekton` | Skip stage 4 (pipeline runs, tasks, RBAC) |
| `--skip-security` | Skip stage 3 (Kyverno, NetworkPolicies, Cosign) |
| `--skip-credentials` | Skip stage 2 (Vault secrets, k8s secrets) |
| `--skip-compose` | Skip stage 1 (Docker Compose stack) |
| `--uninstall-tekton` | Also Helm/kubectl-uninstall Tekton controllers + CRDs |
| `--uninstall-argocd` | Also kubectl-uninstall ArgoCD controllers + CRDs |
| `--uninstall-kyverno` | Also Helm-uninstall Kyverno |
| `--uninstall-eso` | Also Helm-uninstall External Secrets Operator |
| `--remove-images` | Delete locally built Docker images |
| `--delete-cluster` | Run `minikube delete` after all stages |
| `--nuke` | All of the above combined |
| `--dry-run` | Print every action without executing |

---

### Individual Stage Teardown

Run stages independently if you only need to remove one component:

```bash
# Stage 6 — remove Prometheus, Grafana, Loki, OTel
./scripts/k8s/teardown-observability.sh

# Stage 5 — delete ArgoCD Application and stop GitOps sync
./scripts/k8s/teardown-argocd.sh

# Stage 5 — delete Application AND fully uninstall ArgoCD
./scripts/k8s/teardown-argocd.sh --uninstall-argocd

# Stage 4 — cancel all PipelineRuns, delete tasks/pipelines/triggers/PVCs
./scripts/k8s/teardown-tekton.sh

# Stage 4 — also uninstall Tekton controllers from the cluster
./scripts/k8s/teardown-tekton.sh --uninstall-tekton

# Stage 3 — remove Kyverno policies, NetworkPolicies, cosign secrets, OPA ConfigMaps
./scripts/k8s/teardown-security.sh

# Stage 3 — also Helm-uninstall Kyverno and ESO
./scripts/k8s/teardown-security.sh --uninstall-kyverno --uninstall-eso

# Stage 2 — wipe Vault KV paths and all k8s secrets
./scripts/k8s/teardown-credentials.sh

# Stage 2 — only remove k8s secrets, leave Vault data intact
./scripts/k8s/teardown-credentials.sh --skip-vault

# Stage 1 — stop Docker Compose containers and remove volumes
./scripts/teardown-compose.sh

# Stage 1 — also delete the built backend and frontend images
./scripts/teardown-compose.sh --remove-images
```

Every script accepts `--dry-run` to preview actions without making changes.

---

### Teardown Logs

Each stage writes a log to `logs/teardown/`:

```bash
cat logs/teardown/observability.log
cat logs/teardown/argocd.log
cat logs/teardown/tekton.log
cat logs/teardown/security.log
cat logs/teardown/credentials.log
cat logs/teardown/compose.log
```

---

## CI/CD Pipeline

The Tekton CI pipeline runs automatically on every `git push` via a GitHub webhook, and can also be triggered manually.

### Pipeline Stages

```
git-clone → lint-sast → ┬─ test-backend  ─┐
                        └─ test-frontend ─┘
                                           └─ build-push → trivy-scan → cosign-sign → update-manifests
```

| Stage | What it does |
|-------|--------------|
| `git-clone` | Clones the repository at the pushed commit |
| `lint-sast` | ESLint, npm audit, hadolint (Dockerfile), gitleaks secret scan |
| `test-backend` | Jest unit + integration tests, 80% coverage gate |
| `test-frontend` | React Testing Library tests, 60% coverage gate |
| `build-push` | Kaniko builds backend + frontend images, pushes to Docker Hub |
| `trivy-scan` | CVE scan — fails on HIGH or CRITICAL severity |
| `cosign-sign` | Signs images with the project Cosign key stored in Vault |
| `update-manifests` | `kustomize edit set image` + git push (triggers ArgoCD sync) |

### Trigger a Manual PipelineRun

```bash
# Trigger via tkn
tkn pipeline start banking-ci-pipeline \
  --param git-url=https://github.com/muretimiriti/DTB-test.git \
  --param git-revision=main \
  --param image-tag=$(git rev-parse --short HEAD) \
  --workspace name=pipeline-workspace,claimName=pipeline-pvc \
  --workspace name=docker-credentials,secret=regcred \
  -n tekton-pipelines

# Watch live logs
tkn pipelinerun logs -f -n tekton-pipelines
```

### GitOps Loop

After `update-manifests` pushes the new image tag to git, ArgoCD detects the change within 30 minutes (configurable via `POLLING_INTERVAL`) and syncs the `banking` namespace automatically.

**Force an immediate sync:**

```bash
argocd app sync dtb-banking-portal
# or
kubectl -n argocd patch application dtb-banking-portal \
  -p '{"operation":{"sync":{}}}' --type merge
```

---

## Security Controls

| Control | Mechanism |
|---------|-----------|
| Secrets at rest | HashiCorp Vault KV v2 — never in git |
| Secret injection | External Secrets Operator syncs Vault → k8s Secrets |
| Admission policies | Kyverno — requires resource limits, non-root, no privilege escalation, signed images |
| Image signing | Cosign signs every built image; Kyverno verifies signature at admission |
| Vulnerability scanning | Trivy — blocks deployment of HIGH/CRITICAL CVEs |
| Network isolation | Zero-trust NetworkPolicies in `banking` namespace |
| OPA static analysis | Conftest + Rego checks manifests in every pipeline run |
| Code analysis | SonarQube (optional, enabled with `--param skip-sonarqube=false`) |

---

## Observability

Three Grafana dashboards are imported automatically by `observability-init.sh`:

| Dashboard | ID | Data Source |
|-----------|----|-------------|
| Node Exporter Full | 1860 | Prometheus |
| Kubernetes Cluster | 7249 | Prometheus |
| Loki Logs | 13639 | Loki |

Application traces are collected by the OpenTelemetry Collector (`otel` namespace) and can be forwarded to any OTLP-compatible backend.

---

## Health Checks

```bash
# All pods — flag anything not Running/Completed
kubectl get pods -A | grep -Ev 'Running|Completed'

# ArgoCD sync status
kubectl get application dtb-banking-portal -n argocd

# Latest pipeline run
tkn pipelinerun list -n tekton-pipelines

# Vault status
kubectl exec -n vault vault-0 -- vault status

# ESO secret sync
kubectl get externalsecret -n banking

# Kyverno policy reports
kubectl get policyreport -n banking
```

---

## Troubleshooting

### Tekton install fails with `Kyverno webhook: connection refused`

Kyverno admission controller is not running — the bootstrap auto-patches Kyverno webhooks to `Ignore` during installs and restores them after. If running manually:

```bash
kubectl patch validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  --type=json -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'

# ... run install ...

kubectl patch validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  --type=json -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"}]'
```

### `connection refused 192.168.49.2:8443` during bootstrap

The minikube API server dropped. The bootstrap waits up to 2 minutes for recovery:

```bash
minikube status
minikube start
./scripts/bootstrap.sh --resume-from <last-failed-stage>
```

### PipelineRun stuck or failing

```bash
tkn pipelinerun describe -n tekton-pipelines
tkn pipelinerun logs <run-name> -f -n tekton-pipelines
```

### ArgoCD not syncing

```bash
argocd app get dtb-banking-portal
argocd app sync dtb-banking-portal --force
```

### Stage logs

Each bootstrap and teardown stage writes a full log:

```bash
# Bootstrap logs
cat logs/bootstrap/prerequisites.log
cat logs/bootstrap/credentials.log
cat logs/bootstrap/security.log
cat logs/bootstrap/tekton.log
cat logs/bootstrap/argocd.log
cat logs/bootstrap/observability.log

# Teardown logs
cat logs/teardown/observability.log
cat logs/teardown/tekton.log
cat logs/teardown/argocd.log
```

---

## Running Tests Locally

```bash
# Backend
cd backend && npm install && npm test

# Frontend
cd frontend && npm install && npm test

# Code quality + security review (auto-corrects safe issues)
./scripts/code-review.sh --fix
```

---

## Further Reading

| Document | Path |
|----------|------|
| Architecture overview | [doc/architecture.md](doc/architecture.md) |
| API reference | [doc/api-reference.md](doc/api-reference.md) |
| Tekton pipeline walkthrough | [doc/tekton-walkthrough.md](doc/tekton-walkthrough.md) |
| Security walkthrough | [doc/security-walkthrough.md](doc/security-walkthrough.md) |
| CI/CD pipeline details | [doc/cicd-pipeline.md](doc/cicd-pipeline.md) |
| Setup guide | [doc/setup.md](doc/setup.md) |
