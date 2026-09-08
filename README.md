# DSO202: Assignment 1: Three-Tier Task Tracker on Kubernetes

Frontend + backend + PostgreSQL, deployed to the local **kind** cluster from
Practical 1, in a dedicated namespace, governed by a ResourceQuota / LimitRange.
No application code was written; the assignment is entirely the Kubernetes
configuration.

| Tier | Image | Workload | Service |
| --- | --- | --- | --- |
| frontend | `sarojsanyasi/dso202-frontend:1.0` | Deployment (1) | **NodePort** 30080 |
| backend  | `sarojsanyasi/dso202-backend:1.0`  | Deployment (1) | **ClusterIP** 8080 |
| database | `sarojsanyasi/dso202-db:1.0`       | Deployment (1) + PVC | **headless** (`clusterIP: None`) 5432 |

---

## Repository layout

```
.
├── namespace.yaml              # Task 1
├── configmap.yaml              # Task 2 – non-sensitive config (DB_* and POSTGRES_*)
├── secret.yaml                 # Task 2 – credentials only, base64
├── quota.yaml                  # Task 6 – ResourceQuota + LimitRange
├── database/
│   ├── pvc.yaml                # Task 3
│   ├── deployment.yaml
│   └── service.yaml
├── backend/
│   ├── deployment.yaml         # Task 4
│   └── service.yaml
├── frontend/
│   ├── deployment.yaml         # Task 5
│   └── service.yaml
├── README.md
│
├── kind-cluster.yaml           # kind config: adds the 30080 host→node port mapping
├── bonus/rbac.yaml             # Task 8 (optional) – read-only namespaced ServiceAccount
├── scripts/
│   ├── deploy.sh               # one command: cluster → images → apply → wait
│   └── verify.sh               # Task 7 evidence capture (writes evidence/)
├── evidence/
│   ├── task7-transcript.txt    # Task 7 a–d, full terminal transcript
│   ├── cluster-state.txt       # get/describe of every object, quota usage, env dumps
│   ├── bonus-rbac.txt          # Task 8 allow/deny transcript
│   └── screenshots/            # 1.png-12.png, see "Evidence: screenshots" below
├── images/                     # the provided image build contexts (Dockerfiles + source)
│   ├── backend/  db/  frontend/
└── docker-compose.yml          # provided local smoke-test harness (not part of the k8s submission)
```

The four root manifests + `database/`, `backend/`, `frontend/` and `README.md`
follow the structure suggested in the brief exactly. The remaining entries are
additive: `kind-cluster.yaml` and `scripts/` reproduce the environment,
`evidence/` holds the Task 7 / bonus transcripts plus the numbered screenshots
(`screenshots/1.png`-`12.png`, indexed in "Evidence: screenshots" below),
`bonus/` is the optional Task 8,
and the provided Docker build contexts were moved under `images/` so they do not
collide with the `backend/` and `frontend/` manifest directories.

---

## Image note (please read)

The brief issues the images as `sarojsanyasi/dso202-<tier>` with the tag
**`1.0`** (the `image_build_guide.md` / `image_registry.md` files shipped in the
handout are empty; `1.0` is the only tag published on Docker Hub for all three
repositories). If your tutor issued a different tag, change the three `image:`
lines in `*/deployment.yaml`.

The published `:1.0` images are **`linux/arm64` only** (built on Apple Silicon;
note the `__MACOSX` folder in the handout). On an `amd64` host the pull fails
with `no matching manifest for linux/amd64`. `scripts/deploy.sh` therefore
rebuilds the byte-for-byte-equivalent images from the **provided** build contexts
(`images/db`, `images/backend`, `images/frontend`: same Dockerfiles, same source)
and side-loads them with `kind load docker-image`. `imagePullPolicy: IfNotPresent` on each
Deployment then uses the pre-loaded image instead of pulling. Nothing about the
graded manifests changes; only where the identical image bytes come from. On an
`arm64` host, or once `amd64` images are published, delete the build/load block in
`scripts/deploy.sh` and the images pull normally.

---

## How to deploy

