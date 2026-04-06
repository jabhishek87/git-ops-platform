# NovaDeploy — GitOps Deployment Platform

A GitOps deployment platform for NovaDeploy's microservices, built on ArgoCD + Kind. Designed to make deployment failures structurally impossible through enforced ordering, secret isolation, admission control, and platform observability.

## Quick Start

### Prerequisites

- Docker
- [kind](https://kind.sigs.k8s.io/) ≥ 0.20
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/) ≥ 3.12

### Bootstrap

```bash
make up
```

This single command:
1. Creates a Kind cluster (`novadeploy`)
2. Installs ArgoCD via Helm
3. Applies the App-of-Apps, which reconciles the entire platform

Idempotent — safe to run again if the cluster already exists.

### Access ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
# Username: admin
# Password: (printed by bootstrap, or run below)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### Check Status

```bash
make status
# or
kubectl get applications -n argocd
```

### Tear Down

```bash
make down
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Kind Cluster (novadeploy)                    │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    ArgoCD (bootstrap)                         │   │
│  │  App-of-Apps (platform) ──► sync waves enforce ordering      │   │
│  └──────────┬───────────────────────────────────────────────────┘   │
│             │                                                       │
│  Wave 0     ├──► Namespaces & RBAC (ServiceAccounts)               │
│  Wave 1     ├──► cert-manager (TLS automation + CRDs)              │
│  Wave 2     ├──► External Secrets Operator (secret sync + CRDs)    │
│  Wave 2     ├──► Kyverno (policy engine + CRDs)                    │
│  Wave 2     ├──► Monitoring (Prometheus, Grafana, Alertmanager)    │
│  Wave 3     ├──► Vault (dev-mode secret backend)                   │
│  Wave 3     ├──► Kyverno Policies (admission rules)                │
│  Wave 4     ├──► Secrets (SecretStore + ExternalSecrets)           │
│  Wave 5     ├──► PostgreSQL + Redis (data layer)                   │
│  Wave 6     ├──► API Service + Background Worker                   │
│  Wave 7     └──► Platform Observability (dashboards, alerts)       │
│                                                                     │
│  ┌────────────────────────────────────────────────────────────┐     │
│  │ Custom Health Checks (ArgoCD CM)                           │     │
│  │  • Application  → propagates child app health              │     │
│  │  • ExternalSecret → Ready condition                        │     │
│  │  • Certificate  → Ready condition                          │     │
│  └────────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────┘
```

### Repository Structure

```
git-ops-platform/
├── bootstrap/              # Kind config, ArgoCD Helm values, bootstrap.sh
├── platform/
│   ├── app-of-apps.yaml    # Root Application (points to platform/apps/)
│   ├── applicationset.yaml # Per-environment app generation
│   └── apps/               # One Application manifest per component (sync-wave ordered)
├── components/             # Kustomize bases + overlays per component
│   ├── namespaces/base/
│   ├── vault/base/
│   ├── database/{base,overlays/{dev,staging,prod}}/
│   ├── redis/{base,overlays/{dev,staging,prod}}/
│   ├── api-service/{base,overlays/{dev,staging,prod}}/
│   ├── worker/{base,overlays/{dev,staging,prod}}/
│   └── observability/      # ServiceMonitors, PrometheusRules, Grafana dashboards
├── policies/               # Kyverno ClusterPolicies
├── secrets/                # SecretStore + ExternalSecret definitions
├── ci/                     # validate.sh (YAML lint, kubeconform, secret scan)
└── .github/workflows/      # GitHub Actions CI pipeline
```

---

## Deployment Safety Strategy

### How Sync Waves Work

The platform uses ArgoCD's **sync wave** mechanism within an App-of-Apps pattern. Each Application manifest in `platform/apps/` has an `argocd.argoproj.io/sync-wave` annotation. ArgoCD processes waves sequentially — a wave only begins after all resources in the previous wave are **synced and healthy**.

Health is determined by custom Lua health checks configured in ArgoCD's ConfigMap:
- **Application**: healthy only when the child app reports healthy
- **ExternalSecret**: healthy only when `status.conditions[Ready]=True` (secret actually synced from Vault)
- **Certificate**: healthy only when `status.conditions[Ready]=True`

This means wave 5 (database, redis) cannot start until wave 4 (secrets) reports all ExternalSecrets as synced — which requires wave 3 (Vault) to be running and seeded.

### How This Prevents Each Incident

