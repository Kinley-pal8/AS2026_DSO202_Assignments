#!/usr/bin/env bash
# DSO202 Assignment 1 -- bring the whole stack up on a kind cluster.
#
# Usage:  bash scripts/deploy.sh
#
# Steps:
#   1. create the kind cluster (with the NodePort host mapping) if absent
#   2. (amd64 hosts only) build the 3 images from the provided Dockerfiles
#      and load them into the cluster -- see README "Image note"
#   3. kubectl apply every manifest, in dependency order
#   4. wait for all three Deployments to roll out
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CLUSTER=dso202
NS=dso202-assignment-01
IMAGES=(sarojsanyasi/dso202-db:1.0 sarojsanyasi/dso202-backend:1.0 sarojsanyasi/dso202-frontend:1.0)

# 1. cluster ------------------------------------------------------------------
if ! kind get clusters | grep -qx "$CLUSTER"; then
  echo ">> creating kind cluster '$CLUSTER'"
  kind create cluster --name "$CLUSTER" --config ../kind-cluster.yaml
else
  echo ">> kind cluster '$CLUSTER' already exists"
fi
kubectl config use-context "kind-${CLUSTER}"

# 2. images -----------------------------------------------------------------
# The tutor's registry images are arm64-only. On an amd64 host, build the
# byte-for-byte-equivalent images from the provided build contexts and side-
# load them (skip this block entirely on arm64 / once amd64 images exist).
if [ "$(uname -m)" = "x86_64" ]; then
  echo ">> building images from provided Dockerfiles (amd64 host)"
  docker build -t sarojsanyasi/dso202-db:1.0       ../images/db
  docker build -t sarojsanyasi/dso202-backend:1.0  ../images/backend
  docker build -t sarojsanyasi/dso202-frontend:1.0 ../images/frontend
  echo ">> loading images into the cluster"
  kind load docker-image --name "$CLUSTER" "${IMAGES[@]}"
fi

# 3. apply ------------------------------------------------------------------
echo ">> applying manifests"
kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml -f secret.yaml -f quota.yaml
kubectl apply -f database/ -f backend/ -f frontend/

# 4. wait -----------------------------------------------------------------
echo ">> waiting for rollouts"
kubectl -n "$NS" rollout status deploy/db       --timeout=180s
kubectl -n "$NS" rollout status deploy/backend  --timeout=180s
kubectl -n "$NS" rollout status deploy/frontend --timeout=180s

echo
kubectl -n "$NS" get pods,svc,pvc
echo
echo ">> frontend:  http://localhost:30080     (NodePort 30080)"
echo ">> or:        kubectl -n $NS port-forward svc/frontend 8080:8080"
