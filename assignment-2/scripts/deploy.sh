#!/usr/bin/env bash
# DSO202 Assignment 2 -- bring the Unit II stack up on the shared kind cluster.
#
# Usage:  bash scripts/deploy.sh
#
# Steps:
#   1. create/reuse the kind cluster (ingress-ready + NodePort mappings)
#   2. build+load the 3 app images (amd64 hosts) and the operator image
#   3. install the ingress-nginx controller (kind-specific manifest), if absent
#   4. kubectl apply namespace -> config/secret/quota -> RBAC -> CRD ->
#      StatefulSet -> backend -> frontend -> operator -> Ingress
#   5. generate a self-signed TLS cert/key and load it as a Secret (never
#      committed to git -- see ingress/ingress.yaml's header comment)
#   6. wait for every rollout
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"      # .../assignment-2
REPO_ROOT="$(cd "$ROOT/.." && pwd)"           # shared images/, kind-cluster.yaml
cd "$ROOT"

CLUSTER=dso202
NS=dso202-assignment-02
APP_IMAGES=(sarojsanyasi/dso202-db:1.0 sarojsanyasi/dso202-backend:1.0 sarojsanyasi/dso202-frontend:1.0)
OPERATOR_IMAGE=dso202/dbbackup-operator:1.0
INGRESS_NGINX_VERSION=controller-v1.11.3

# 1. cluster ------------------------------------------------------------------
if ! kind get clusters | grep -qx "$CLUSTER"; then
  echo ">> creating kind cluster '$CLUSTER' (ingress-ready)"
  kind create cluster --name "$CLUSTER" --config "$REPO_ROOT/kind-cluster.yaml"
else
  echo ">> kind cluster '$CLUSTER' already exists"
  echo "   (if it predates this assignment's kind-cluster.yaml, ingress will"
  echo "   NOT work until you: kind delete cluster --name $CLUSTER && rerun)"
fi
kubectl config use-context "kind-${CLUSTER}"

# 2. images -------------------------------------------------------------------
if [ "$(uname -m)" = "x86_64" ]; then
  echo ">> building app images from provided Dockerfiles (amd64 host)"
  docker build -t sarojsanyasi/dso202-db:1.0       "$REPO_ROOT/images/db"
  docker build -t sarojsanyasi/dso202-backend:1.0  "$REPO_ROOT/images/backend"
  docker build -t sarojsanyasi/dso202-frontend:1.0 "$REPO_ROOT/images/frontend"
  echo ">> loading app images into the cluster"
  kind load docker-image --name "$CLUSTER" "${APP_IMAGES[@]}"
fi

echo ">> building the DbBackup operator image"
docker build -t "$OPERATOR_IMAGE" "$ROOT/operator"
echo ">> loading the operator image into the cluster"
kind load docker-image --name "$CLUSTER" "$OPERATOR_IMAGE"

# 3. ingress controller ---------------------------------------------------
if ! kubectl get ns ingress-nginx >/dev/null 2>&1; then
  echo ">> installing ingress-nginx ($INGRESS_NGINX_VERSION, kind provider manifest)"
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"
  echo ">> waiting for the ingress-nginx admission webhook Job + controller Pod"
  kubectl wait --namespace ingress-nginx \
    --for=condition=Complete job --selector=app.kubernetes.io/component=admission-webhook \
    --timeout=180s
  kubectl wait --namespace ingress-nginx \
    --for=condition=Ready pod --selector=app.kubernetes.io/component=controller \
    --timeout=180s
else
  echo ">> ingress-nginx already installed"
fi

# 4. apply ------------------------------------------------------------------
echo ">> applying manifests"
kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml -f secret.yaml -f quota.yaml
kubectl apply -f rbac/rbac.yaml
kubectl apply -f operator/config/crd/dbbackups.yaml
kubectl apply -f database/
kubectl apply -f backend/
kubectl apply -f frontend/
kubectl apply -f operator/config/manager/manager.yaml

# 5. TLS secret (generated, never committed) -------------------------------
echo ">> generating a self-signed TLS cert for the Ingress"
TLS_DIR="$(mktemp -d)"
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout "$TLS_DIR/tls.key" -out "$TLS_DIR/tls.crt" \
  -subj "/CN=tasktracker.dso202.local" \
  -addext "subjectAltName=DNS:tasktracker.dso202.local,DNS:status.dso202.local" \
  2>/dev/null
kubectl -n "$NS" create secret tls tasktracker-tls \
  --cert="$TLS_DIR/tls.crt" --key="$TLS_DIR/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -rf "$TLS_DIR"

kubectl apply -f ingress/ingress.yaml

# 6. wait -----------------------------------------------------------------
echo ">> waiting for rollouts"
kubectl -n "$NS" rollout status statefulset/db          --timeout=180s
kubectl -n "$NS" rollout status deploy/backend           --timeout=180s
kubectl -n "$NS" rollout status deploy/frontend          --timeout=180s
kubectl -n "$NS" rollout status deploy/dbbackup-operator --timeout=180s

echo
kubectl -n "$NS" get pods,svc,statefulset,ingress
echo
echo ">> add to /etc/hosts:   127.0.0.1  tasktracker.dso202.local status.dso202.local"
echo ">> then browse:         http://tasktracker.dso202.local:8080/   (or https://...:8443, self-signed cert)"
echo ">> status vhost:        http://status.dso202.local:8080/api/status"
echo ">> (8080/8443, not 80/443 -- see kind-cluster.yaml's header comment: this host's Apache already owns 80)"
echo ">> trigger a backup:    kubectl apply -f operator/config/samples/dbbackup-sample.yaml"