**Incident #1 — Secret not ready (45-min outage)**
- ExternalSecrets are in wave 4. Database and API service are in waves 5-6.
- The custom ExternalSecret health check blocks downstream waves until secrets are actually synced from Vault.
- Additionally, the API service and worker deployments reference secrets via `secretKeyRef` — Kubernetes itself will refuse to schedule the pod if the Secret doesn't exist.
- Result: structurally impossible. The app cannot deploy before its secrets are ready.

**Incident #2 — CRD race condition (30-min error loop)**
- Operators that install CRDs (cert-manager, ESO, Kyverno, monitoring) are in waves 1-2.
- Resources that consume those CRDs (Kyverno policies, ExternalSecrets, ServiceMonitors) are in waves 3-7.
- ArgoCD waits for the operator's Application to be healthy (all pods running, CRDs registered) before proceeding to the next wave.
- Result: structurally impossible. CRD consumers never deploy before CRD providers.

**Incident #3 — Phantom kubectl edit (discovered 2 weeks late)**
- ArgoCD's `selfHeal: true` on all applications continuously reconciles desired state from Git.
- Any manual `kubectl edit` is detected as drift and reverted automatically.
- The monitoring stack fires `ArgoCDAppOutOfSync` alert if an app stays out of sync for >15 minutes.
- Result: drift is auto-corrected within the reconciliation interval (5 minutes). Alerts ensure visibility.

**Incident #4 — Shared secret blast radius (3-service impact)**
- Each service has its own ExternalSecret pulling its own path from Vault:
  - `api-service-db-credentials` ← `secret/dev/api-service/db`
  - `worker-db-credentials` ← `secret/dev/worker/db`
  - `api-service-redis-credentials` ← `secret/dev/api-service/redis`
  - `worker-redis-credentials` ← `secret/dev/worker/redis`
- Credential rotation for one service does not affect others.
- ESO refreshes secrets every 1 minute (`refreshInterval: 1m`), so rotation propagates without pod restarts.
- Result: blast radius is limited to a single service.

---

## Multi-Environment Design

### Shared Baseline, Intentional Differences

All components use Kustomize with a shared `base/` and per-environment `overlays/{dev,staging,prod}/`. The base contains the deployment, service, and security context. Overlays customize:

| Aspect | Dev | Staging | Prod |
|--------|-----|---------|------|
| Replicas | 1 | 1 | 2+ |
| Resource limits | Minimal | Moderate | Production-grade |
| ArgoCD sync | Auto + prune | Auto, no prune | Manual sync only |
| Secret path | `secret/dev/...` | `secret/staging/...` | `secret/prod/...` |

### Environment Sync Policies

Defined in `platform/applicationset.yaml` using a matrix generator:
- **Dev**: `automated: true, prune: true, selfHeal: true` — fast iteration, auto-cleanup
- **Staging**: `automated: true, prune: false, selfHeal: true` — auto-sync but no accidental resource deletion
- **Prod**: `automated: false` — requires explicit manual sync or approval, preventing accidental production changes

### Promotion Strategy

1. Merge change to `main` — dev auto-syncs immediately
2. Verify in dev via ArgoCD dashboard / `kubectl get applications`
3. Staging auto-syncs (same branch) — verify behavior with staging resource profile
4. For prod: manually trigger sync in ArgoCD UI or CLI after validation

### Drift Prevention

- `selfHeal: true` on all environments reverts manual changes
- Prod's manual sync means changes only apply when explicitly triggered
- ArgoCD alerts fire on OutOfSync state lasting >15 minutes

---

## Secrets Management

### Architecture

```
Vault (dev-mode)  ──►  External Secrets Operator  ──►  K8s Secrets  ──►  Pods
  (wave 3)                  (wave 2)                    (wave 4)        (wave 5-6)
```

- **Vault** runs in dev mode with a well-known root token (local-only, no cloud dependency)
- **Vault seed job** (PostSync hook) populates per-service, per-environment credentials
- **SecretStore** in `novadeploy` namespace connects ESO to Vault
- **ExternalSecrets** pull individual secret paths into dedicated K8s Secrets
- **Zero secrets in Git** — only secret references (paths, key names) are stored

### Secret Rotation

ESO polls Vault every 60 seconds (`refreshInterval: 1m`). To rotate:
1. Update the secret value in Vault
2. ESO picks up the new value on next refresh cycle
3. Pods using `envFrom` or `secretKeyRef` pick up changes on next restart, or immediately if using mounted volumes (kubelet syncs within ~1 minute)

### Trade-off: Dev-mode Vault Token

