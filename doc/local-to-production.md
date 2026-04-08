# Local Dev → Production: What Must Change

This document is a line-level audit of every assumption, placeholder, and
local-only value in the codebase that will break — or silently misbehave —
when the stack is deployed to a real server. It is structured by concern so
engineers can work through each area independently.

---

## Table of Contents

1. [Cluster Provisioning](#1-cluster-provisioning)
2. [Secrets & Vault](#2-secrets--vault)
3. [Container Registry](#3-container-registry)
4. [Networking & Ingress](#4-networking--ingress)
5. [Storage](#5-storage)
6. [Resource Sizing](#6-resource-sizing)
7. [GitOps & ArgoCD](#7-gitops--argocd)
8. [CI/CD — Tekton](#8-cicd--tekton)
9. [Application Config](#9-application-config)
10. [Observability](#10-observability)
11. [Database — MongoDB](#11-database--mongodb)
12. [Security Policies](#12-security-policies)
13. [Port-Forwards & UIs](#13-port-forwards--uis)
14. [Priority Order](#14-priority-order)

---

## 1. Cluster Provisioning

### What exists now

Every bootstrap script spins up a local minikube cluster before anything else:

```bash
# scripts/prerequisites.sh
MINIKUBE_VERSION="v1.38.1"
MINIKUBE_CPUS="4"
MINIKUBE_MEMORY="8192"
MINIKUBE_DISK="40g"
MINIKUBE_K8S_VERSION="v1.32.3"

minikube start \
  --driver=docker \
  --cpus=$MINIKUBE_CPUS \
  --memory=$MINIKUBE_MEMORY \
  --disk-size=$MINIKUBE_DISK \
  --kubernetes-version=$MINIKUBE_K8S_VERSION \
  --addons=ingress,metrics-server,storage-provisioner
```

`argocd-init.sh`, `tekton-init.sh`, and `observability-init.sh` all contain the
same `minikube start` fallback block (copy-pasted). The minikube API server IP
`192.168.49.2:8443` is referenced directly in at least one script.

### What must change

| Item | Local value | Production requirement |
|------|-------------|----------------------|
| Cluster driver | `minikube --driver=docker` | EKS / GKE / AKS / bare-metal kubeadm |
| Addons | `minikube addons enable ingress` | Helm-installed ingress-nginx or cloud LB |
| Metrics server | minikube built-in | `metrics-server` Helm chart |
| API server IP | `192.168.49.2:8443` | Real cluster endpoint from kubeconfig |
| CPU/RAM ceiling | 4 vCPU / 8 GiB | Sized to workload SLA (see §6) |

**Action:** Strip all `minikube start` blocks from `prerequisites.sh`,
`argocd-init.sh`, `tekton-init.sh`, and `observability-init.sh`. Replace with
a preflight check that simply asserts `kubectl cluster-info` succeeds. Cluster
creation is out-of-scope for a bootstrap script in production.

---

## 2. Secrets & Vault

This is the highest-risk area. Multiple layers of insecure defaults exist.

### 2a. Vault dev mode

```bash
# scripts/prerequisites.sh
helm install vault hashicorp/vault \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root"
```

Dev mode means:
- All secrets are in-memory only — lost on pod restart
- The root token is the literal string `"root"`
- TLS is disabled
- No audit log
- No unsealing — Vault starts pre-unsealed

### 2b. Hardcoded root token

```bash
# scripts/k8s/vault-credentials.sh  (line 24)
VAULT_TOKEN="root"

# scripts/k8s/security-init.sh  (line 369)
VAULT_ROOT_TOKEN="${VAULT_ROOT_TOKEN:-root}"
```

The default is used if the environment variable is not set. In every CI/CD and
bootstrap run without explicit override this token is `root`.

### 2c. Placeholder passwords written to Vault

```bash
# scripts/k8s/security-init.sh  (lines 392-410)
JWT_SECRET="${JWT_SECRET:-CHANGE_ME_64_CHAR_RANDOM_STRING}"
MONGO_APP_PASSWORD="${MONGO_APP_PASSWORD:-CHANGE_ME_APP_PASSWORD}"
MONGO_ROOT_PASSWORD="${MONGO_ROOT_PASSWORD:-CHANGE_ME_ROOT_PASSWORD}"
```

These are written into Vault KV. Any deployment that doesn't set these
environment variables before running the script will write literal placeholder
strings as live secrets.

### 2d. ExternalSecret store uses HTTP

```yaml
# manifests/security/external-secrets/cluster-secret-store.yaml
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
```

Plain HTTP to Vault. In production all Vault traffic must be TLS.

### 2e. Rate-limit values written as Vault secrets

```bash
# scripts/k8s/vault-credentials.sh  (lines 251-256)
RATE_LIMIT_WINDOW_MS="60000"
RATE_LIMIT_MAX="100"
AUTH_RATE_LIMIT_MAX="5"
JWT_EXPIRES_IN="1h"
```

These are application tuning values, not secrets. They should be in a ConfigMap
controlled by the kustomize overlay, not in Vault, so they can be adjusted per
environment without rotating secrets.

### What must change

| Item | Required action |
|------|-----------------|
| Vault dev mode | Deploy Vault in HA mode with `server.ha.enabled=true`, auto-unseal via cloud KMS (AWS KMS / GCP CKMS / Azure Key Vault) |
| Root token | Generate via `vault operator init`, store unseal keys in a secure bootstrap envelope, never set in any script |
| Placeholder secrets | Require all secret env vars at deploy-time; fail the script if unset — no fallback defaults |
| Vault TLS | Issue a cert via cert-manager; set `server.extraEnvironmentVars.VAULT_CACERT` in the ESO ClusterSecretStore |
| ClusterSecretStore URL | `https://vault.vault.svc.cluster.local:8200` |
| App tuning values | Move `RATE_LIMIT_*`, `JWT_EXPIRES_IN` out of Vault and into environment-specific ConfigMaps |

---

## 3. Container Registry

### What exists now

```bash
# scripts/k8s/tekton-init.sh / vault-credentials.sh
DOCKER_REPO="muretimiriti/dtb-project"

# manifests/gitops/applicationset.yaml  (lines 33-34)
argocd-image-updater.argoproj.io/image-list: >-
  backend=muretimiriti/dtb-project-backend,
  frontend=muretimiriti/dtb-project-frontend

# manifests/tekton/tasks/build-push.yaml  (line 23)
image-registry default="docker.io"
```

Every image reference is tied to a single Docker Hub account
(`muretimiriti`). Docker Hub has rate limits (100 pulls/6h unauthenticated,
200/6h authenticated on free tier). Public repositories expose image layers.

```yaml
# manifests/k8s/backend/deployment.yaml  (line 68)
imagePullPolicy: Always
```

`Always` pulls on every pod start regardless of local cache — acceptable in
dev where you want the latest; adds latency and Docker Hub request cost in
production.

### What must change

| Item | Required action |
|------|-----------------|
| Registry | Move to a private registry: ECR, GCR, ACR, or self-hosted Harbor |
| Docker Hub username | Parameterise `DOCKER_REPO` — never hardcode a user account in manifests or scripts |
| `imagePullPolicy` | Change to `IfNotPresent` in production; only use `Always` in dev overlay |
| `regcred` ExternalSecret | Update Vault path and secret keys to match the new registry auth format |
| Image Updater write-back | Update `argocd-image-updater.argoproj.io/image-list` annotation in `applicationset.yaml` to use the new registry URLs |
| Kaniko destination | Update `build-push.yaml` destinations to the new private registry |
| Image digests | Prefer `image@sha256:...` references in prod overlay over mutable tags |

---

## 4. Networking & Ingress

### 4a. DNS hostnames

```yaml
# manifests/k8s/frontend/ingress.yaml  (line 25)
host: "banking.local"

# manifests/environments/dev/kustomization.yaml
host: "banking-dev.local"

# manifests/environments/staging/kustomization.yaml
host: "banking-staging.local"

# manifests/environments/prod/kustomization.yaml
host: "banking.dtb.local"
```

`.local` domains are non-routable outside the developer's machine. The
`/etc/hosts` workaround (`echo "$(minikube ip) banking.local" | sudo tee -a /etc/hosts`)
is cited in the README. None of this works on a real server.

### 4b. CORS allowed origins

```bash
# backend/src/config/env.js  (line 22)
allowedOrigins: process.env.ALLOWED_ORIGINS?.split(',') || ['http://localhost:3000']

# manifests/k8s/backend/configmap.yaml
ALLOWED_ORIGINS: "http://banking-frontend.banking.svc.cluster.local,http://localhost:3000"
```

`localhost:3000` is included in production-bound ConfigMap. This is an
unnecessary CORS hole.

### 4c. Nginx reverse proxy backend URL

```nginx
# frontend/nginx.conf  (line 24)
proxy_pass http://backend:5000/api/;

# Content-Security-Policy header  (line 13)
connect-src 'self' http://backend:5000 http://localhost:5000;
```

`backend` resolves via Docker Compose service DNS. On Kubernetes, the service
name is `banking-backend` (or `staging-banking-backend` in the staging
overlay). The nginx.conf is baked into the Docker image at build time — any
change requires a rebuild.

### 4d. Storage Class provisioner

```yaml
# manifests/platform/storage-class.yaml  (line 15)
provisioner: k8s.io/minikube-hostpath
```

This provisioner does not exist outside minikube. Volumes will fail to bind.

### What must change

| Item | Required action |
|------|-----------------|
| Ingress hosts | Replace `*.local` with real FQDNs registered in DNS (`banking.yourdomain.com`, `banking-staging.yourdomain.com`) |
| TLS | Add `tls:` block to each Ingress, reference cert-manager `Certificate` or cloud-managed cert |
| CORS origins | Set `ALLOWED_ORIGINS` per environment in overlay ConfigMap; remove `localhost` entirely from staging and prod |
| nginx `proxy_pass` | Make backend URL a build arg (`REACT_APP_API_URL`) resolved at image build time per environment, or use a relative path and let Nginx proxy based on the Ingress path rule |
| nginx CSP | Remove `http://localhost:5000` from `connect-src`; use relative origin (`'self'`) |
| Storage class | Replace `k8s.io/minikube-hostpath` with the cloud provider's provisioner: `ebs.csi.aws.com`, `pd.csi.storage.gke.io`, `disk.csi.azure.com` |
| Ingress controller | Switch from minikube addon to `helm install ingress-nginx` with a real LoadBalancer service |

---

## 5. Storage

### What exists now

```yaml
# manifests/k8s/mongodb/statefulset.yaml  (lines 145-157)
volumeClaimTemplates:
  - metadata:
      name: mongo-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 10Gi      # minikube-sized

  - metadata:
      name: mongo-config
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi

# manifests/platform/storage-class.yaml
provisioner: k8s.io/minikube-hostpath
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer

# manifests/observability/prometheus-values.yaml  (line 16)
storageClassName: standard-rwo     # minikube-specific

# manifests/observability/loki-values.yaml  (line 9)
storageClassName: standard-rwo     # minikube-specific
```

`hostpath` provisioner stores data on the minikube VM disk — it disappears
when the cluster is deleted. `standard-rwo` does not exist outside minikube.

### What must change

| Item | Required action |
|------|-----------------|
| Storage class provisioner | Cloud-specific CSI driver (see §4) |
| MongoDB data volume | Size to expected data volume + 3× headroom; 10Gi is almost certainly too small for production banking data |
| MongoDB HA | Move from `replicas: 1` StatefulSet to a 3-node replica set (see §11) |
| Prometheus storage | `storageClassName` must match the production storage class name |
| Loki storage | Same — and consider S3/GCS/Azure Blob for Loki chunks instead of block storage |
| Retention | Prometheus `7d` and Loki `168h` retention — audit and compliance may require 30–365 days |
| Backup | No backup strategy exists. Add Velero or cloud-native snapshots for MongoDB PVCs |

---

## 6. Resource Sizing

All CPU and memory values are tuned for a 4-CPU / 8 GiB minikube VM shared
across the entire stack. They will cause OOMKill or CPU throttling under any
meaningful production load.

### Current values vs. recommended minimums

| Component | Current requests | Current limits | Recommended prod minimum |
|-----------|-----------------|----------------|--------------------------|
| Backend | 100m CPU / 128Mi | 500m / 512Mi | 500m / 512Mi → 2 / 2Gi |
| Frontend (nginx) | 50m / 64Mi | 200m / 256Mi | 100m / 128Mi → 500m / 512Mi |
| MongoDB | 250m / 256Mi | 1000m / 1Gi | 1 / 2Gi → 4 / 8Gi |
| OTel Collector | not set | 200m / 512Mi | 500m / 1Gi |
| Prometheus | chart default | chart default | 2 / 4Gi (storage-bound) |

```yaml
# manifests/platform/resource-quota.yaml
hard:
  requests.cpu: "2"       # entire banking namespace capped at 2 vCPU
  requests.memory: "2Gi"
  limits.cpu: "4"
  limits.memory: "4Gi"
  requests.storage: "30Gi"
```

The namespace ResourceQuota prevents the backend from scaling — the HPA for
backend alone can reach 5 replicas × 500m = 2.5 vCPU, which exceeds the
`limits.cpu: "4"` quota once you add MongoDB and frontend.

### What must change

- Raise or remove the namespace ResourceQuota for production; re-apply it
  after load testing to right-size to actual usage.
- Update deployment resource requests/limits in each overlay's patch section.
- HPA `minReplicas`/`maxReplicas` values in `backend/hpa.yaml` and
  `frontend/hpa.yaml` need load-testing to determine appropriate bounds.

---

## 7. GitOps & ArgoCD

### 7a. Hardcoded repository URL

```yaml
# manifests/gitops/applicationset.yaml  (line 44)
repoURL: "https://github.com/muretimiriti/DTB-test.git"

# manifests/gitops/app-project.yaml  (line 24)
sourceRepos:
  - "https://github.com/muretimiriti/DTB-test.git"

# manifests/gitops/platform-application.yaml
# manifests/gitops/security-application.yaml
# manifests/gitops/observability-application.yaml
repoURL: "https://github.com/muretimiriti/DTB-test.git"
```

Five manifest files contain the GitHub URL of the original developer's fork.
Any team deploying this must fork to their own org and update all five.

### 7b. Bootstrap Application uses envsubst

```yaml
# manifests/argocd/application.yaml
repoURL: "${REPO_URL}"
```

This file uses a shell variable that is substituted by `argocd-init.sh` at
apply time. The five files above are applied by ArgoCD directly from git and
cannot use shell variables.

### 7c. Single cluster destination

```yaml
# manifests/gitops/app-project.yaml  (line 29)
destinations:
  - server: https://kubernetes.default.svc
```

`kubernetes.default.svc` is the in-cluster API server reference. All
Applications are constrained to deploy to the same cluster that hosts ArgoCD.
Multi-cluster deployments require registering additional cluster credentials
in ArgoCD and adding destination entries.

### 7d. ArgoCD insecure login

```bash
# scripts/k8s/argocd-init.sh  (line 210)
argocd login localhost:8080 \
  --username admin \
  --password "$ARGOCD_ADMIN_PASSWORD" \
  --insecure \
  --grpc-web
```

`--insecure` skips TLS verification. In production, ArgoCD must be behind
TLS and the CLI must verify the certificate.

### 7e. 30-minute polling interval

```bash
# scripts/k8s/argocd-init.sh  (line 13)
POLLING_INTERVAL="${POLLING_INTERVAL:-1800}"   # 30 minutes
```

30 minutes means a code push can take up to 30 minutes to appear in dev.
The alternative — webhook-based trigger — should be configured for production
so ArgoCD syncs within seconds of a git push.

### What must change

| Item | Required action |
|------|-----------------|
| All `repoURL` fields | Replace with your organisation's git server URL (GitHub Enterprise, GitLab, Bitbucket) |
| SSH vs HTTPS | Use SSH deploy keys or GitHub App credentials — not personal access tokens — for ArgoCD repo access |
| `--insecure` flag | Remove; configure ArgoCD with a valid TLS certificate (cert-manager + Let's Encrypt or internal CA) |
| Polling interval | Configure a GitHub/GitLab webhook pointing at the ArgoCD API server; set `timeout.reconciliation` to `0s` (webhook-only) |
| Multi-cluster | Register target cluster credentials and update `app-project.yaml` destinations |
| Admin password | Rotate the ArgoCD initial admin password immediately after first login; consider integrating SSO (Dex + OIDC/LDAP) |

---

## 8. CI/CD — Tekton

### 8a. Webhook trigger filter

```yaml
# manifests/tekton/triggers/event-listener.yaml  (line 28)
- key: body.ref
  operator: in
  values: ["refs/heads/main"]
```

Only pushes to `main` trigger a build. If your production workflow uses
release branches or tag-based promotions, this filter must be updated.

### 8b. Kaniko executor version

```yaml
# manifests/tekton/tasks/build-push.yaml  (line 40)
image: gcr.io/kaniko-project/executor:v1.23.2
```

Pinned to a specific version. Check for security advisories against this
version before going to production.

### 8c. Empty `REACT_APP_API_URL` build arg

```yaml
# manifests/tekton/tasks/build-push.yaml  (line 64)
--build-arg REACT_APP_API_URL=""
```

An empty API URL means the React app relies on relative paths and Nginx
proxy rules to reach the backend. This works when Nginx and the backend
are in the same cluster. If the frontend is served via CDN or a different
domain, this must be set to the absolute backend API URL.

### 8d. Pipeline notification endpoint

```yaml
# manifests/tekton/pipelines/ci-pipeline.yaml  (line 184)
url: "http://webhook-sink.tekton-pipelines.svc.cluster.local"
```

This in-cluster webhook sink does not exist — the `send-to-webhook-http`
finally task will fail silently (or loudly) on every pipeline run until a
real notification target is configured (Slack webhook, Teams, PagerDuty).

### 8e. SonarQube skipped by default

```yaml
# manifests/tekton/pipelines/ci-pipeline.yaml  (line 44)
- name: skip-sonarqube
  type: string
  default: "true"
```

SonarQube analysis is opt-in. For a production-grade pipeline, quality gate
enforcement should be mandatory — change the default to `"false"` and ensure
the SonarQube instance is properly provisioned.

### What must change

| Item | Required action |
|------|-----------------|
| Webhook filter | Update `values` to match your branch/tag strategy; add tag filter for production promotions |
| Kaniko version | Pin to latest stable; subscribe to `kaniko` release notifications |
| `REACT_APP_API_URL` | Set per environment in the build-push task params; use the real production API FQDN |
| Notification URL | Configure a real outbound webhook (Slack, Teams); remove or replace `webhook-sink` reference |
| SonarQube default | Set `skip-sonarqube: "false"`; provision a persistent SonarQube instance with a quality gate |
| Docker Hub rate limits | Authenticate Kaniko pulls with a service account token to avoid anonymous rate limits |

---

## 9. Application Config

### 9a. Backend allowed origins

```javascript
// backend/src/config/env.js  (line 22)
allowedOrigins: process.env.ALLOWED_ORIGINS?.split(',') || ['http://localhost:3000']
```

Fallback to `localhost:3000` means a misconfigured pod (missing env var)
silently opens CORS to localhost — which is a confused deputy risk in a
cluster where `localhost` could refer to the pod itself.

### 9b. Body size limit

```javascript
// backend/src/server.js  (line 45)
app.use(express.json({ limit: '10kb' }));
```

10 kB is very restrictive. Bulk transaction uploads, base64-encoded
documents, or any file attachment feature will need this raised. Document
the intended maximum payload size and set it explicitly per environment.

### 9c. MongoDB connection options

```javascript
// backend/src/config/database.js
serverSelectionTimeoutMS: 5000,
socketTimeoutMS: 45000
```

5-second server selection timeout is too aggressive for a production cluster
where MongoDB may be on a different node or behind a service mesh with
connection overhead. Recommend `serverSelectionTimeoutMS: 30000` in
production.

### 9d. JWT expiry

```bash
# scripts/k8s/vault-credentials.sh
JWT_EXPIRES_IN="1h"
```

One-hour expiry with no refresh token mechanism means users are logged out
every hour. Decide on a session policy (sliding expiry, refresh tokens) and
implement it before production.

### What must change

| Item | Required action |
|------|-----------------|
| `ALLOWED_ORIGINS` default | Change fallback from `localhost` to an empty string that throws an error if unset |
| Body size limit | Document and configure via env var; set different values per environment |
| MongoDB timeouts | Increase `serverSelectionTimeoutMS` to 30s; make both values configurable via env |
| JWT expiry | Define a session policy; implement refresh tokens or extend expiry based on UX requirements |
| `OPTIONS` method | Add `OPTIONS` to the CORS methods list so preflight requests succeed from browser clients |

---

## 10. Observability

### 10a. Prometheus and Loki storage class

```yaml
# manifests/observability/prometheus-values.yaml
storageClassName: standard-rwo    # minikube-specific; does not exist in production

# manifests/observability/loki-values.yaml
storageClassName: standard-rwo
```

Both will fail `PersistentVolumeClaim` binding on any non-minikube cluster.

### 10b. Internal cluster URLs hardcoded in OTel Collector

```yaml
# manifests/observability/otel-collector.yaml
exporters:
  prometheusremotewrite:
    endpoint: "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"
  loki:
    endpoint: "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
```

These DNS names assume the exact Helm release names `prometheus` (from
`kube-prometheus-stack`) and `loki` (from `loki-stack`) installed in the
`monitoring` namespace. If release names differ, the collector will drop all
telemetry silently.

### 10c. Retention too short for compliance

```yaml
# manifests/observability/prometheus-values.yaml
retention: "7d"

# manifests/observability/loki-values.yaml
retention_period: "168h"   # 7 days
```

Banking applications typically require 90–365 days of audit logs and
metrics depending on jurisdiction. Seven days is unusable for any incident
post-mortem beyond last week.

### What must change

| Item | Required action |
|------|-----------------|
| Storage class | Replace `standard-rwo` with the production provider's class name in both values files |
| Loki chunks | For production log volume, use Loki in Simple Scalable mode with S3/GCS/Blob object storage instead of a PVC |
| OTel endpoints | Parameterise Prometheus and Loki URLs via OTel ConfigMap; match actual Helm release names |
| Retention | Set Prometheus `retention: "90d"` and Loki `retention_period: "2160h"` (90d) at minimum; confirm with compliance team |
| Alerting | Configure Alertmanager receivers (PagerDuty, Slack, email) — currently no receivers are defined |
| Tracing backend | OTel collector has no trace exporter configured; add Jaeger or Tempo as a destination |

---

## 11. Database — MongoDB

### What exists now

```yaml
# manifests/k8s/mongodb/statefulset.yaml
spec:
  replicas: 1          # single node — no HA, no failover
  serviceName: mongodb-headless
```

A single-replica MongoDB has no replication, no automatic failover, and no
read scaling. Any pod restart causes a full database outage.

The `mongo:7.0` image is pinned to the major version only — patch updates
(`7.0.1` → `7.0.15`) apply automatically with `imagePullPolicy: IfNotPresent`
reset cycles, which can introduce unplanned upgrades.

No backup or point-in-time recovery mechanism exists anywhere in the stack.

### What must change

| Item | Required action |
|------|-----------------|
| Replica count | Deploy a 3-node replica set using Bitnami MongoDB Helm chart or the MongoDB Community Operator |
| Image pin | Pin to a full semver tag: `mongo:7.0.15`; update intentionally via PR |
| Connection string | Update `MONGODB_URI` in backend ConfigMap to include the replica set name: `mongodb://user:pass@host1,host2,host3/db?replicaSet=rs0&authSource=db` |
| Backups | Deploy Percona Backup for MongoDB (pbm) or schedule `mongodump` CronJobs to object storage |
| Storage | Use a high-IOPS storage class; provision at least 3× current data size |
| PodDisruptionBudget | `mongodb/pdb.yaml` currently allows disruption to the single pod — update `maxUnavailable: 0` once HA is configured |

---

## 12. Security Policies

### 12a. Kyverno policies in audit mode

```yaml
# manifests/security/kyverno-policies.yaml
- name: require-resource-limits
  spec:
    validationFailureAction: Audit   # logs but does not block
```

`Audit` mode records violations without blocking deployments. For production,
`require-resource-limits`, `disallow-latest-tag`, `require-signed-images`,
and `require-readonly-rootfs` should all be `Enforce`.

### 12b. Image signing — `require-signed-images` in audit

```yaml
- name: require-signed-images
  spec:
    validationFailureAction: Audit
```

Images are signed by Cosign in the CI pipeline, but Kyverno does not enforce
the signature at admission. A manually pushed unsigned image would be
admitted without warning.

### 12c. Cosign key stored in Vault dev mode

The Cosign private key is generated by `security-init.sh` and stored in
Vault. Since Vault runs in dev mode (in-memory), the key is lost on every
Vault pod restart. Any restart between build and deploy breaks signature
verification.

### What must change

| Item | Required action |
|------|-----------------|
| Kyverno policy modes | Switch `require-resource-limits`, `disallow-latest-tag`, `require-signed-images`, `require-readonly-rootfs` to `Enforce` after verifying all workloads comply |
| Cosign key durability | Store Cosign private key in production Vault (persistent backend); or use keyless signing via Sigstore Fulcio/Rekor |
| Image signing scope | The `require-signed-images` Kyverno policy must specify the correct registry and key reference once the registry changes |
| Network policies | Verify `allow-ingress-to-frontend` correctly targets the production ingress controller namespace (may differ from `ingress-nginx`) |
| OPA conftest | Add conftest checks to the Tekton `lint-sast` task to validate environment overlay kustomizations, not just the base |

---

## 13. Port-Forwards & UIs

Every UI access path in the stack relies on `kubectl port-forward`:

```bash
# scripts/k8s/port-forward.sh
kubectl port-forward svc/argocd-server    -n argocd          8080:443  &
kubectl port-forward svc/tekton-dashboard -n tekton-pipelines 9097:9097 &
kubectl port-forward svc/prometheus-grafana -n monitoring     3001:80   &
kubectl port-forward svc/vault            -n vault            8200:8200 &
```

Port-forwarding is a developer convenience feature — it requires an
authenticated `kubectl` session, terminates on disconnect, and is not
suitable for team access or any automated tooling.

### What must change

| Service | Production approach |
|---------|---------------------|
| ArgoCD UI | Expose via Ingress with TLS and SSO (Dex + GitHub/LDAP) |
| Tekton Dashboard | Expose via Ingress with auth proxy (oauth2-proxy) or restrict to VPN |
| Grafana | Expose via Ingress with TLS; configure LDAP/OIDC login |
| Prometheus | Keep internal only; access via Grafana data source |
| Alertmanager | Keep internal only; configure receivers |
| Vault | Expose via Ingress with TLS if UI is needed; prefer CLI/API access via VPN |

Remove `port-forward.sh` from production runbooks entirely. It should only
be used by developers for local debugging.

---

## 14. Priority Order

Not all changes are equal. Work through them in this sequence:

### P0 — Must fix before any production traffic

1. **Vault** — switch from dev mode to persistent HA; remove root token default
2. **Placeholder secrets** — fail scripts if `JWT_SECRET`, `MONGO_*_PASSWORD` are unset
3. **Storage class** — replace `k8s.io/minikube-hostpath` and `standard-rwo`
4. **DNS / Ingress hosts** — replace `*.local` with real FQDNs + TLS
5. **MongoDB HA** — single replica is a single point of failure for all data
6. **Container registry** — move to private registry; remove Docker Hub personal account

### P1 — Must fix before production load

7. **Resource sizing** — right-size requests/limits and ResourceQuota after load testing
8. **CORS** — remove `localhost` from all staging and production `ALLOWED_ORIGINS`
9. **Kyverno enforcement** — switch audit policies to enforce once workloads comply
10. **Backup** — implement MongoDB backup and test restore procedure
11. **Retention** — extend Prometheus and Loki retention to meet compliance requirements

### P2 — Must fix before public launch

12. **ArgoCD TLS + SSO** — remove `--insecure`; integrate OIDC
13. **ArgoCD webhooks** — replace 30-minute polling with push-based sync
14. **Notification sink** — configure real alerting receivers (Slack, PagerDuty)
15. **SonarQube** — enforce quality gate by default
16. **JWT session policy** — define and implement refresh token / sliding session

### P3 — Operational hardening (ongoing)

17. **Image pinning** — full semver tags, no floating major versions
18. **OTel tracing** — add a tracing backend (Tempo or Jaeger)
19. **Cosign keyless** — migrate to Sigstore Fulcio for ephemeral key signing
20. **Multi-cluster** — register additional cluster destinations in ArgoCD AppProject
