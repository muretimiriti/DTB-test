# Tekton Pipeline Walkthrough — DTB Banking Portal

## Overview

The Tekton CI/CD pipeline automates the full software delivery lifecycle for the DTB Banking Portal, from source code commit to production deployment. It is composed of reusable Tasks assembled into two Pipelines, triggered automatically by GitHub webhooks.

```
GitHub Push / PR
       │
       ▼
EventListener (Tekton Triggers)
       │
       ▼
CI Pipeline ──────────────────────────────────────────────────────────────────
  git-clone → generate-tag → lint-sast ──→ test-backend     ──┐
                                  └──→ sonarqube-scan         ├→ kaniko (backend)
                                             └──→ npm-integration-test ──┘ kaniko (frontend)
                                                                    │
                                                             trivy-scan
                                                                    │
                                                            cosign-sign
                                                                    │
                                                        update-manifests (GitOps)
                                                                    │
                                                       ▼ (ArgoCD detects commit)
CD Pipeline ──────────────────────────────────────────────────────────────────
  smoke-test → [manual gate] → promote-to-production
```

---

## Folder Structure

```
manifests/tekton/
├── tasks/                    Reusable Task definitions (one per concern)
│   ├── git-clone.yaml        Clone the source repository
│   ├── generate-tag.yaml     Generate image tag (branch-sha-timestamp)
│   ├── lint-sast.yaml        ESLint + npm audit + hadolint + secret scan
│   ├── sonarqube-scan.yaml   Static code analysis + Quality Gate check
│   ├── test-backend.yaml     Backend unit tests + 80% coverage gate
│   ├── test-frontend.yaml    Frontend unit tests + 60% coverage gate
│   ├── npm-integration-test.yaml  Backend integration tests (API-level)
│   ├── kaniko.yaml           Build & push one Docker image (no daemon)
│   ├── trivy-scan.yaml       CVE scan images (fails on HIGH/CRITICAL)
│   ├── cosign-sign.yaml      Sign images for supply chain verification
│   ├── update-manifests.yaml kustomize edit set image + git push (GitOps)
│   └── smoke-test.yaml       Validate deployed app endpoints
│
├── pipelines/
│   ├── ci-pipeline.yaml      Stages 1–8: clone → test → build → sign → update
│   └── cd-pipeline.yaml      Stages 9–10: smoke test → promote to production
│
├── triggers/
│   ├── event-listener.yaml   GitHub webhook receiver
│   ├── trigger-binding.yaml  Extract params from webhook payload
│   └── trigger-template.yaml Create PipelineRun from params
│
├── rbac/
│   ├── serviceaccount.yaml   Pipeline ServiceAccount with image pull secrets
│   └── rolebinding.yaml      Roles and ClusterRoles for pipeline permissions
│
└── workspaces/
    └── pvc.yaml              5Gi shared PVC for source + artefacts
```

---

## Task Reference

### `git-clone`
Clones the application repository into the shared pipeline workspace.

| Param | Default | Description |
|-------|---------|-------------|
| `url` | — | Git repository HTTPS URL |
| `revision` | `main` | Branch, tag, or full commit SHA |
| `depth` | `1` | Shallow clone depth |
| `submodules` | `false` | Fetch submodules |

**Results:** `commit` (full SHA), `url`

---

### `generate-tag`
Creates a unique, traceable image tag consumed by all downstream tasks.

**Format:** `<branch>-<short-sha>-<timestamp>`
**Example:** `main-a1b2c3d-20260316-143022`

| Param | Description |
|-------|-------------|
| `git-revision` | Full commit SHA from `git-clone` result |
| `git-branch` | Branch name (e.g. `main`, `feature/auth`) |

**Results:** `image-tag`, `short-sha`

---

### `lint-sast`
Runs four quality and security checks in sequence:

1. **ESLint** — backend (`src/`) and frontend (`src/`) with `--max-warnings 0`
2. **npm audit** — fails on `HIGH` or `CRITICAL` vulnerabilities
3. **hadolint** — Dockerfile best-practice linting
4. **Secret scan** — grep for hardcoded passwords/API keys in source files

| Param | Default | Description |
|-------|---------|-------------|
| `fail-on-audit` | `true` | Whether npm audit failures block the pipeline |

---

### `sonarqube-scan`
Sends source code and coverage reports to the in-cluster SonarQube instance, then polls the Quality Gate result.

**SonarQube URL (in-cluster):**
```
http://sonarqube-sonarqube.sonarqube.svc.cluster.local:9000
```

| Param | Default | Description |
|-------|---------|-------------|
| `sonar-token` | — | Auth token from `sonarqube-token` Secret |
| `sonar-project-key` | `dtb-banking-portal` | SonarQube project key |
| `git-branch` | `main` | Branch for analysis context |

Fails the pipeline if Quality Gate status is not `OK`.

---