The `vault-token` Secret in `secrets/secret-store.yaml` contains the dev-mode root token (`root`). This is acceptable for a local Kind cluster but would be replaced with Vault's Kubernetes auth method in production.

---

## Standards Enforcement

### Kyverno Policies

Four ClusterPolicies enforce deployment standards:

| Policy | What It Blocks |
|--------|---------------|
| `disallow-privileged` | Containers with `privileged: true` or `allowPrivilegeEscalation: true`, pods not setting `runAsNonRoot: true` |
| `disallow-latest-tag` | Images with no tag or `:latest` |
| `require-resource-limits` | Pods missing `resources.requests` or `resources.limits` |
| `disallow-host-namespaces` | Pods using `hostNetwork`, `hostPID`, or `hostIPC` |

### Rollout Strategy

Policies deploy in **Audit mode** (`validationFailureAction: Audit`). This means:
1. Violations are logged and visible in policy reports, but pods are not rejected
2. Teams can review violations via `kubectl get policyreport -A`
3. Once existing workloads are compliant, switch to `Enforce` mode

This prevents the common problem of deploying a new policy that immediately breaks running workloads. System namespaces (kube-system, argocd, kyverno, cert-manager, external-secrets, monitoring, vault) are excluded to avoid blocking infrastructure components.

### CI-Level Enforcement

The CI pipeline (`ci/validate.sh` + GitHub Actions) catches issues before merge:
- YAML syntax validation (yamllint)
- Kubernetes schema validation (kubeconform) — catches deprecated APIs and malformed manifests
- Kyverno offline policy testing — applies policies against manifests without a cluster
- Secret detection — scans diffs for accidentally committed credentials

---

## Observability

### What's Deployed

- **Prometheus** — scrapes ArgoCD metrics, node metrics, kube-state-metrics
- **Grafana** — ArgoCD platform health dashboard (sync status, health, reconciliation times)
- **Alertmanager** — routes alerts from PrometheusRules
- **ServiceMonitors** — scrape ArgoCD server and application controller metrics
- **PrometheusRules** — four platform alerts:

| Alert | Condition | Severity |
|-------|-----------|----------|
| `ArgoCDAppOutOfSync` | App out of sync >15 min | Warning |
| `ArgoCDAppDegraded` | App health degraded >5 min | Critical |
| `ArgoCDSyncFailed` | Sync failure in last 10 min | Critical |
| `ArgoCDAppStuck` | App progressing >30 min | Warning |

### Answering Key Questions

- **Is the platform healthy?** → ArgoCD dashboard shows all apps Synced/Healthy. Grafana dashboard shows aggregate status.
- **Are deployments failing?** → `ArgoCDSyncFailed` alert fires. ArgoCD UI shows failed sync with error details.
- **Has anything drifted?** → `ArgoCDAppOutOfSync` alert fires. `selfHeal: true` auto-corrects drift, but the alert provides visibility.
- **What changed in the last hour?** → ArgoCD UI shows sync history with timestamps, revisions, and diffs.
- **"Not yet deployed" vs "deployment failed"** → ArgoCD distinguishes `Missing` (not yet synced) from `Degraded` (synced but unhealthy). Custom health checks ensure accurate status.
- **"Stuck" vs "slow"** → `ArgoCDAppStuck` fires after 30 minutes of `Progressing` state, distinguishing genuinely stuck deployments from slow-but-progressing ones.

---

## Incident Runbook: Deployment Stuck in Progressing

### Symptoms
- ArgoCD app shows `Health: Progressing` for >10 minutes
- `ArgoCDAppStuck` alert fires (after 30 min)

### Diagnosis Steps

```bash
# 1. Identify which app is stuck
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

# 2. Check the app's resources for unhealthy components
kubectl get application <app-name> -n argocd -o jsonpath='{range .status.resources[*]}{.kind}/{.name}: health={.health.status}{"\n"}{end}'

# 3. Check pod status in the target namespace
kubectl get pods -n <namespace> -o wide
kubectl describe pod <pod-name> -n <namespace>

# 4. Check events for scheduling/image pull issues
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20

# 5. For sync wave issues, check the platform app's operation state
kubectl get application platform -n argocd -o jsonpath='{.status.operationState.message}'
```

### Likely Root Causes

| Cause | Indicator | Fix |
|-------|-----------|-----|
| Image pull failure | `ImagePullBackOff` in pod status | Fix image reference, check registry access |
| Secret not found | `CreateContainerConfigError` | Check ExternalSecret status: `kubectl get externalsecrets -n novadeploy` |
| Resource quota exceeded | `Pending` pod, events show quota | Increase node resources or reduce requests |
| Readiness probe failing | Pod running but 0/1 Ready | Check probe config, application logs |
| Sync wave timeout | Platform app retries exhausted | Trigger manual sync: `kubectl annotate application platform -n argocd argocd.argoproj.io/refresh=hard --overwrite` |

