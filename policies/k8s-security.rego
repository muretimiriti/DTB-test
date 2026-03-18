package main

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits.cpu
  msg := sprintf(
    "DENY [resource-limits] Container '%v' in Deployment '%v' must set resources.limits.cpu",
    [container.name, input.metadata.name]
  )
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits.memory
  msg := sprintf(
    "DENY [resource-limits] Container '%v' in Deployment '%v' must set resources.limits.memory",
    [container.name, input.metadata.name]
  )
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  container.securityContext.privileged == true
  msg := sprintf(
    "DENY [no-privileged] Container '%v' in Deployment '%v' must not run as privileged",
    [container.name, input.metadata.name]
  )
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  container.securityContext.allowPrivilegeEscalation != false
  msg := sprintf(
    "DENY [no-priv-escalation] Container '%v' in Deployment '%v' must set allowPrivilegeEscalation: false",
    [container.name, input.metadata.name]
  )
}

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

warn[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.readinessProbe
  msg := sprintf(
    "WARN [readiness-probe] Container '%v' in Deployment '%v' should have a readinessProbe",
    [container.name, input.metadata.name]
  )
}

warn[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.livenessProbe
  msg := sprintf(
    "WARN [liveness-probe] Container '%v' in Deployment '%v' should have a livenessProbe",
    [container.name, input.metadata.name]
  )
}

warn[msg] {
  input.kind == "Deployment"
  input.spec.replicas == 1
  msg := sprintf(
    "WARN [single-replica] Deployment '%v' has only 1 replica — consider 2+ for HA",
    [input.metadata.name]
  )
}

warn[msg] {
  input.kind == "Deployment"
  not input.metadata.labels["app.kubernetes.io/part-of"]
  msg := sprintf(
    "WARN [missing-label] Deployment '%v' is missing label app.kubernetes.io/part-of",
    [input.metadata.name]
  )
}
