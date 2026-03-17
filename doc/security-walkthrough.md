# Security Stack Walkthrough — DTB Banking Portal

End-to-end guide for initialising, validating, and operating every security
component in the Kubernetes-based CI/CD pipeline.

> **Related files**
> - [`scripts/k8s/security-init.sh`](../scripts/k8s/security-init.sh) — single script that runs all steps below
> - [`manifests/security/kyverno-policies.yaml`](../manifests/security/kyverno-policies.yaml) — admission policies
> - [`manifests/security/network-policy.yaml`](../manifests/security/network-policy.yaml) — network isolation rules
> - [`policies/k8s-security.rego`](../policies/k8s-security.rego) — OPA/Conftest manifest policies
> - [`doc/security.md`](./security.md) — application-level security (auth, headers, rate limiting)

---

## Architecture Overview

```
 Developer Push
      │
      ▼
 ┌─────────────────────────────────────────────────────────┐
 │  Tekton CI Pipeline                                      │
 │                                                          │
 │  git-clone → lint-sast ──► conftest (OPA)               │
 │                    │                                     │
 │                    └──► sonarqube-scan                   │
 │                              │                           │
 │  test-backend/frontend ──────┘                           │
 │       │                                                  │
 │  kaniko (build) → trivy-scan → cosign-sign               │
 │                                     │                    │
 │                             update-manifests (GitOps)    │
 └─────────────────────────────────────────────────────────┘
                                     │
                                     ▼
 ┌─────────────────────────────────────────────────────────┐
 │  Kubernetes Admission (Kyverno)                          │
 │                                                          │
 │  Pod created? → require-signed-images   (cosign verify) │
 │              → disallow-privileged-containers            │
 │              → require-non-root-user                     │
 │              → disallow-privilege-escalation             │
 │              → require-resource-limits                   │
 │              → require-readonly-rootfs                   │
 │              → disallow-latest-tag                       │
 └─────────────────────────────────────────────────────────┘
                                     │
                                     ▼
 ┌─────────────────────────────────────────────────────────┐
 │  Runtime                                                 │
 │  Vault ──► ESO ──► K8s Secrets ──► Pods                 │
 │  (secret/banking/backend|mongodb)                        │
 │  NetworkPolicy — zero-trust within banking namespace     │
 └─────────────────────────────────────────────────────────┘
```

---

## Prerequisites

Before running `security-init.sh`, ensure the following are installed
(see [`scripts/prerequisites.sh`](../scripts/prerequisites.sh)):

| Tool | Minimum Version | Purpose |
|------|-----------------|---------|
| `kubectl` | 1.28+ | Cluster interaction |
| `helm` | 3.12+ | Chart installs |
| `cosign` | 2.0+ | Image signing |
| `trivy` | 0.50+ | CVE scanning |
| `conftest` | 0.46+ | OPA policy testing |
| `python3` | 3.8+ | Key substitution in script |
| `minikube` | 1.32+ | Local cluster |

Cluster must have these namespaces and deployments running:

```bash
kubectl get ns banking kyverno sonarqube vault external-secrets monitoring
kubectl get pods -n kyverno
kubectl get pods -n vault
kubectl get pods -n external-secrets
```

---

## Quick Start

```bash
# Full initialisation — interactive (prompts for passwords/tokens)
./scripts/k8s/security-init.sh

# Non-interactive with env vars pre-set
VAULT_ROOT_TOKEN=root \
SONAR_ADMIN_PASS=admin \
DOCKER_USERNAME=myuser \
./scripts/k8s/security-init.sh

# Dry run — print every action without executing
./scripts/k8s/security-init.sh --dry-run

# Skip slow components during development
./scripts/k8s/security-init.sh --skip-sonarqube --skip-trivy
```

The script runs 11 steps sequentially and prints a security posture report
at the end showing PASS / WARN / FAIL per component.

---

## Step-by-Step Reference

### Step 1 — Preflight