### Recovery

```bash
# Force re-sync of a specific app
kubectl annotate application <app-name> -n argocd argocd.argoproj.io/refresh=hard --overwrite

# Force re-sync of entire platform
kubectl annotate application platform -n argocd argocd.argoproj.io/refresh=hard --overwrite

# If a pod is stuck in CrashLoopBackOff, check logs
kubectl logs <pod-name> -n <namespace> --previous
```

---

## Scaling Considerations

### Current: Single Local Cluster

The current design runs everything on one Kind cluster. This is appropriate for development and demonstration.

### Scaling to 10 Clusters / 3 Regions

| Aspect | Current | At Scale |
|--------|---------|----------|
| **Cluster management** | Single Kind cluster | ArgoCD ApplicationSets with cluster generators, one management cluster running ArgoCD targeting remote clusters |
| **Git structure** | Single repo, overlays per env | Same repo, add cluster-level overlays (`overlays/{region}/{cluster}/`) |
| **Secrets** | Dev-mode Vault, root token | Production Vault cluster (HA) per region, Kubernetes auth method, no static tokens |
| **Policy enforcement** | Kyverno per cluster | Kyverno on each cluster, policies synced from Git. Consider OPA Gatekeeper for cross-cluster policy aggregation |
| **Monitoring** | Single Prometheus | Thanos or Cortex for cross-cluster metric aggregation. Per-cluster Prometheus with remote-write to central store |
| **Bootstrap** | `make up` creates everything | Terraform/Pulumi for cloud infrastructure, ArgoCD bootstrapped via cluster provisioning pipeline |
| **Promotion** | Single branch, manual prod sync | Branch-per-environment or PR-based promotion with automated testing gates |

### Key Changes Needed

1. **ArgoCD multi-cluster**: Register remote clusters as ArgoCD destinations. ApplicationSets generate apps per cluster using cluster generators.
2. **Vault production mode**: HA Vault with auto-unseal, Kubernetes auth per cluster, audit logging.
3. **Federated monitoring**: Each cluster runs Prometheus + remote-write to a central Thanos/Cortex. Grafana queries the central store.
4. **Network**: Cross-region connectivity for ArgoCD → remote clusters. Consider running ArgoCD per region to reduce latency.
5. **RBAC**: ArgoCD AppProjects per team, restricting which namespaces and clusters each team can deploy to.

---

## Validation

### Run Locally

```bash
make validate
```

Runs: YAML lint, kubeconform schema validation, secret detection scan.

### CI Pipeline

GitHub Actions runs on every push/PR to `main`:
1. YAML syntax check (yamllint)
2. Kubernetes manifest validation (kubeconform)
3. Kyverno offline policy test against workload manifests
4. Secret detection in diffs

---

## Design Decisions & Trade-offs

| Decision | Rationale | Trade-off |
|----------|-----------|-----------|
| App-of-Apps over ApplicationSets for ordering | Sync waves within a single parent app give deterministic ordering. ApplicationSets don't support inter-app dependency ordering. | More YAML files in `platform/apps/`, but explicit and auditable. |
| Kustomize over Helm for app manifests | Simpler to review in PRs, no template rendering surprises. Helm used only for third-party charts. | Less dynamic than Helm, but more transparent. |
| Audit mode for Kyverno policies | Safe rollout — doesn't break existing workloads. Switch to Enforce after compliance review. | Violations are logged but not blocked until switched to Enforce. |
| Dev-mode Vault with root token | Zero external dependencies, works offline, instant bootstrap. | Not production-representative. Would use Kubernetes auth + HA Vault in production. |
| selfHeal on all environments | Prevents drift (Incident #3). Prod uses manual sync to prevent unintended changes, but selfHeal reverts manual kubectl edits. | Legitimate emergency `kubectl edit` changes get reverted. Requires committing to Git for persistent changes. |
| Init containers for runtime dependency checks | Defense-in-depth — even if sync waves ensure ordering, init containers verify actual connectivity. | Adds startup latency (~2-5 seconds per check). |

---

## AI Tools Used

AI assistance (Amazon Q) was used for:
- Generating this README documentation
- Debugging sync wave ordering issues during development

All architecture decisions, manifest authoring, and platform design were done manually.