Prerequisite: Docker running, plus `kind`, `kubectl` on `PATH`.

```bash
bash scripts/deploy.sh          # creates kind cluster "dso202", builds+loads images, applies everything
bash scripts/verify.sh          # runs Task 7 a–d, writes evidence/
```

Reach the app:

* **NodePort**: <http://localhost:30080> (works because `kind-cluster.yaml` maps
  host `30080` → node `30080`, matching the frontend Service's `nodePort`).
* **Fallback**: `kubectl -n dso202-assignment-01 port-forward svc/frontend 8080:8080`.

Tear down: `kind delete cluster --name dso202`.

### Known limitation (by design of the brief)

The frontend calls the backend **from the browser** (`fetch` in `app.js`), and
Task 5 fixes `BACKEND_URL` to the backend's *cluster-internal* address
(`http://backend.dso202-assignment-01.svc.cluster.local:8080`). That name only
resolves inside the cluster, so the browser UI at `:30080` loads but its AJAX
calls cannot reach the backend from the host. This is inherent to the brief
(cluster-internal `BACKEND_URL` **and** a backend that "must never be reachable
from outside the cluster"). The brief anticipates it: Task 7a is evidenced
"through the frontend **or via `curl` through a port-forwarded backend**"; the
`curl` path is used here.

---

## Task 1: Architecture note

*(written before any manifest: which cluster components schedule and run each
Pod, and which objects each tier uses and why)*

### What runs where when `kubectl apply` is issued

**Control plane** (all on the single `dso202-control-plane` node, which is itself
a Docker container):

* **kube-apiserver**: the only component the manifests talk to. It authenticates,
  validates and admits every object (Namespace, ConfigMap, Secret, PVC, Deployment,
  Service, ResourceQuota, LimitRange) and persists it.
* **etcd**: stores the accepted desired state for all of the above.
* **kube-controller-manager**: runs the controllers that turn desired state into
  Pods: the **Deployment** controller creates a **ReplicaSet** per tier; each
  ReplicaSet creates its **Pod** object; the **PersistentVolume** controller binds
  the `db-data` PVC; the **EndpointSlice** controller fills in the `backend` /
  `frontend` Service backends (the headless `db` Service gets an EndpointSlice but
  no virtual IP); the **ResourceQuota** controller admits or rejects each Pod
  against `quota.yaml`; the **Namespace** controller owns the namespace lifecycle.
* **kube-scheduler**: watches for the three unscheduled Pods and binds each to the
  one node, checking the Pod's resource *requests* (supplied by the LimitRange
  defaults / explicit `resources:`) against node capacity and the namespace quota,
  and honouring the control-plane node's taint (kind's single node is
  schedulable).
* **cloud-controller-manager**: not used (kind is not a cloud provider); the
  NodePort is reachable via kind's `extraPortMappings`, not a cloud LoadBalancer.

**Node components** (on `dso202-control-plane`):

* **kubelet**: sees the bound Pods, asks the runtime to start containers, uses the
  pre-loaded images (`IfNotPresent`), mounts the PVC-backed volume into the
  database Pod at `/var/lib/postgresql/data`, projects the ConfigMap/Secret keys in
  as environment variables, runs the container process, and reports Pod status
  back to the apiserver (this is also what recreates a container in place and lets
  the ReplicaSet replace a deleted Pod; see Task 7c).
* **container runtime (containerd)**: pulls/holds image layers and runs the
  containers.
* **kube-proxy**: programs the node's iptables rules so the `backend` ClusterIP
  and the `frontend` NodePort (30080) forward to the current Pod IPs. The headless
  `db` Service has **no** proxy rules; clients get the Pod IP straight from DNS.
* **CNI plugin (kindnet)**: assigns each Pod a `10.244.x.x` IP and wires
  Pod-to-Pod traffic.
* **CoreDNS** (add-on Pods in `kube-system`): resolves the Service names
  (`db`, `backend`, `frontend`) within the namespace search domain; this is what
  Task 7b demonstrates.
* **local-path-provisioner** (kind add-on): watches the `db-data` PVC and
  dynamically provisions a hostPath-backed PersistentVolume on the node
  (StorageClass `standard`, the cluster default).

