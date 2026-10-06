# DSO202: Assignments

Scaling, Orchestration, Monitoring & Observability: a Task Tracker app
(frontend + backend + PostgreSQL, no application code written by either
assignment) redeployed against successive units' Kubernetes concepts, on one
shared local `kind` cluster.

| Assignment | Scope | Namespace | Details |
| --- | --- | --- | --- |
| [assignment-1/](assignment-1/README.md) | Unit I: namespaces, ConfigMap/Secret, Deployments, PVC, Services, quotas, `kubectl` verification | `dso202-assignment-01` | [Assignment_guide.md](assignment-1/Assignment_guide.md) |
| [assignment-2/](assignment-2/README.md) | Unit II: StatefulSets, Ingress, RBAC, a custom Operator | `dso202-assignment-02` | [Assignment2_guide.md](assignment-2/Assignment2_guide.md) |

Each assignment folder is self-contained (its own manifests, scripts,
evidence) and can be applied independently; they never share a namespace, so
both can be deployed to the cluster at once.

---

## Shared at this level

- **`images/`**: the provided build contexts (Dockerfiles + source) for the
  three app images (`sarojsanyasi/dso202-{frontend,backend,db}:1.0`). Both
  assignments' `scripts/deploy.sh` build from here on amd64 hosts, since the
  tutor's registry images are arm64-only (see assignment-1's README "Image
  note" for the full explanation).
- **`kind-cluster.yaml`**: one cluster definition (`dso202`) for the whole
  module, since kind's node config is immutable after creation and each
  assignment needs different host-port mappings: Assignment 1 needs 30080
  for its frontend NodePort; Assignment 2 needs an `ingress-ready` node
  label plus 8080/8443 for the ingress-nginx controller (mapped away from
  the standard 80/443 because this host already runs Apache on 80 for
  unrelated coursework; see the file's own header comment).
- **`docker-compose.yml`**, **`image_build_guide.md`**, **`image_registry.md`**:
  provided as part of the original handout, unmodified.
- **`unit2.md`**: the Unit II topic list Assignment 2 was built against.

## Deploying both

```bash
kind create cluster --name dso202 --config kind-cluster.yaml   # once
bash assignment-1/scripts/deploy.sh
bash assignment-2/scripts/deploy.sh
```

Tear down: `kind delete cluster --name dso202`.