Checks that the cluster is reachable and that all required namespaces and
binaries are present. Namespaces are created automatically if missing.

```bash
# Manual check
kubectl cluster-info
kubectl get ns banking kyverno sonarqube vault external-secrets
command -v cosign trivy conftest helm
```

---

### Step 2 — Trivy (Container Vulnerability Scanning)

Trivy scans container images for known CVEs. It runs in two places:

1. **CI pipeline** — `manifests/tekton/tasks/trivy-scan.yaml` — blocks the
   pipeline if `HIGH` or `CRITICAL` severities are found.
2. **security-init.sh** — verifies the binary works and updates the DB.

```bash
# Update the vulnerability database
trivy image --download-db-only

# Scan a specific image (exit 1 on HIGH/CRITICAL)
trivy image --severity HIGH,CRITICAL --exit-code 1 \
  myuser/banking-backend:main-abc1234-20260316

# Scan with full JSON output
trivy image --format json --output trivy-report.json \
  myuser/banking-backend:main-abc1234-20260316

# Scan the filesystem (in CI before build)
trivy fs --severity HIGH,CRITICAL --exit-code 1 .
```

**Tuning severity thresholds** — edit `manifests/tekton/tasks/trivy-scan.yaml`:
```yaml
- name: SEVERITY
  value: "HIGH,CRITICAL"   # Change to MEDIUM,HIGH,CRITICAL to tighten
- name: EXIT_CODE
  value: "1"               # Set to 0 to make failures non-blocking (warn only)
```

---

### Step 3 — SonarQube (Static Code Analysis)

SonarQube scans source code for bugs, vulnerabilities, and code smells.
The pipeline task (`sonarqube-scan.yaml`) enforces the **Quality Gate** —
pipeline fails if the gate status is not `OK`.

**Access the UI:**
```bash
kubectl port-forward svc/sonarqube-sonarqube -n sonarqube 9000:9000 &
open http://localhost:9000
# Credentials: admin / admin (change after first login)
```

**Project:** `dtb-banking-portal`

**Quality Gate rules (Sonar Way defaults):**
- New bugs: 0
- New vulnerabilities: 0
- New code smells: ≤ 5
- New coverage: ≥ 80%
- New duplications: ≤ 3%

**Generate a new analysis token manually:**
```bash
curl -su admin:admin \
  -X POST "http://localhost:9000/api/user_tokens/generate" \
  -d "name=my-token&type=GLOBAL_ANALYSIS_TOKEN" \
  | python3 -m json.tool
```

**Check Quality Gate status:**
```bash
curl -su admin:admin \
  "http://localhost:9000/api/qualitygates/project_status?projectKey=dtb-banking-portal" \
  | python3 -m json.tool
```

---

### Step 4 — Kyverno (Admission Policy Enforcement)

Kyverno intercepts every Pod/Deployment creation and validates it against
the policies in [`manifests/security/kyverno-policies.yaml`](../manifests/security/kyverno-policies.yaml).

**Active policies:**

| Policy | Mode | What it enforces |
|--------|------|-----------------|
| `require-resource-limits` | Audit | CPU + memory limits on all containers |
| `disallow-privileged-containers` | Enforce | No `privileged: true` |
| `require-non-root-user` | Enforce | `runAsNonRoot: true` or `runAsUser > 0` |
| `disallow-privilege-escalation` | Enforce | `allowPrivilegeEscalation: false` |
| `disallow-latest-tag` | Audit | Images must use a specific tag, not `:latest` |
| `require-signed-images` | Audit | Images must be cosign-signed (see Step 5) |
| `require-readonly-rootfs` | Audit | `readOnlyRootFilesystem: true` |

> `Audit` mode logs violations but allows the Pod. `Enforce` mode blocks the Pod.
> Change `Audit` → `Enforce` when all workloads are compliant.

**Verify policies are active:**
```bash
kubectl get clusterpolicies
kubectl get clusterpolicies -o wide
```