### Objects per tier and why

| Tier | Objects | Why |
| --- | --- | --- |
| *namespace-wide* | **Namespace** | one tenancy + governance boundary (LO 5). |
| | **ConfigMap** + **Secret** | config lifted out of the images; non-sensitive vs credential split (Task 2); consumed via `configMapKeyRef` / `secretKeyRef`. |
| | **ResourceQuota** + **LimitRange** | cap the namespace total; give every container a sane default + hard min/max (Task 6). |
| database | **Deployment** (1 replica, `strategy: Recreate`) | declarative, self-healing workload; `Recreate` guarantees two Postgres Pods never hold the single `ReadWriteOnce` volume at once. |
| | **PersistentVolumeClaim** | Postgres data must outlive the Pod (LO 4, Task 7c); bound by kind's default provisioner. |
| | **headless Service** (`clusterIP: None`) | a single stateful Pod needs a stable in-namespace DNS name, not load-balancing or an external IP; headless gives exactly that and nothing routable from outside. |
| backend | **Deployment** (1 replica) | stateless, freely restartable/replaceable. |
| | **ClusterIP Service** | in-cluster-only entry point; default type; provides the `backend` DNS name and would load-balance future replicas. Never NodePort/LoadBalancer. |
| frontend | **Deployment** (1 replica) | stateless static-asset server. |
| | **NodePort Service** (30080) | the single permitted way in from outside the cluster, via the kind port mapping. |

A StatefulSet is not used for the database: Unit I scope, a single replica, and a
PVC referenced from a Deployment already give stable storage and a stable name.

---

## Task 2: Configuration and Secrets

* **`configmap.yaml`** holds every non-sensitive value:
  `DB_HOST, DB_PORT, DB_NAME, APP_PORT, CORS_ORIGIN, POSTGRES_DB, BACKEND_URL`.
* **`secret.yaml`** holds only credentials:
  `DB_USER, DB_PASSWORD, POSTGRES_USER, POSTGRES_PASSWORD`.
* The **backend/database variable-name mismatch** from the brief is handled by
  carrying **both** naming conventions with **matching values**: the backend reads
  `DB_*`, the official Postgres image reads `POSTGRES_*`, and
  `DB_NAME == POSTGRES_DB == taskdb`, `DB_USER == POSTGRES_USER == taskuser`,
  `DB_PASSWORD == POSTGRES_PASSWORD == taskpass`. Each Deployment consumes only its
  own set (verified in `evidence/cluster-state.txt`: the env dump inside each
  running container).
* No credential appears in any Deployment, the ConfigMap, or anywhere else; only
  in the Secret, and only base64-encoded (not `stringData`).

> **Secret encoding caveat (documentation requirement).** A Kubernetes Secret is
> only **base64-encoded, not encrypted**. Anyone who can read the object, or read
> etcd, recovers the values with `base64 -d` (e.g.
> `kubectl -n dso202-assignment-01 get secret task-tracker-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d`).
> Real mitigations, such as an `EncryptionConfiguration` for encryption at rest,
> tight RBAC on the Secret (see the bonus), or an external secret store, are out
> of scope for Unit I and are **not** applied here.

---

## Task 3–5: The three tiers (summary)

* **Database**: `db-data` PVC (1Gi, RWO, default StorageClass, no
  `storageClassName` set → kind's `standard`/local-path). Single-replica
  Deployment mounts it at `/var/lib/postgresql/data` (with
  `PGDATA=/var/lib/postgresql/data/pgdata` so the official image initialises
  cleanly), consuming `POSTGRES_DB` from the ConfigMap and `POSTGRES_USER` /
  `POSTGRES_PASSWORD` from the Secret; never any `DB_*` key. Headless Service
  `db` exposes 5432 in-namespace only.
* **Backend**: Deployment consumes `DB_HOST` (= `db`, the headless Service name),
  `DB_PORT, DB_NAME, APP_PORT, CORS_ORIGIN` from the ConfigMap and `DB_USER` /
  `DB_PASSWORD` from the Secret. ClusterIP Service `backend` exposes 8080
  in-cluster only.
* **Frontend**: Deployment consumes `BACKEND_URL` from the ConfigMap; the
  image's entrypoint substitutes it into `config.js` at Pod start (confirmed in
  `evidence/cluster-state.txt`). NodePort Service `frontend` exposes 8080 as node
  port 30080.

