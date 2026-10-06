#!/usr/bin/env bash
# DSO202 Assignment 2 -- evidence capture for StatefulSet identity, Ingress
# (routing + TLS + name-based vhosting), RBAC (allow/deny), and the DbBackup
# Operator. Run after scripts/deploy.sh. Writes evidence/assignment2-transcript.txt.
set -uo pipefail

NS=dso202-assignment-02
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EV_DIR="$ROOT/evidence"
mkdir -p "$EV_DIR"

hr() { printf '\n============================================================\n%s\n============================================================\n' "$1"; }
kn() { kubectl -n "$NS" "$@"; }

{
hr "CONTEXT"
kubectl config current-context
kn get all,statefulset,ingress,pvc,configmap,secret,resourcequota -o wide

hr "2.1 StatefulSet: stable network identity + per-replica storage"
echo "\$ kubectl -n $NS get pods -l tier=database -o wide     # name is always db-0, not a random suffix"
kn get pods -l tier=database -o wide
echo
echo "\$ kubectl -n $NS get pvc                                 # db-data-db-0, bound to this ordinal"
kn get pvc
echo
FE=$(kn get pod -l tier=frontend -o jsonpath='{.items[0].metadata.name}')
echo "\$ kubectl -n $NS exec $FE -- nslookup db-0.db.${NS}.svc.cluster.local"
kn exec "$FE" -- nslookup "db-0.db.${NS}.svc.cluster.local"
echo
echo "# --- delete db-0 and confirm the REPLACEMENT Pod has the SAME name ---"
kn delete pod db-0
kn rollout status statefulset/db --timeout=120s
echo "\$ kubectl -n $NS get pod db-0     # same name after recreation -- a Deployment would rename it"
kn get pod db-0
echo
echo "# deleting db-0 drops the backend's DB connection pool and it restarts once"
echo "# (documented in Assignment 1's Task 7c) -- settle before hitting it via Ingress"
kn rollout status deploy/backend --timeout=60s

hr "2.2 Ingress: routing, TLS, name-based virtual hosting"
echo "# both hosts resolve to the ingress-nginx controller's hostPort via --resolve,"
echo "# so this works without editing /etc/hosts. Ports are 8080/8443 (not 80/443)"
echo "# because this host's Apache already owns 80 -- see kind-cluster.yaml."
echo
echo "\$ curl -sk https://tasktracker.dso202.local:8443/ --resolve tasktracker.dso202.local:8443:127.0.0.1 | head -5"
curl -sk https://tasktracker.dso202.local:8443/ --resolve tasktracker.dso202.local:8443:127.0.0.1 | head -5
echo
echo "\$ curl -sk https://tasktracker.dso202.local:8443/api/tasks --resolve tasktracker.dso202.local:8443:127.0.0.1"
curl -sk https://tasktracker.dso202.local:8443/api/tasks --resolve tasktracker.dso202.local:8443:127.0.0.1; echo
echo
echo "# second virtual host -- SAME ip:port, DIFFERENT Service (straight to backend)"
echo "\$ curl -sk https://status.dso202.local:8443/api/status --resolve status.dso202.local:8443:127.0.0.1"
curl -sk https://status.dso202.local:8443/api/status --resolve status.dso202.local:8443:127.0.0.1; echo
echo
echo "# TLS termination -- the presented cert is the self-signed one from deploy.sh"
echo "\$ curl -skv https://tasktracker.dso202.local:8443/ --resolve tasktracker.dso202.local:8443:127.0.0.1 2>&1 | grep -E 'subject:|issuer:|SSL connection'"
curl -skv https://tasktracker.dso202.local:8443/ --resolve tasktracker.dso202.local:8443:127.0.0.1 2>&1 | grep -E 'subject:|issuer:|SSL connection'

hr "2.3 RBAC: authentication vs authorization"
echo "# IMPORTANT: 'kubectl --token=X' alone is NOT a valid test on this cluster --"
echo "# the ambient admin kubeconfig also carries a client CERTIFICATE, and mutual-TLS"
echo "# client-cert auth wins over a bearer token, so every call would silently run as"
echo "# admin regardless of which token is passed (verified: try it, everything says"
echo "# 'yes' to auth can-i --list). A clean, TOKEN-ONLY kubeconfig avoids that, exactly"
echo "# like Assignment 1's bonus RBAC evidence (evidence/bonus-rbac.txt) already did."
SRV=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_DIR="$(mktemp -d)"
kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$CA_DIR/ca.crt"

as_identity() {   # as_identity <name> <token> -- builds an isolated kubeconfig
  local kc="$CA_DIR/$1.kubeconfig"
  kubectl --kubeconfig="$kc" config set-cluster k --server="$SRV" --certificate-authority="$CA_DIR/ca.crt" --embed-certs=true >/dev/null
  kubectl --kubeconfig="$kc" config set-credentials "$1" --token="$2" >/dev/null
  kubectl --kubeconfig="$kc" config set-context c --cluster=k --user="$1" --namespace="$NS" >/dev/null
  kubectl --kubeconfig="$kc" config use-context c >/dev/null
  echo "$kc"
}

BACKEND_POD=$(kn get pod -l tier=backend -o jsonpath='{.items[0].metadata.name}')
echo "# backend-sa: has an identity (mounted token) but NO Role/RoleBinding targets it"
echo "\$ kubectl -n $NS exec $BACKEND_POD -- cat /var/run/secrets/kubernetes.io/serviceaccount/token"
BACKEND_TOKEN=$(kn exec "$BACKEND_POD" -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
echo "# (token retrieved, ${#BACKEND_TOKEN} chars)"
BACKEND_KC=$(as_identity backend-sa "$BACKEND_TOKEN")
echo "\$ kubectl --kubeconfig=<backend-sa only> -n $NS get pods       # expect Forbidden"
kubectl --kubeconfig="$BACKEND_KC" -n "$NS" get pods 2>&1 | tail -3
echo
echo "# viewer: bound to Role (namespace) + ClusterRole (nodes) + aggregated ClusterRole (quota)"
VIEWER_TOKEN=$(kn create token viewer)
VIEWER_KC=$(as_identity viewer "$VIEWER_TOKEN")
echo "\$ kubectl --kubeconfig=<viewer only> -n $NS get pods            # allowed (Role)"
kubectl --kubeconfig="$VIEWER_KC" -n "$NS" get pods
echo "\$ kubectl --kubeconfig=<viewer only> get nodes                  # allowed (ClusterRole)"
kubectl --kubeconfig="$VIEWER_KC" get nodes
echo "\$ kubectl --kubeconfig=<viewer only> -n $NS get resourcequota   # allowed (aggregated ClusterRole)"
kubectl --kubeconfig="$VIEWER_KC" -n "$NS" get resourcequota
echo "\$ kubectl --kubeconfig=<viewer only> -n $NS get secret task-tracker-secret   # expect Forbidden"
kubectl --kubeconfig="$VIEWER_KC" -n "$NS" get secret task-tracker-secret 2>&1 | tail -3
echo "\$ kubectl get clusterrole dso202-monitoring-aggregate -o jsonpath='{.rules}'   # auto-populated"
kubectl get clusterrole dso202-monitoring-aggregate -o jsonpath='{.rules}'; echo
rm -rf "$CA_DIR"

hr "2.4 Operator: DbBackup custom resource end to end"
kubectl -n "$NS" delete dbbackup demo-backup --ignore-not-found >/dev/null 2>&1
echo "\$ kubectl apply -f operator/config/samples/dbbackup-sample.yaml"
kubectl apply -f "$ROOT/operator/config/samples/dbbackup-sample.yaml"
echo
echo "# poll .status.phase until it leaves Pending/Running"
for i in $(seq 1 30); do
  PHASE=$(kn get dbbackup demo-backup -o jsonpath='{.status.phase}' 2>/dev/null)
  echo "  t+${i}s phase=$PHASE"
  [ "$PHASE" = "Succeeded" ] || [ "$PHASE" = "Failed" ] && break
  sleep 2
done
echo
echo "\$ kubectl -n $NS get dbbackup demo-backup -o yaml"
kn get dbbackup demo-backup -o yaml
echo
JOB=$(kn get dbbackup demo-backup -o jsonpath='{.status.jobName}')
echo "\$ kubectl -n $NS logs job/$JOB"
kn logs "job/$JOB"

hr "DONE"
} 2>&1 | tee "$EV_DIR/assignment2-transcript.txt"