### `test-backend`
Runs the Jest test suite for the Node.js backend.

- **Unit tests** — `tests/unit/` (model + utility)
- **Integration tests** — `tests/integration/` (API with mongodb-memory-server)
- **Coverage gate** — 80% line coverage minimum

| Param | Default | Description |
|-------|---------|-------------|
| `coverage-threshold` | `80` | Minimum line coverage % |

---

### `npm-integration-test`
Dedicated integration test task that runs only `tests/integration/` in isolation. Use this when you need fine-grained parallelism or need to re-run integration tests independently.

| Param | Default | Description |
|-------|---------|-------------|
| `test-pattern` | `integration` | Jest path pattern |
| `timeout` | `120000` | Per-test timeout in ms |

**Results:** `test-status`, `tests-passed`, `tests-failed`

---

### `test-frontend`
Runs React Testing Library unit tests with a 60% line coverage gate.

| Param | Default | Description |
|-------|---------|-------------|
| `coverage-threshold` | `60` | Minimum line coverage % |

---

### `kaniko`
Builds and pushes a single Docker image using Kaniko (no Docker daemon, no privileged pods required). Called once for backend and once for frontend.

| Param | Default | Description |
|-------|---------|-------------|
| `image` | — | Full destination image ref (`registry/user/name:tag`) |
| `dockerfile` | `Dockerfile` | Dockerfile path relative to context |
| `context` | `.` | Build context relative to workspace root |
| `build-target` | `production` | Multi-stage build target |
| `cache-enabled` | `true` | Enable layer caching |

**Results:** `image-digest` (sha256:...), `image-url`

---

### `trivy-scan`
Scans both built images for known CVEs using Trivy. JSON reports are saved to the workspace for audit.

| Param | Default | Description |
|-------|---------|-------------|
| `severity` | `HIGH,CRITICAL` | Severity levels that fail the pipeline |
| `exit-code` | `1` | Set to `0` to make scan advisory only |
| `image-tag` | — | Tag generated by `generate-tag` |

---

### `cosign-sign`
Signs both images using Cosign with a key stored in a Kubernetes Secret. Kyverno admission policies (in `manifests/security/`) enforce that only signed images can be deployed.

**One-time setup:**
```bash
cosign generate-key-pair k8s://tekton-pipelines/cosign-key
```

| Param | Default | Description |
|-------|---------|-------------|
| `cosign-key-secret` | `cosign-key` | Secret containing the private key |
| `image-tag` | — | Tag to sign |

---

### `update-manifests`
Implements the GitOps promotion step. Updates `manifests/k8s/kustomization.yaml` with the new image tag and pushes the commit to the repository. ArgoCD detects the change and syncs the cluster.

```bash
# What this task runs:
kustomize edit set image DOCKERHUB_USERNAME/banking-backend=<user>/banking-backend:<tag>
kustomize edit set image DOCKERHUB_USERNAME/banking-frontend=<user>/banking-frontend:<tag>
git commit -m "ci: update image tags to <tag>"
git push
```

| Param | Default | Description |
|-------|---------|-------------|
| `image-tag` | — | New image tag |
| `git-token-secret` | `git-credentials` | Secret with `GIT_TOKEN` key |

---

### `smoke-test`
Validates the deployed application by hitting health and API endpoints with retries.

| Endpoint checked | Expected status |
|-----------------|-----------------|
| `GET /health` (backend) | 200 |
| `GET /api/accounts` (backend) | 401 (auth required — confirms routing works) |
| `GET /health` (frontend) | 200 |
| `GET /` (frontend) | 200 |

| Param | Default | Description |
|-------|---------|-------------|
| `max-retries` | `10` | Retry attempts per endpoint |
| `retry-interval` | `10` | Seconds between retries |

---

## Pipeline Reference

### CI Pipeline (`banking-ci-pipeline`)

**Trigger:** Any push to `main` or pull request opened/updated.

**Task execution graph:**
```
git-clone
    │
generate-tag
    │
    ├──────────────────────────┐
lint-sast              sonarqube-scan
    │                          │
    ├──────────┐               │
test-backend  test-frontend    │
    │          │               │
npm-integration-test ──────────┘
    │
kaniko (backend) + kaniko (frontend)   [parallel]
    │
trivy-scan (backend) + trivy-scan (frontend)   [parallel]
    │
cosign-sign (backend) + cosign-sign (frontend)   [parallel]
    │
update-manifests
```

**Parameters passed by the trigger:**

| Parameter | Source |
|-----------|--------|
| `git-url` | Webhook payload `body.repository.clone_url` |
| `git-revision` | Webhook payload `body.after` (full SHA) |
| `docker-username` | `docker-hub-params` Secret |
| `sonar-token` | `sonarqube-token` Secret |

---

### CD Pipeline (`banking-cd-pipeline`)

**Trigger:** Manually, or after ArgoCD detects the manifest commit from the CI pipeline.