Every Pod, Deployment and Service carries `tier: frontend|backend|database` (plus
`app: task-tracker`); see the `-L tier` output in `evidence/cluster-state.txt`.

---

## Task 6: ResourceQuota / LimitRange justification

Measured idle footprint of the images: Postgres ~15–30 MiB, Node/Express
~40–60 MiB, nginx ~5–10 MiB; all three effectively 0 CPU at rest.

### LimitRange `task-tracker-limits` (per container)

| | CPU | Memory | Reasoning |
| --- | --- | --- | --- |
| `defaultRequest` | 100m | 128Mi | comfortably above every image's idle draw, so nothing is starved when a manifest omits `resources:`. |
| `default` (limit) | 500m | 512Mi | ample burst for Postgres first-init and Node GC without a single container reserving much. |
| `min` | 50m | 64Mi | the quota requires *both* requests and limits on every container; this stops a "near-zero" container from being admitted and skewing scheduling. |
| `max` | 1 | 1Gi | no single container may reserve the whole namespace budget. |

Each Deployment also sets explicit `resources:` inside these bounds: db
`100m/192Mi → 500m/512Mi`, backend `100m/128Mi → 500m/256Mi`, frontend
`50m/64Mi → 200m/128Mi`.

### ResourceQuota `task-tracker-quota` (namespace total)

Steady state (the 3 Pods, from `kubectl describe resourcequota`, see
`evidence/cluster-state.txt`): **requests 250m / 384Mi**, **limits 1200m /
896Mi**.

| Quota key | Value | Reasoning |
| --- | --- | --- |
| `requests.cpu` | `1` | ~4× the 250m steady request: absorbs a rolling update (`maxSurge` briefly adds one backend + one frontend Pod, ~+150m) plus a couple of `kubectl exec`/`debug` Pods, while never letting the namespace *reserve* more than one core from the single kind node. |
| `requests.memory` | `1Gi` | ~2.7× the 384Mi steady request; same surge + debug headroom, capped so the namespace can't reserve the node out from under the control plane. |
| `limits.cpu` | `3` | lets every container burst to its 500m limit at once (1200m) *and* surge Pods burst too, while still bounding a runaway namespace well under node capacity. |
| `limits.memory` | `2Gi` | headroom over the 896Mi steady limit for surge + a memory spike during Postgres init, with a hard ceiling that protects other namespaces. |
| `pods` | `12` | 3 steady + up to 3 surge during concurrent rollouts + `exec`/`debug` Pods + the throwaway Pod from the Task 7d imperative command. A hard stop far above need, so a stray `replicas: 50` is rejected immediately. |
| `persistentvolumeclaims` | `2` | only the database claims storage (1). A ceiling of 2 permits one extra (a restore/migration PVC) while making accidental storage sprawl impossible. |

All values are derived from the measured steady-state numbers above, not copied.

---

## Task 7: Verification and interactivity

Full transcript: **`evidence/task7-transcript.txt`** (produced by
`scripts/verify.sh`). Supporting `get`/`describe` output:
**`evidence/cluster-state.txt`**. Screenshots of each step run live against the
cluster are in **`evidence/screenshots/`**: `8.png` (7a), `9.png` (7b),
`10a.png` / `10b.png` (7c), `11.png` (7d); see the index below.

### 7a: Full CRUD cycle  *(via `curl` through a port-forwarded backend)*

