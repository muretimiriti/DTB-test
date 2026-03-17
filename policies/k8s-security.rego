package main

# =============================================================================
# k8s-security.rego — OPA policies for Kubernetes manifest validation
#
# Run with conftest before applying manifests:
#   conftest test manifests/k8s/backend/deployment.yaml --policy policies/
#   conftest test manifests/k8s/ --policy policies/ --all-namespaces
#
# Also executed in the Tekton lint-sast task on every pipeline run.
# =============================================================================

# ── DENY: containers without CPU limits ──────────────────────────────────────
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits.cpu
  msg := sprintf(
    "DENY [resource-limits] Container '%v' in Deployment '%v' must set resources.limits.cpu",
    [container.name, input.metadata.name]
  )
}

# ── DENY: containers without memory limits ───────────────────────────────────
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits.memory
  msg := sprintf(
    "DENY [resource-limits] Container '%v' in Deployment '%v' must set resources.limits.memory",
    [container.name, input.metadata.name]
  )
}

# ── DENY: privileged containers ──────────────────────────────────────────────
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  container.securityContext.privileged == true
  msg := sprintf(
    "DENY [no-privileged] Container '%v' in Deployment '%v' must not run as privileged",
    [container.name, input.metadata.name]
  )
}

# ── DENY: allowPrivilegeEscalation not explicitly false ──────────────────────
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  container.securityContext.allowPrivilegeEscalation != false
  msg := sprintf(
    "DENY [no-priv-escalation] Container '%v' in Deployment '%v' must set allowPrivilegeEscalation: false",
    [container.name, input.metadata.name]
  )
}

# ── DENY: missing namespace on Deployment/StatefulSet/Service ────────────────
deny[msg] {
  input.kind == "Deployment"
  not input.metadata.namespace
  msg := sprintf(
    "DENY [require-namespace] Deployment '%v' must specify metadata.namespace",
    [input.metadata.name]
  )
}

deny[msg] {
  input.kind == "StatefulSet"
  not input.metadata.namespace
  msg := sprintf(
    "DENY [require-namespace] StatefulSet '%v' must specify metadata.namespace",
    [input.metadata.name]
  )
}

# ── DENY: Service without selector (headless allowed — ClusterIP: None) ──────
deny[msg] {
  input.kind == "Service"
  input.spec.type != "ExternalName"
  not input.spec.clusterIP == "None"
  not input.spec.selector
  msg := sprintf(
    "DENY [service-selector] Service '%v' must have a selector",
    [input.metadata.name]
  )
}

# ── WARN: missing readinessProbe ─────────────────────────────────────────────
warn[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.readinessProbe
  msg := sprintf(
    "WARN [readiness-probe] Container '%v' in Deployment '%v' should have a readinessProbe",
    [container.name, input.metadata.name]
  )
}

# ── WARN: missing livenessProbe ──────────────────────────────────────────────
warn[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.livenessProbe
  msg := sprintf(
    "WARN [liveness-probe] Container '%v' in Deployment '%v' should have a livenessProbe",
    [container.name, input.metadata.name]
  )
}

# ── WARN: single replica (no HA) ─────────────────────────────────────────────
warn[msg] {
  input.kind == "Deployment"
  input.spec.replicas == 1
  msg := sprintf(
    "WARN [single-replica] Deployment '%v' has only 1 replica — consider 2+ for HA",
    [input.metadata.name]
  )
}

# ── WARN: missing app.kubernetes.io/part-of label ────────────────────────────
warn[msg] {
  input.kind == "Deployment"
  not input.metadata.labels["app.kubernetes.io/part-of"]
  msg := sprintf(
    "WARN [missing-label] Deployment '%v' is missing label app.kubernetes.io/part-of",
    [input.metadata.name]
  )
}