**Check policy violations:**
```bash
# Per-namespace policy report
kubectl get policyreport -n banking

# Detailed violations
kubectl describe policyreport -n banking

# All namespaces
kubectl get policyreport -A
```

**Re-apply policies after editing:**
```bash
kubectl apply -f manifests/security/kyverno-policies.yaml
```

---

### Step 5 — Cosign (Image Signing & Verification)

Every image built by the Tekton pipeline is signed using Cosign. The
private key is stored as a Kubernetes Secret; the public key is embedded
in the Kyverno `require-signed-images` policy.

#### Key Generation

The script generates the key pair once and stores it as a cluster secret:

```bash
# Generate key pair (run once — security-init.sh does this automatically)
COSIGN_PASSWORD="" cosign generate-key-pair k8s://tekton-pipelines/cosign-key

# Inspect the generated secret
kubectl get secret cosign-key -n tekton-pipelines -o yaml

# Extract and view the public key
kubectl get secret cosign-key -n tekton-pipelines \
  -o jsonpath='{.data.cosign\.pub}' | base64 -d

# The public key is also saved to the repo root by security-init.sh
cat cosign.pub
```

#### Where the Keys Are Used

| Location | Key | Purpose |
|----------|-----|---------|
| `k8s://tekton-pipelines/cosign-key` | Private | Tekton `cosign-sign` task signs images |
| `k8s://banking/cosign-key` | Private (mirror) | Available if signing runs in banking ns |
| `banking/cosign-pubkey` ConfigMap | Public | Kyverno reads for admission verification |
| `cosign.pub` (repo root) | Public | Manual `cosign verify` + pipeline reference |
| `kyverno-policies.yaml` | Public (embedded) | `require-signed-images` policy |

#### Signing an Image (what the pipeline does)

```bash
# The cosign-sign task does this automatically — shown here for reference
cosign sign \
  --key k8s://tekton-pipelines/cosign-key \
  --tlog-upload=false \
  myuser/banking-backend:main-abc1234-20260316
```

#### Verifying a Signed Image

```bash
# Verify against the local public key
cosign verify \
  --key cosign.pub \
  --insecure-ignore-tlog=true \
  myuser/banking-backend:main-abc1234-20260316

# Verify using the cluster secret
cosign verify \
  --key k8s://tekton-pipelines/cosign-key \
  --insecure-ignore-tlog=true \
  myuser/banking-backend:main-abc1234-20260316
```

#### Updating the Kyverno Policy with a New Key

If you regenerate the cosign key pair (e.g. key rotation), re-run the
security init script — it detects the new key and re-applies the policy:

```bash
# Delete the old secret to force regeneration
kubectl delete secret cosign-key -n tekton-pipelines
kubectl delete secret cosign-key -n banking

# Re-run (will generate new key and update Kyverno policy)
./scripts/k8s/security-init.sh --skip-trivy --skip-sonarqube \
  --skip-vault --skip-eso --skip-conftest --skip-netpol
```

---

### Step 6 — Vault (Secrets Management)

HashiCorp Vault (running in dev mode on minikube) stores all sensitive
application secrets. Pods never receive secrets directly — they are synced
via ESO (Step 7).

**Access the UI:**
```bash
kubectl port-forward svc/vault -n vault 8200:8200 &
open http://localhost:8200
# Token: root (dev mode)
```

**Secret paths:**

| Path | Contents |
|------|----------|
| `secret/banking/backend` | `JWT_SECRET`, `MONGO_APP_PASSWORD`, `NODE_ENV`, rate limit config |
| `secret/banking/mongodb` | `MONGO_ROOT_USER`, `MONGO_ROOT_PASSWORD`, `MONGO_APP_USER`, `MONGO_APP_PASSWORD` |

**Read secrets manually (for debugging):**
```bash
# Via kubectl exec into the Vault pod
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN=root vault kv get secret/banking/backend"

kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN=root vault kv get secret/banking/mongodb"
```