`POST` → `id: 4` created · `GET /api/tasks/4` → the task · `PUT` `{"status":"done"}`
→ status flips to `done` · `DELETE /api/tasks/4` → **204** · `GET /api/tasks/4`
→ **404**. Seed rows 1–3 (from the image's `01-init.sql`) list correctly
throughout.

### 7b: Service DNS resolution from inside a Pod

`kubectl exec` into the **frontend** Pod:

* `nslookup backend.dso202-assignment-01.svc.cluster.local` → `10.96.22.244`
  (the ClusterIP), served by CoreDNS at `10.96.0.10`.
* `curl -s http://backend:8080/api/status` → `{"status":"ok","db":"connected"}`
  (the backend Service is reached **by name**, and it in turn reaches the
  database by its Service name).
* `nslookup db` → `10.244.0.x`, i.e. the **Pod IP** directly, showing the
  headless Service resolves straight to the endpoint with no cluster IP.

*(musl's `nslookup` walks every entry in the `search` line and prints `NXDOMAIN`
for the misses before the hit, then exits non-zero; the successful `Name: … /
Address: …` line is the relevant one.)*

### 7c: Self-healing and data persistence

1. Create `persist-marker`.
2. `kubectl delete pod <backend>` → `kubectl get pods -l tier=backend --watch`
   shows the ReplicaSet standing up a **new** Pod within seconds (name changes,
   same `pod-template-hash` / ReplicaSet), `1/1 Running`.
3. Read the marker back (from inside the cluster, via the frontend Pod): **still
   there**, the Pod was replaced, the data lives on the PV.
4. Stronger check: `kubectl delete pod <db>` too, and `kubectl get pvc db-data`
   stays `Bound` to the **same** PV (same `pvc-…` volume name), and the marker is
   *still* retrievable after the database Pod restarts. Pod lifecycle and
   PersistentVolume lifecycle are independent.

   *(The backend process may log one restart here: when the database Pod is
   deleted mid-query its connection pool drops and Node exits; the ReplicaSet
   restarts it and it reconnects. Nothing is lost; the data is on the PV.)*

### 7d: Declarative vs imperative

Both create an equivalent ClusterIP Service for the backend selector:

```bash
# declarative
kubectl apply -f backend/service.yaml

# imperative equivalent (throwaway)
kubectl -n dso202-assignment-01 create service clusterip backend-imperative --tcp=8080:8080
kubectl -n dso202-assignment-01 set selector service backend-imperative 'app=task-tracker,tier=backend'
```

**Comparison.** The *declarative* form is a version-controlled file that is the
single source of truth: it is diff-able and reviewable, idempotent (re-running
`apply` reports `unchanged` and a 3-way merge reconciles drift), and reproducible
on any cluster with one command, which is why the entire rest of this assignment
is declarative. Its costs are verbosity and needing a file. The *imperative* form
(`create` / `expose` / `run` / `set`) is faster to type and needs no file, which
suits exploration and live debugging; but nothing records what was done, it is not
idempotent (`create` errors if the object exists), it drifts from source control
immediately, and its flags cannot express every field; here a follow-up
`kubectl set selector` was required just to match the declarative object. Verdict:
imperative for throwaway/debugging, declarative for anything that must be
reviewed, reproduced, or kept.

---

## Task 8: Bonus, namespace RBAC  *(optional, attempted)*

`bonus/rbac.yaml`: a `ServiceAccount` **viewer**, a namespaced **Role**
`namespace-readonly` (only `get`/`list`/`watch`, and deliberately **no**
`secrets`), and a **RoleBinding**. Transcript in `evidence/bonus-rbac.txt`,
executed with a token-only kubeconfig so only the ServiceAccount's rights apply:

* `kubectl get pods` / `get deploy` → **allowed**
* `kubectl delete pod --all` → **Forbidden** (no `delete` verb)
* `kubectl get secret task-tracker-secret` → **Forbidden** (`secrets` not in the Role)
* `kubectl -n kube-system get pods` → **Forbidden** (a `Role` cannot grant
  anything outside its own namespace)

---

## Evidence: screenshots

All screenshots live in **`evidence/screenshots/`** and were captured on
`2026-09-08` from a running deployment on the `dso202` kind cluster. The command
behind each shot is listed in the table below, so every image is reproducible.

| # | File | What it shows | Evidences |
| --- | --- | --- | --- |
| 01 | `screenshots/1.png` | `kind get clusters`, `kubectl config current-context`, `kubectl get nodes -o wide`: the `dso202` cluster exists and kubectl points at it. | Practical 1 prerequisite |
| 02 | `screenshots/2.png` | `kubectl get all,pvc,configmap,secret -n $NS -o wide`: 3 Deployments + 3 ReplicaSets + 3 Pods `Running`, the 3 Services with the correct types (frontend NodePort 30080, backend ClusterIP, db headless `None`), the bound PVC, the ConfigMap and the Secret. | Tasks 1–6 at a glance |
| 03 | `screenshots/3.png` | `kubectl get pod,deploy,svc -n $NS -L tier`: a `TIER` column reading `frontend` / `backend` / `database` on every row. | Constraint §6 (`tier` label everywhere) |
| 04 | `screenshots/4.png` | `kubectl get storageclass` + `kubectl get pvc,pv -n $NS`: `standard` is the default StorageClass; `db-data` is `Bound` to a dynamically-provisioned PV. | Task 3 (persistent storage) |
| 05 | `screenshots/5.png` | `describe configmap`, the Secret as YAML, and `base64 -d` recovering `DB_PASSWORD` in plaintext. | Task 2 (config/secret split + "encoded, not encrypted" caveat) |
| 06 | `screenshots/6.png` | `describe resourcequota task-tracker-quota` + `describe limitrange task-tracker-limits`: `Used` vs `Hard`, and the per-container default / min / max. | Task 6 (quota + LimitRange, justified in "Task 6" above) |
| 07 | `screenshots/7.png` | `kubectl exec` env dumps: backend has `DB_*` (with `DB_HOST=db`), postgres has `POSTGRES_*`, values match. | Tasks 2 & 4 (naming-mismatch requirement, config actually injected) |
| 08 | `screenshots/8.png` | CRUD over `curl` through `port-forward svc/backend 18080:8080`: `POST` → new id, `GET /:id`, `PUT {"status":"done"}`, `DELETE` → `204`, `GET` deleted → `404`; seed rows 1–3 list throughout. | **Task 7a** (full CRUD cycle) |
| 09 | `screenshots/9.png` | From inside the frontend Pod: `nslookup backend…svc.cluster.local` → ClusterIP `10.96.22.244`, `curl http://backend:8080/api/status` → `{"status":"ok","db":"connected"}`, `nslookup db` → a `10.244.x.x` Pod IP (headless). | **Task 7b** (Service DNS resolution) |
| 10a | `screenshots/10a.png` | Terminal A: `kubectl get pods -l tier=backend --watch` showing the old Pod `Terminating` and a new Pod `Running` with a different name after the delete. | **Task 7c** (self-healing via the ReplicaSet) |
| 10b | `screenshots/10b.png` | Terminal B: the `persist-marker` task is still returned after the backend Pod is deleted and recreated, and `kubectl get pvc db-data` is still `Bound` to the same PV. | **Task 7c** (data persistence: Pod vs PV lifecycle) |
| 11 | `screenshots/11.png` | `kubectl apply -f backend/service.yaml` vs `kubectl create service clusterip … + set selector`: both yield an equivalent Service; cleanup deletes the imperative one. | **Task 7d** (declarative vs imperative) |
| 12 | `screenshots/12.png` | `http://localhost:30080`: the "Field Log" Task Tracker page served over the NodePort. The UI shell loads; its browser `fetch` calls to the backend fail from the host by design (see "Known limitation"), which is why 7a is evidenced via `curl`. | Task 5 (frontend reachable on NodePort 30080) |

**Task 8 (bonus)** has no screenshot; its allow/deny evidence is the terminal
transcript in **`evidence/bonus-rbac.txt`**.

---

## Constraints checklist

* [x] Pinned image tag `:1.0` for all tiers; no `latest`.
* [x] No credential in plaintext in any committed manifest; Secret only, base64.
* [x] `tier` label on every Pod, Deployment and Service.
* [x] Backend = ClusterIP, database = headless; neither is NodePort/LoadBalancer.
* [x] All resources scoped to `dso202-assignment-01`.
* [x] All manifests are version-controlled YAML.
