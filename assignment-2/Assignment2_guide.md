# DSO202: Assignment 2: Advanced Kubernetes Concepts Applied to the Task Tracker

**Module:** DSO202: Scaling, Orchestration, Monitoring & Observability
**Scope:** Unit II only
**Weighting:** 10 marks (of the module's four assignments, each 10 marks)

---

## 1. Overview

No formal brief was issued for this assignment beyond one instruction:
*"Utilize the concepts and knowledge gained from the Unit 2 lectures to
effectively implement Assignment 1."* This document is that instruction
turned into a concrete, gradeable task list, written in the same style and
weighting as `assignment-1/Assignment_guide.md`, covering every topic listed
in `unit2.md`:

- 2.1 StatefulSets
- 2.2 Ingress and Ingress Controllers
- 2.3 Kubernetes RBAC
- 2.4 Kubernetes Operators

The same Task Tracker application from Assignment 1 (frontend, backend,
PostgreSQL, no application code changes) is redeployed into its own
namespace, `dso202-assignment-02`, on the same shared `kind` cluster, using
these four concepts in place of Assignment 1's Unit I equivalents.

---

## 2. Learning Outcomes Addressed

| Unit II topic | Where addressed |
| --- | --- |
| 2.1 StatefulSets | Task 1: `database/statefulset.yaml` |
| 2.2 Ingress and Ingress Controllers | Task 2: `ingress/ingress.yaml` + ingress-nginx |
| 2.3 RBAC | Task 3: `rbac/rbac.yaml` |
| 2.4 Kubernetes Operators | Task 4: `operator/` |

---

## 3. Tasks

### Task 1: StatefulSet Database Tier *(2.1)*

- Replace Assignment 1's Deployment+PVC database with a **StatefulSet**
  (`serviceName: db`, 1 replica, a `volumeClaimTemplates` entry instead of a
  hand-written PVC).
- Keep the headless Service (`clusterIP: None`) the StatefulSet requires.
- README must explain, in terms of *this* app, what a StatefulSet gives that
  the Assignment 1 Deployment did not: stable Pod identity (`db-0`), ordered
  deployment/scaling, and a per-replica PVC from the template.

### Task 2: Ingress and Ingress Controller *(2.2)*

- Install an Ingress Controller (ingress-nginx) on the `kind` cluster.
- Replace the frontend's NodePort Service with **ClusterIP**, fronted by an
  **Ingress** resource.
- The Ingress must demonstrate: basic path-based routing (`/` and `/api` to
  different Services), TLS termination (a Secret of type `kubernetes.io/tls`
  referenced by the Ingress), name-based virtual hosting (at least two
  distinct hostnames on the one Ingress/controller), and at least one
  controller-specific annotation.
- README must note which controller was used and why (2.2.2.1 vs 2.2.2.2).

### Task 3: RBAC *(2.3)*

- At least one **Role** + **RoleBinding** (namespace-scoped permissions).
- At least one **ClusterRole** + **ClusterRoleBinding** (cluster-scoped
  permissions, e.g. reading Nodes).
- At least one **aggregated ClusterRole** (`aggregationRule` selecting a
  label on other ClusterRoles).
- At least one application Pod (not just a demo ServiceAccount) running as a
  dedicated **ServiceAccount**, to demonstrate Pod authentication.
- README must show, with real allow/deny `kubectl` output per identity used,
  captured through an isolated (token-only, no client-certificate)
  kubeconfig per identity so the test is genuine.

### Task 4: A Basic Operator *(2.4)*

- Define a **CustomResourceDefinition** for a small, real problem (this
  submission: `DbBackup`, a one-shot pg_dump request against the database).
- Write a **controller** (the Operator pattern: watch the CR, reconcile
  cluster state, here a backup `Job`, to match it, report status back onto
  the CR) and run it as a Deployment in-cluster, under its own
  least-privilege ServiceAccount (ties back into Task 3).
- README must state what tooling was actually available (Go toolchain
  present/absent, `operator-sdk`/`kubebuilder` present/absent) and, if the
  standard scaffolding CLI was unavailable, what was substituted and why the
  substitute is still a faithful implementation of the pattern (2.4.1) and
  not just a plain script.

---

## 4. Non-Negotiable Constraints (carried over from Assignment 1)

- No image tag other than `:1.0` for the three app tiers; no `latest`.
- No credential in plaintext in any committed manifest.
- Every Pod/Deployment/StatefulSet/Service still carries a `tier` label.
- The database is still never exposed via NodePort/LoadBalancer (Ingress
  does not change this: only the frontend and, deliberately, the backend's
  `/api` path are ever reached from outside the cluster).
- Generated secrets (the Ingress TLS key) are never committed to git.

---

## 5. Marking Rubric

| Criterion | Marks | Evidence expected |
| --- | --- | --- |
| StatefulSet correctness | 2 | `db-0` stable identity survives a Pod delete; PVC named to the ordinal; headless Service |
| Ingress correctness | 3 | Path routing, TLS termination, 2+ virtual hosts, 1+ controller annotation, all demonstrated live |
| RBAC correctness | 2 | Role/RoleBinding, ClusterRole/ClusterRoleBinding, aggregated ClusterRole, and a Pod-authenticated ServiceAccount, each proven allow/deny |
| Operator correctness | 2 | CRD applies; creating a CR triggers real reconciliation (a Job runs); `.status` reflects the outcome |
| Documentation | 1 | README explains the *why* for each Unit II concept in terms of this app, not just repeats the manifest |
| **Total** | **10** | |

---

## 6. Submission Checklist

- [ ] Namespace `dso202-assignment-02` created, separate from Assignment 1
- [ ] Database is a StatefulSet with a volumeClaimTemplate; stable identity demonstrated
- [ ] ingress-nginx installed; frontend Service changed to ClusterIP
- [ ] Ingress demonstrates path routing, TLS, 2+ hosts, 1+ annotation
- [ ] Role + RoleBinding, ClusterRole + ClusterRoleBinding, and an aggregated ClusterRole all applied and proven
- [ ] A Pod runs under a dedicated ServiceAccount with no Role bound, and its lack of authorization is demonstrated
- [ ] DbBackup CRD + controller deployed; a sample CR reconciles to Succeeded
- [ ] README documents the reasoning for each task, not only the steps
- [ ] All manifests and (hand-written or scaffolded) operator source committed to version control
