# DSO202: Assignment 2: Unit II Concepts Applied to the Task Tracker

The same three-tier Task Tracker from Assignment 1 (no application code
changed), redeployed into its own namespace on the same shared `kind`
cluster, replacing every Unit I mechanism with its Unit II counterpart:
StatefulSets, Ingress, formal RBAC, and a hand-built Operator. See
[Assignment2_guide.md](Assignment2_guide.md) for the task list and rubric
this README is evidencing, and the [top-level README](../README.md) for how
this relates to Assignment 1.

| Concept (unit2.md) | Assignment 1 had | Assignment 2 has |
| --- | --- | --- |
| 2.1 Database workload | Deployment + hand-written PVC | **StatefulSet** + `volumeClaimTemplates` (`database/statefulset.yaml`) |
| 2.2 External access | frontend NodePort only | **Ingress** (ingress-nginx) fronting ClusterIP Services, 2 virtual hosts, TLS (`ingress/ingress.yaml`) |
| 2.3 RBAC | one optional bonus Role/RoleBinding | Role, ClusterRole, **aggregated** ClusterRole, and a Pod running under its own ServiceAccount (`rbac/rbac.yaml`) |
| 2.4 Operators | not covered | a **DbBackup** CRD + hand-built controller (`operator/`) |

---

## Repository layout

```
assignment-2/
├── Assignment2_guide.md        # this assignment's own brief + rubric (no official one was issued)
├── README.md
├── namespace.yaml               # dso202-assignment-02
├── configmap.yaml                # same DB_*/POSTGRES_* pattern as Assignment 1; BACKEND_URL now EMPTY (see below)
├── secret.yaml
├── quota.yaml
├── database/
│   ├── statefulset.yaml         # Task 1 (2.1)
│   └── service.yaml              # headless, required by the StatefulSet
├── backend/
│   ├── deployment.yaml           # + serviceAccountName: backend-sa (2.3.3.2)
│   └── service.yaml               # ClusterIP (Ingress fronts it now)
├── frontend/
│   ├── deployment.yaml
│   └── service.yaml               # changed from NodePort to ClusterIP
├── ingress/
│   └── ingress.yaml               # Task 2 (2.2): routing, TLS, 2 virtual hosts, annotations
├── rbac/
│   └── rbac.yaml                  # Task 3 (2.3): Role/RoleBinding, ClusterRole/Binding, aggregation, Pod SA
├── operator/                      # Task 4 (2.4): see "Operator tooling note" below
│   ├── go.mod / go.sum
│   ├── api/v1alpha1/dbbackup_types.go
│   ├── controllers/dbbackup_controller.go
│   ├── cmd/main.go
│   ├── Dockerfile
│   └── config/
│       ├── crd/dbbackups.yaml
│       ├── rbac/                  # (the operator's RBAC is in ../../rbac/rbac.yaml, part 5)
│       ├── manager/manager.yaml
│       └── samples/dbbackup-sample.yaml
├── scripts/
│   ├── deploy.sh                  # cluster -> images -> ingress-nginx -> manifests -> TLS -> wait
│   └── verify.sh                  # Task 1-4 evidence capture (writes evidence/)
└── evidence/
    └── assignment2-transcript.txt
```

`../images/`, `../kind-cluster.yaml` and `../docker-compose.yml` are shared
with Assignment 1 at the repo root (see the top-level README).

---

## How to deploy

Prerequisite: the shared cluster from the [top-level README](../README.md#deploying-both).

```bash
bash scripts/deploy.sh     # builds+loads images, installs ingress-nginx, applies everything, issues a TLS cert
bash scripts/verify.sh     # Task 1-4 evidence, writes evidence/assignment2-transcript.txt
```

Reach the app:

* **Ingress**: add `127.0.0.1  tasktracker.dso202.local status.dso202.local`
  to `/etc/hosts`, then <http://tasktracker.dso202.local:8080/> (or
  `https://...:8443`, self-signed cert). Ports are 8080/8443, not the standard
  80/443, because this host already runs Apache on 80 for unrelated
  coursework; see `../kind-cluster.yaml`'s header comment.
* Without editing `/etc/hosts`: `curl --resolve tasktracker.dso202.local:8443:127.0.0.1 https://tasktracker.dso202.local:8443/ -k` (exactly what `scripts/verify.sh` does).

Tear down: `kind delete cluster --name dso202` (removes Assignment 1 too, since they share one cluster).

---

## Task 1: StatefulSet database tier (2.1)

Assignment 1's database was a single-replica Deployment mounting a
hand-written PVC: enough for one replica, but it gives no *identity* since
every rollout can rename the Pod, and every replica would fight over one PVC
if scaled. `database/statefulset.yaml` replaces it with a StatefulSet:

* **Stable network identity (2.1.2.1).** The Pod is always `db-0` (not a
  `-xxxxx` random suffix), so it always answers to
  `db-0.db.dso202-assignment-02.svc.cluster.local`. Deleting it and letting
  the StatefulSet controller recreate it, evidenced in
  `evidence/assignment2-transcript.txt`, proves the name survives, which a
  Deployment's Pod name never does.
* **Ordered deployment/scaling (2.1.2.2).** `db-0` must reach Ready before
  `db-1` would be created, and scale-down removes the highest ordinal first.
  This assignment still runs 1 replica (a real multi-primary Postgres needs
  replication config outside this module's scope), so this property is
  adopted for the mechanism, not because 1 replica strictly needs it.
* **Headless Service (2.1.3).** `database/service.yaml` is unchanged in
  substance from Assignment 1: `clusterIP: None` is what a StatefulSet
  requires to publish one DNS record per Pod instead of one shared VIP.
* **volumeClaimTemplates (2.1.4).** No standalone `pvc.yaml`: the
  StatefulSet itself provisions `db-data-db-0`, one PVC per ordinal,
  automatically.

## Task 2: Ingress and Ingress Controller (2.2)

**Controller choice:** ingress-nginx (2.2.2.1), installed via its
kind-specific manifest (`scripts/deploy.sh`) rather than Traefik (2.2.2.2).
ingress-nginx is the reference implementation the Kubernetes docs use, has
first-party kind support, and its annotation surface
(`nginx.ingress.kubernetes.io/...`) is the most widely documented. Traefik's
main practical difference is configuring routes via its own CRDs
(IngressRoute) or annotations with a `traefik.ingress.kubernetes.io/...`
prefix instead of a single Ingress-shaped object, which is a real
alternative but not evaluated hands-on here.

`ingress/ingress.yaml` demonstrates every sub-topic in 2.2 against this app:

* **Basic routing rules (2.2.1.1).** One host, two paths: `/api` (Prefix) →
  `backend:8080`, `/` (Prefix) → `frontend:8080`.
* **TLS termination (2.2.1.2).** `scripts/deploy.sh` generates a self-signed
  cert/key with `openssl` and loads it as a `kubernetes.io/tls` Secret,
  **never committed to git**, referenced by the Ingress's `tls:` block.
* **Name-based virtual hosting (2.2.1.3).** A *second* host,
  `status.dso202.local`, routes straight to the backend Service: same
  Ingress, same controller IP/port, a completely different destination by
  hostname alone.
* **Controller-specific annotations (2.2.3).** `ssl-redirect: "false"` (so
  plain HTTP still works against a self-signed cert, for grading
  convenience) and `proxy-body-size: "5m"` (raises nginx's default 1m
  request-body cap), both ingress-nginx-specific keys that would not exist
  verbatim on another controller.

**This also fixes Assignment 1's "Known limitation".** `configmap.yaml` sets
`BACKEND_URL` to an **empty string**. `app.js` does
`const API = (BACKEND_URL || '') + '/api/tasks'`, so an empty value makes
every `fetch()` call a *relative* path. Once the Ingress puts the frontend
and the backend behind the same origin, that relative call resolves without
CORS or cluster-internal DNS ever being involved from the browser's
perspective: the real, production-shaped fix Assignment 1's README predicted
an Ingress would be.

## Task 3: RBAC (2.3)

`rbac/rbac.yaml` has five parts (`kubectl get role,clusterrole,rolebinding,clusterrolebinding -n dso202-assignment-02` after apply):

1. **`backend-sa`**: the backend Deployment's `serviceAccountName`
   (2.3.3.1, 2.3.3.2), with **no** Role/RoleBinding targeting it. Its Pod
   authenticates to the API server (it has a mounted, auto-rotated token)
   but is authorized for nothing.
2. **`viewer` + Role `namespace-readonly` + RoleBinding** (2.3.1.1, 2.3.2.1):
   the same read-only, namespace-scoped pattern as Assignment 1's bonus, now
   the graded implementation.
3. **ClusterRole `dso202-node-reader` + ClusterRoleBinding**: `viewer` is
   also bound, via a ClusterRoleBinding, to read Nodes, a genuinely
   cluster-scoped resource a namespaced Role could never grant.
4. **Aggregated ClusterRoles (2.3.1.2)**: `dso202-view-pods` and
   `dso202-view-quota` both carry the label
   `rbac.dso202.io/aggregate-to-monitoring: "true"`;
   `dso202-monitoring-aggregate` selects that label via `aggregationRule`
   and ships with `rules: []` of its own. After `kubectl apply`,
   `kubectl get clusterrole dso202-monitoring-aggregate -o yaml` shows
   `rules` populated automatically by the API server, proof the aggregation
   actually ran, not just that the YAML was accepted.
5. **`dbbackup-operator-sa` + Role + RoleBinding**: the Operator's own
   least-privilege identity (Task 4): only `dbbackups`/`dbbackups/status`
   and `batch/jobs`, nothing more.

**Proving allow/deny correctly (a real pitfall worth documenting).**
`evidence/assignment2-transcript.txt` extracts `backend-sa`'s and `viewer`'s
tokens from inside their Pods and calls the API server as each. The first
attempt at this used `kubectl --token=<token>` against the ambient admin
kubeconfig, and every call succeeded regardless of which token was passed,
because that kubeconfig *also* carries kind's admin **client certificate**,
and mutual-TLS client-cert authentication wins over a bearer token, so the
`--token` flag was silently ignored. The fix, and what the transcript
actually shows, is a **token-only kubeconfig per identity** (no client
cert), built the same way Assignment 1's bonus RBAC evidence already did it
(`evidence/bonus-rbac.txt`). With that fixed:

* `backend-sa` → `get pods`: **Forbidden** (no binding targets it).
* `viewer` → `get pods`: allowed (Role); `get nodes`: allowed (ClusterRole);
  `get resourcequota`: allowed (aggregated ClusterRole); `get secret
  task-tracker-secret`: **Forbidden** (Secrets are deliberately excluded from
  every Role/ClusterRole here).

## Task 4: DbBackup Operator (2.4)

**Tooling note (documentation requirement).** This environment has no
`operator-sdk`, no `kubebuilder`, and no `sudo` (so nothing installable via
`apt`). A Go toolchain was still obtainable: Go ships as a plain tarball that
installs into a user-writable directory with no root needed
(`~/.local/go`), so `operator/api/`, `operator/controllers/` and
`operator/cmd/main.go` are hand-written against
`sigs.k8s.io/controller-runtime`, the **same library** both scaffolding
tools generate code against; only the boilerplate a CLI would have typed out
(a `zz_generated.deepcopy.go`, the `main.go` wiring) is written by hand
instead of generated. The Operator pattern itself, a CRD, a controller
reconciling real cluster state to match it, status reported back onto the
custom resource, is implemented in full, not simulated.

**A real bug this surfaced, worth documenting.** The first version of the
manager used controller-runtime's default cache, which watches **all**
namespaces. The first time `Owns(&batchv1.Job{})` started its Job informer,
the API server rejected the cluster-scoped `LIST`/`WATCH` with `Forbidden`,
because `rbac/rbac.yaml`'s `dbbackup-operator` Role is deliberately
namespace-scoped (least privilege: this Operator has no business watching
Jobs anywhere else). The fix (`cmd/main.go`) reads the Operator's own
namespace from its projected ServiceAccount volume
(`/var/run/secrets/kubernetes.io/serviceaccount/namespace`) and passes
`cache.Options{DefaultNamespaces: {...}}` so the manager's cache is confined
to exactly the one namespace the Role actually grants, rather than loosening
the RBAC to match an unnecessarily broad cache.

**What it does.** `DbBackup` (`operator/config/crd/dbbackups.yaml`, group
`dso202.io/v1alpha1`) is a one-shot backup request. Creating one
(`operator/config/samples/dbbackup-sample.yaml`) is the only trigger the
Operator watches for:

1. `DbBackupReconciler.Reconcile` (`operator/controllers/dbbackup_controller.go`)
   sees a `DbBackup` with no `.status.jobName` and creates a `Job` that runs
   `pg_dump` against `spec.targetService` (default `db`), authenticating
   with the **same** `task-tracker-secret`/`task-tracker-config` keys the
   backend Deployment already uses: no duplicated credentials.
2. It sets `.status.phase = Running` and records the Job's name.
3. `Owns(&batchv1.Job{})` means the Job's own status change re-triggers
   `Reconcile` (event-driven, not just polled); once the Job reports
   `Succeeded` or `Failed`, that becomes `.status.phase`, with
   `.status.message` pointing at `kubectl logs job/<name>` for detail.

`evidence/assignment2-transcript.txt` shows a full run: apply the sample,
watch `.status.phase` go `Pending → Running → Succeeded` in about 3 seconds,
and the Job's log line `BACKUP_OK: 102 lines dumped from db`.

---

## Evidence

Full command transcript for all four tasks:
**`evidence/assignment2-transcript.txt`** (produced by `scripts/verify.sh`
against a live deployment on the `dso202` kind cluster).

---

## Constraints checklist

* [x] App image tags still pinned at `:1.0`; no `latest`.
* [x] No credential in plaintext in any committed manifest; the Ingress TLS
      key is generated at deploy time and never committed.
* [x] `tier`/`app` labels carried over onto every workload and Service.
* [x] The database is still never reachable outside the cluster; only the
      frontend and the backend's `/api` path are reachable, and only via the
      Ingress Controller, not a NodePort/LoadBalancer Service.
* [x] All resources scoped to `dso202-assignment-02`, separate from
      Assignment 1's namespace.
* [x] All manifests, CRD, and operator source are version-controlled.