**Update a secret:**
```bash
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN=root vault kv patch secret/banking/backend \
    JWT_SECRET='new-64-char-secret-here'"
```

**ESO policy (what ESO is allowed to do):**
```hcl
# eso-banking-policy
path "secret/data/banking/*" {
  capabilities = ["read", "list"]
}
```

---

### Step 7 — ESO (External Secrets Operator)

ESO watches `ExternalSecret` resources and pulls values from Vault into
native Kubernetes `Secret` objects on a 5-minute refresh cycle.

**Architecture:**
```
Vault (secret/banking/*)
        │
        │  token auth (vault-eso-token secret)
        ▼
ClusterSecretStore/vault-backend
        │
        ├──► ExternalSecret/banking-backend-secrets ──► Secret/backend-secret
        │
        └──► ExternalSecret/banking-mongodb-secrets ──► Secret/mongodb-secret
```

> **Why `ClusterSecretStore` not `SecretStore`?**
> `SecretStore` is namespace-scoped and cannot reference secrets in other
> namespaces (`tokenSecretRef.namespace` is invalid on it). `ClusterSecretStore`
> is cluster-scoped and correctly supports `tokenSecretRef.namespace: external-secrets`.

**Check sync status:**
```bash
# Should show Ready / SecretSynced
kubectl get externalsecret -n banking

# Detailed status and last sync time
kubectl describe externalsecret banking-backend-secrets -n banking
kubectl describe externalsecret banking-mongodb-secrets -n banking

# Verify the secrets were created
kubectl get secret backend-secret -n banking
kubectl get secret mongodb-secret -n banking

# Inspect a synced secret (base64-encoded values)
kubectl get secret backend-secret -n banking -o jsonpath='{.data.JWT_SECRET}' | base64 -d
```

**Force a manual resync:**
```bash
kubectl annotate externalsecret banking-backend-secrets \
  force-sync=$(date +%s) -n banking --overwrite
```

**Troubleshooting ESO sync failures:**
```bash
# Check ESO operator logs
kubectl logs -n external-secrets \
  -l app.kubernetes.io/name=external-secrets --tail=50

# Check ClusterSecretStore status
kubectl get clustersecretstore vault-backend
kubectl describe clustersecretstore vault-backend

# Verify the vault-eso-token secret exists
kubectl get secret vault-eso-token -n external-secrets

# Verify RBAC — ESO ServiceAccount must be able to read the token
kubectl auth can-i get secret/vault-eso-token \
  --namespace external-secrets \
  --as system:serviceaccount:external-secrets:external-secrets
```

---

### Step 8 — Conftest / OPA (Manifest Policy Testing)

Conftest runs OPA policies defined in [`policies/k8s-security.rego`](../policies/k8s-security.rego)
against Kubernetes manifests **before** they are applied — catching
misconfigurations at development time (shift-left).

Conftest also runs inside the Tekton pipeline as the `conftest-policies`
step in the `lint-sast` task.

**Run locally:**
```bash
# Check all deployment manifests
conftest test manifests/k8s/backend/deployment.yaml \
  manifests/k8s/frontend/deployment.yaml \
  manifests/k8s/mongodb/statefulset.yaml \
  --policy policies/ --output table

# Check everything in k8s/ recursively
find manifests/k8s -name "*.yaml" \
  | xargs conftest test --policy policies/ --output table

# JSON output for CI parsing
conftest test manifests/k8s/backend/deployment.yaml \
  --policy policies/ --output json | python3 -m json.tool
```

**Active OPA rules (`policies/k8s-security.rego`):**

