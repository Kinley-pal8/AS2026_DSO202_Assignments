# DSO202 — Assignment 1: Three-Tier Application Deployment on Kubernetes Cluster

**Module:** DSO202 — Scaling, Orchestration, Monitoring & Observability
**Scope:** Unit I only
**Weighting:** 10 marks (of the module's four assignments, each 10 marks)

---

## 1. Overview

A pre-built three-tier application — frontend, backend, and database — must be deployed to the local `kind` cluster established in Practical 1. All three container images are provided; no application code is written for this assignment. The graded effort is entirely the Kubernetes configuration: how the three tiers are connected, configured, secured, governed, and verified, using only Unit I content applied in a standard, industry-representative way.

The application is a minimal Task Tracker exposing create, read, update, and delete operations on a `task` resource.

---

## 2. Learning Outcomes Addressed

| LO | Outcome | Where addressed |
| --- | --- | --- |
| 1 | Core concepts and architecture of Kubernetes | Task 1 (architecture note) |
| 2 | Deploy and manage applications using various resource types | Tasks 3–5 (Deployments, Services, ConfigMap, Secret, PVC) |
| 3 | Operate `kubectl` for cluster management and troubleshooting | Task 7 |
| 4 | Implement persistent storage using Volumes | Task 3 (database PVC) |
| 5 | Apply namespace-based multi-tenancy (partial — the etcd service-registry half of this outcome belongs to Unit III) | Tasks 1 and 6 |

---

## 3. Provided Materials

Image names, tags, and the full configuration contract are provided below. Students must **not** substitute their own images or a `latest` tag for any tier.

| Tier | Provided as | Internal port |
| --- | --- | --- |
| Frontend | `sarojsanyasi/dso202-frontend` | 8080 |
| Backend | `sarojsanyasi/dso202-backend` | 8080 |
| Database | `sarojsanyasi/dso202-db` | 5432 |

**Backend API:** `GET /api/tasks`, `GET /api/tasks/{id}`, `POST /api/tasks`, `PUT /api/tasks/{id}`, `DELETE /api/tasks/{id}`, `GET /api/status`.

**Important — variable naming mismatch:** the backend expects `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`. The database image expects the official PostgreSQL image's own variables: `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`. Both sets must be supplied with matching values — copying only one set will leave the other tier misconfigured.

---

## 4. Prerequisite

The `kind` cluster from Practical 1 must be running. If the frontend's `NodePort` Service is to be reached directly from a browser, the cluster must have been created with an `extraPortMappings` entry covering the chosen NodePort; otherwise, `kubectl port-forward` must be used to reach the frontend for demonstration purposes. This should be confirmed before starting Task 5.

---

## 5. Tasks

### Task 1 — Namespace and Architecture Note *(maps 1.1, 1.5.1)*

- A dedicated namespace: `dso202-assignment-01` must be created for this assignment.
- A short written note (half a page) must describe, before any manifest is written, which control-plane and node components will be involved in scheduling and running each of the three Pods, and which Kubernetes objects will be used for each tier and why.

### Task 2 — Configuration and Secrets *(1.2.5)*

- A ConfigMap must hold all non-sensitive values (`DB_HOST`, `DB_PORT`, `DB_NAME`, `APP_PORT`, `CORS_ORIGIN`, `POSTGRES_DB`, `BACKEND_URL`).
- A Secret must hold all credential values (`DB_USER`, `DB_PASSWORD`, `POSTGRES_USER`, `POSTGRES_PASSWORD`).
- The README must note explicitly that Kubernetes Secrets are base64-encoded, not encrypted at rest by default — this is a documentation requirement, not something to be "fixed" within this assignment's scope.

### Task 3 — Database Tier *(1.2.1–1.2.4, 1.4)*

- A PersistentVolumeClaim must be created using `kind`'s default storage provisioner.
- A single-replica Deployment must mount the PVC at the database's data path and consume the correct ConfigMap/Secret keys (`POSTGRES_*`, not `DB_*`).
- A **headless Service** (`clusterIP: None`) must expose the database within the namespace only.

### Task 4 — Backend Tier *(1.2.1–1.2.4)*

- A Deployment must consume its own ConfigMap/Secret keys (`DB_*`), with `DB_HOST` set to the database Service's name.
- A **ClusterIP** Service must expose the backend within the namespace only — it must never be reachable from outside the cluster.

### Task 5 — Frontend Tier *(1.2.1–1.2.4)*

- A Deployment must consume `BACKEND_URL`, set to the backend Service's cluster-internal address.
- A **NodePort** Service must expose the frontend, using the port mapped in the `kind` cluster configuration (see Section 4).

### Task 6 — Namespace Resource Governance *(1.5.3)*

- A ResourceQuota and a LimitRange must be applied to the namespace, bounding all three Deployments.
- Chosen values must be justified in the README — arbitrary or copied values without reasoning will not satisfy this requirement.

### Task 7 — Verification and Interactivity *(1.3)*

The following must be demonstrated and evidenced (terminal transcript or screenshot) in the submission:

a. **Full CRUD cycle** — a task created, listed, updated, and deleted through the frontend or via `curl` through a port-forwarded backend.

b. **Service DNS resolution** — from inside the frontend Pod (`kubectl exec`), the backend Service must be reached by name via `curl`, demonstrating that cluster DNS resolves the Service correctly.

c. **Self-healing and data persistence** — the backend Pod must be deleted manually; the ReplicaSet's recreation of it must be observed via `kubectl get pods --watch`; and a task created before the deletion must still be retrievable afterward, demonstrating that Pod lifecycle and PersistentVolume lifecycle are independent.

d. **Declarative vs. imperative comparison** — at least one resource from this assignment must be created both declaratively (`kubectl apply -f`) and, separately, via the equivalent imperative `kubectl` command, with a short written comparison of the two approaches.

### Task 8 — Bonus (Optional) — Namespace RBAC *(1.5.2)*

A minimal Role and RoleBinding scoping a read-only ServiceAccount to the namespace may optionally be added for bonus credit. This is optional because the full mechanics of Roles and RoleBindings are formally taught in Unit II; a template outline will be provided separately on request.

---

## 6. Non-Negotiable Constraints

- No image tag other than the one issued at 3. by the module tutor may be used; `latest` may not be used for any tier.
- No credential may appear in plaintext in any manifest committed to version control — credentials belong in the Secret only.
- Every Pod, Deployment, and Service must carry a `tier` label (`frontend`, `backend`, or `database`).
- The backend and database must never be exposed via NodePort or LoadBalancer.
- All manifests must be submitted as version-controlled YAML files, consistent with the practical work submission process (Assessment Component A).

---

## 7. Submission Requirements

Suggested repository structure:

```
assignment-1/
├── namespace.yaml
├── configmap.yaml
├── secret.yaml
├── quota.yaml
├── database/
│ ├── pvc.yaml
│ ├── deployment.yaml
│ └── service.yaml
├── backend/
│ ├── deployment.yaml
│ └── service.yaml
├── frontend/
│ ├── deployment.yaml
│ └── service.yaml
└── README.md
```

`README.md` must include: the architecture note (Task 1), the ResourceQuota/LimitRange justification (Task 6), the Secret encoding caveat (Task 2), and the evidence for Task 7 (a–d).

---

## 8. Marking Rubric

| Criterion | Marks | Evidence expected |
| --- | --- | --- |
| Code Organisation & Readability | 1 | Manifests logically split by tier; consistent naming and labelling |
| Comments & Documentation | 1 | README covers all required notes (Tasks 1, 2, 6) clearly |
| Configuration Requirements | 2 | Correct ConfigMap/Secret separation; correct `DB_*` / `POSTGRES_*` key mapping; justified quota values |
| Configuration Implementation | 5 | All Deployments, Services (including the headless and ClusterIP Services), PVC, and namespace function correctly; Task 7 evidence complete |
| Deployment & Configuration | 1 | Declarative/imperative comparison completed correctly (Task 7d) |
| **Total** | **10** | |

---

## 9. Troubleshooting Guide

| Symptom | Likely cause |
| --- | --- |
| `ImagePullBackOff` | Incorrect image name or tag; or, if many students share a network, the anonymous Docker Hub pull-rate limit may have been reached — try `docker login` before pulling |
| Backend `CrashLoopBackOff` | Environment variable name mismatch (check `DB_*` vs `POSTGRES_*`); confirm the ConfigMap/Secret are actually referenced in the Deployment spec |
| Frontend cannot reach backend | `BACKEND_URL` value does not match the backend Service's name or namespace |
| Backend cannot reach database | `DB_HOST` value does not match the database Service's name; confirm the headless Service was created correctly |
| NodePort unreachable from a browser | `kind` cluster was not created with the matching `extraPortMappings`; use `kubectl port-forward` as a fallback |
| PVC stuck in `Pending` | Confirm `kind`'s default StorageClass is present (`kubectl get storageclass`) |

---

## 10. Submission Checklist

- [ ] Namespace created and all resources scoped to it
- [ ] ConfigMap and Secret created with correct, matching key values across both naming conventions
- [ ] Database Deployment mounts PVC and uses a headless Service
- [ ] Backend Deployment uses a ClusterIP Service and correct environment variables
- [ ] Frontend Deployment uses a NodePort Service and correct `BACKEND_URL`
- [ ] ResourceQuota and LimitRange applied and justified
- [ ] Full CRUD cycle demonstrated and evidenced
- [ ] Service DNS resolution demonstrated from inside a Pod
- [ ] Pod self-healing and data persistence demonstrated
- [ ] One resource created both declaratively and imperatively, with written comparison
- [ ] README complete with all required notes
- [ ] All manifests committed to the designated version-control repository