**Stages:**
1. `git-clone` — clone the manifests repo
2. `smoke-test` — validate staging deployment
3. `promote-to-production` — update the production environment overlay

---

## Trigger Setup

### 1. Apply all Tekton resources

```bash
# Prerequisites first
kubectl apply -f manifests/tekton/rbac/
kubectl apply -f manifests/tekton/workspaces/

# Tasks
kubectl apply -f manifests/tekton/tasks/

# Pipelines
kubectl apply -f manifests/tekton/pipelines/

# Triggers
kubectl apply -f manifests/tekton/triggers/
```

### 2. Create required Secrets

```bash
# Docker Hub credentials
kubectl create secret docker-registry regcred \
  --docker-username=$DOCKER_USERNAME \
  --docker-password=$DOCKER_PASSWORD \
  -n tekton-pipelines

# Docker Hub username param (for pipeline params)
kubectl create secret generic docker-hub-params \
  --from-literal=DOCKER_USERNAME=$DOCKER_USERNAME \
  -n tekton-pipelines

# GitHub token (for cloning private repos + pushing manifest updates)
kubectl create secret generic git-credentials \
  --from-literal=GIT_TOKEN=$GITHUB_TOKEN \
  -n tekton-pipelines

# SonarQube token
kubectl create secret generic sonarqube-token \
  --from-literal=SONAR_TOKEN=$SONAR_TOKEN \
  -n tekton-pipelines

# GitHub webhook secret (must match what you configure in GitHub)
kubectl create secret generic github-webhook-secret \
  --from-literal=webhook-secret=$WEBHOOK_SECRET \
  -n tekton-pipelines

# Cosign key pair (one-time)
cosign generate-key-pair k8s://tekton-pipelines/cosign-key
```

### 3. Expose the EventListener

```bash
# Port-forward for local testing
kubectl port-forward svc/el-banking-event-listener -n tekton-pipelines 8080:8080

# Or get the NodePort
kubectl get svc el-banking-event-listener -n tekton-pipelines
```

### 4. Configure GitHub Webhook

In your GitHub repository → **Settings → Webhooks → Add webhook:**

| Field | Value |
|-------|-------|
| Payload URL | `http://<your-ip>:8080/` |
| Content type | `application/json` |
| Secret | value of `$WEBHOOK_SECRET` |
| Events | `push`, `pull requests` |

---

## Running the Pipeline Manually

```bash
# Trigger a one-off PipelineRun without a webhook
kubectl create -f - <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: banking-ci-manual-
  namespace: tekton-pipelines
spec:
  pipelineRef:
    name: banking-ci-pipeline
  serviceAccountName: tekton-pipeline-sa
  params:
    - name: git-url
      value: https://github.com/YOUR_ORG/DTB-tets.git
    - name: git-revision
      value: main
    - name: image-tag
      value: manual-$(date +%Y%m%d-%H%M%S)
    - name: docker-username
      value: YOUR_DOCKER_USERNAME
    - name: sonar-token
      value: YOUR_SONAR_TOKEN
  workspaces:
    - name: pipeline-workspace
      persistentVolumeClaim:
        claimName: pipeline-workspace-pvc
    - name: docker-credentials
      secret:
        secretName: regcred
  timeouts:
    pipeline: "1h0m0s"
EOF
```

---

## Monitoring Pipeline Runs

```bash
# List all pipeline runs
tkn pipelinerun list -n tekton-pipelines

# Watch a specific run
tkn pipelinerun logs banking-ci-run-<id> -f -n tekton-pipelines

# Describe a run to see task statuses
tkn pipelinerun describe banking-ci-run-<id> -n tekton-pipelines

# List task runs
tkn taskrun list -n tekton-pipelines

# Open Tekton Dashboard
kubectl port-forward svc/tekton-dashboard -n tekton-dashboard 9097:9097
# Visit: http://localhost:9097
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `git-clone` fails with auth error | `git-credentials` Secret missing or wrong token | Re-create the Secret with a valid `GIT_TOKEN` |
| `kaniko` push fails with `unauthorized` | `regcred` Secret missing in `tekton-pipelines` namespace | Run the `kubectl create secret docker-registry` command above |
| `trivy-scan` fails immediately | Image not yet pushed / wrong tag | Check `build-push` task completed; verify image exists in Docker Hub |
| `sonarqube-scan` times out | SonarQube pod not ready | `kubectl get pods -n sonarqube` — may need 5 min on first start |
| EventListener not receiving events | Webhook URL unreachable | Confirm port-forward is running or NodePort is accessible |
| `cosign-sign` fails with key error | `cosign-key` Secret not created | Run `cosign generate-key-pair k8s://tekton-pipelines/cosign-key` |
| Pipeline workspace full | PVC 5Gi exhausted by large images | Increase PVC size in `workspaces/pvc.yaml` or add a cleanup task |