| Rule | Type | Checks |
|------|------|--------|
| `deny` — no CPU limit | Deny | `resources.limits.cpu` must be set |
| `deny` — no memory limit | Deny | `resources.limits.memory` must be set |
| `deny` — privileged | Deny | `securityContext.privileged != true` |
| `deny` — priv escalation | Deny | `allowPrivilegeEscalation == false` |
| `deny` — no namespace | Deny | `metadata.namespace` must be set |
| `deny` — service no selector | Deny | Services must have a pod selector |
| `warn` — no readinessProbe | Warn | Containers should have readiness probes |
| `warn` — no livenessProbe | Warn | Containers should have liveness probes |
| `warn` — single replica | Warn | Deployments with 1 replica have no HA |
| `warn` — missing label | Warn | `app.kubernetes.io/part-of` should be set |

**Adding a new policy:**
```rego
# Example: deny containers with no image tag (untagged = :latest behaviour)
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not contains(container.image, ":")
  msg := sprintf("DENY Container '%v' must specify an image tag", [container.name])
}
```

---

### Step 9 — Network Policies

Zero-trust network isolation is applied to the `banking` namespace via
[`manifests/security/network-policy.yaml`](../manifests/security/network-policy.yaml).

**Policy summary:**

| Policy | Allows | Denies |
|--------|--------|--------|
| `deny-all-ingress` | Nothing (default deny) | All inbound traffic |
| `deny-all-egress` | Nothing (default deny) | All outbound traffic |
| `allow-frontend-ingress` | Ingress from anywhere on port 80 | Everything else |
| `allow-backend-from-frontend` | Frontend → Backend on port 3001 | Direct external access |
| `allow-mongodb-from-backend` | Backend → MongoDB on port 27017 | Frontend → MongoDB |
| `allow-dns-egress` | All pods → kube-dns on 53/UDP+TCP | Other egress |
| `allow-backend-egress` | Backend → MongoDB + external HTTPS | Other egress |

**Verify policies:**
```bash
kubectl get networkpolicy -n banking
kubectl describe networkpolicy -n banking
```

**Test isolation (example):**
```bash
# This should fail — frontend cannot reach mongodb directly
kubectl run test --image=alpine -n banking --rm -it -- \
  nc -zv mongodb-service 27017
```

---

## Security Posture Report

After `security-init.sh` completes, the report shows:

```
══ Security Posture Report ══

  PASS (7): trivy sonarqube kyverno cosign vault eso network-policy
  WARN (1): conftest
  FAIL (0):
```

**PASS** = Component initialised and verified successfully.
**WARN** = Component installed but something needs attention (see script output).
**FAIL** = Critical failure — pipeline will not work correctly until resolved.

---

## Verifying the Full Pipeline Flow

Once all components are initialised, trigger an end-to-end security scan:

```bash
# 1. Run conftest against all manifests
conftest test manifests/k8s/backend/deployment.yaml --policy policies/

# 2. Scan the backend image with Trivy
trivy image --severity HIGH,CRITICAL myuser/banking-backend:latest

# 3. Verify the image is signed
cosign verify --key cosign.pub --insecure-ignore-tlog=true \
  myuser/banking-backend:main-abc1234-20260316

# 4. Check Kyverno is blocking unsigned/non-compliant pods
kubectl run bad-pod --image=nginx:latest -n banking 2>&1
# Expected: admission webhook denied or audit log entry

# 5. Check ESO secrets are synced
kubectl get externalsecret -n banking
kubectl get secret backend-secret mongodb-secret -n banking

# 6. Confirm SonarQube Quality Gate is passing
curl -su admin:admin \
  "http://localhost:9000/api/qualitygates/project_status?projectKey=dtb-banking-portal"
```

---

## Key Rotation Procedures

### Rotate Cosign Keys

```bash
# Delete existing keys
kubectl delete secret cosign-key -n tekton-pipelines
kubectl delete secret cosign-key -n banking

# Re-run cosign setup (security-init.sh handles Kyverno policy update)
./scripts/k8s/security-init.sh \
  --skip-trivy --skip-sonarqube --skip-vault \
  --skip-eso --skip-conftest --skip-netpol
```

### Rotate Vault ESO Token

```bash
# Create a new token in Vault
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN=root vault token create \
    -policy=eso-banking-policy -ttl=8760h -format=json" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])"

# Update the secret
kubectl create secret generic vault-eso-token \
  --from-literal=token=<new-token> \
  -n external-secrets --dry-run=client -o yaml | kubectl apply -f -

# Force ESO resync
kubectl annotate externalsecret banking-backend-secrets \
  force-sync=$(date +%s) -n banking --overwrite
```

### Rotate JWT Secret

```bash
# Write new secret to Vault
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_TOKEN=root vault kv patch secret/banking/backend \
    JWT_SECRET=$(openssl rand -hex 64)"

# ESO will sync within 5 minutes, or force immediately:
kubectl annotate externalsecret banking-backend-secrets \
  force-sync=$(date +%s) -n banking --overwrite
```

---

## Troubleshooting

### Kyverno blocking a legitimate pod

```bash
# Check what's blocking it
kubectl describe pod <pod-name> -n banking
kubectl get policyreport -n banking -o yaml

# Temporarily switch a policy to Audit to unblock
kubectl patch clusterpolicy require-signed-images \
  --type='merge' \
  -p '{"spec":{"validationFailureAction":"Audit"}}'
```

### ESO not syncing

```bash
# 1. Check ClusterSecretStore is Ready
kubectl get clustersecretstore vault-backend

# 2. Check ESO can reach Vault
kubectl exec -n external-secrets \
  $(kubectl get pod -n external-secrets -l app.kubernetes.io/name=external-secrets -o name | head -1) \
  -- curl -s http://vault.vault.svc.cluster.local:8200/v1/sys/health

# 3. Check RBAC
kubectl auth can-i get secret/vault-eso-token \
  --namespace external-secrets \
  --as system:serviceaccount:external-secrets:external-secrets

# 4. Check ESO logs
kubectl logs -n external-secrets \
  -l app.kubernetes.io/name=external-secrets --tail=100 | grep -i error
```

### Cosign verify failing

```bash
# Ensure you're using the right public key
kubectl get secret cosign-key -n tekton-pipelines \
  -o jsonpath='{.data.cosign\.pub}' | base64 -d > /tmp/cosign-cluster.pub

cosign verify --key /tmp/cosign-cluster.pub \
  --insecure-ignore-tlog=true \
  myuser/banking-backend:main-abc1234-20260316
```

### SonarQube Quality Gate failing

```bash
# Check which rules are failing
curl -su admin:admin \
  "http://localhost:9000/api/qualitygates/project_status?projectKey=dtb-banking-portal" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for cond in data['projectStatus']['conditions']:
    if cond['status'] != 'OK':
        print(cond)
"
```

---

## Security Checklist (Kubernetes / Pipeline)

- [x] Trivy image scanning in CI — blocks on HIGH/CRITICAL CVEs
- [x] SonarQube static analysis — Quality Gate enforced
- [x] Kyverno admission policies — 7 policies active in banking namespace
- [x] Cosign image signing — all pipeline-built images are signed
- [x] Kyverno signature verification — `require-signed-images` policy active
- [x] Vault KV store — secrets never in plaintext in manifests or env files
- [x] ESO secret sync — `ClusterSecretStore` + `ExternalSecret` per component
- [x] ESO RBAC — least-privilege token reader role for `vault-eso-token`
- [x] OPA/Conftest — manifest policies enforced in CI and locally
- [x] Network policies — zero-trust isolation in banking namespace
- [x] Cosign keys in Kubernetes Secrets — not on disk or in source control
- [ ] Upgrade Kyverno `require-signed-images` from Audit → Enforce once all images are signed
- [ ] Upgrade `require-resource-limits` and `disallow-latest-tag` to Enforce
- [ ] Enable Vault Kubernetes auth (replace token auth for production)
- [ ] Enable Vault audit logging (`vault audit enable file file_path=/vault/logs/audit.log`)
- [ ] Add TLS to Vault (`VAULT_ADDR=https://...`)
- [ ] Set up Vault unsealing with cloud KMS (not dev mode) for production
