#!/usr/bin/env bash
# DSO202 Assignment 1 -- Task 7 verification / evidence capture.
# Run against a deployed cluster (see scripts/deploy.sh first).
# Writes a transcript to evidence/task7-transcript.txt and also prints it.
set -uo pipefail

NS=dso202-assignment-01
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EV_DIR="$ROOT/evidence"
mkdir -p "$EV_DIR"

hr()  { printf '\n============================================================\n%s\n============================================================\n' "$1"; }
kn()  { kubectl -n "$NS" "$@"; }

BE=http://localhost:18080
PF_PID=""

start_pf() {                       # (re)start the backend port-forward, wait until it answers
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  local i
  for i in $(seq 1 20); do
    kn port-forward svc/backend 18080:8080 >/tmp/pf-backend.log 2>&1 &
    PF_PID=$!
    for _ in $(seq 1 10); do
      curl -sf "$BE/api/status" >/dev/null 2>&1 && return 0
      sleep 0.5
    done
    kill "$PF_PID" 2>/dev/null
  done
  echo "!! backend port-forward never came up" >&2
  return 1
}

# in-cluster curl: exec inside the frontend Pod, hit the backend Service by name.
# Used where Pod churn would break a port-forward. Retries while the new Pod / DB
# connection settles.
FEPOD() { kn get pod -l tier=frontend -o jsonpath='{.items[0].metadata.name}'; }
incurl() {
  local i out
  for i in $(seq 1 20); do
    out=$(kn exec "$(FEPOD)" -- curl -s "$@" 2>/dev/null)
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    sleep 1
  done
  printf '%s' "$out"
}

start_pf || exit 1
trap 'kill $PF_PID 2>/dev/null' EXIT

{
hr "CONTEXT: cluster / namespace / objects"
kubectl config current-context
kn get all,pvc,configmap,secret,resourcequota,limitrange -o wide
kn get pods --show-labels

hr "TASK 7b: Service DNS resolution from inside the frontend Pod"
FE=$(FEPOD)
echo "# exec target: $FE"
echo "\$ nslookup backend.${NS}.svc.cluster.local"
kn exec "$FE" -- nslookup "backend.${NS}.svc.cluster.local"
echo
echo "\$ curl -s http://backend:8080/api/status      # backend Service reached BY NAME"
kn exec "$FE" -- curl -s http://backend:8080/api/status
echo
echo "\$ nslookup db      # headless Service resolves straight to the Pod IP (no cluster IP)"
kn exec "$FE" -- nslookup db

hr "TASK 7a: Full CRUD cycle (curl through the port-forwarded backend)"
echo "\$ curl -s $BE/api/tasks                        # READ list (seed rows 1-3)"
curl -s "$BE/api/tasks"; echo
echo
echo "\$ curl -s -XPOST $BE/api/tasks -d '{\"title\":\"CRUD demo\",\"description\":\"created by verify.sh\"}'   # CREATE"
CREATED=$(curl -s -XPOST "$BE/api/tasks" -H 'Content-Type: application/json' -d '{"title":"CRUD demo","description":"created by verify.sh"}')
echo "$CREATED"
ID=$(printf '%s' "$CREATED" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
echo "# new task id = $ID"
echo
echo "\$ curl -s $BE/api/tasks/$ID                     # READ one"
curl -s "$BE/api/tasks/$ID"; echo
echo
echo "\$ curl -s -XPUT $BE/api/tasks/$ID -d '{\"status\":\"done\"}'   # UPDATE"
curl -s -XPUT "$BE/api/tasks/$ID" -H 'Content-Type: application/json' -d '{"status":"done"}'; echo
echo
echo "\$ curl -s -o /dev/null -w '%{http_code}' -XDELETE $BE/api/tasks/$ID   # DELETE -> expect 204"
curl -s -o /dev/null -w '%{http_code}\n' -XDELETE "$BE/api/tasks/$ID"
echo "\$ curl -s -o /dev/null -w '%{http_code}' $BE/api/tasks/$ID            # READ deleted -> expect 404"
curl -s -o /dev/null -w '%{http_code}\n' "$BE/api/tasks/$ID"

hr "TASK 7c: Self-healing + data persistence"
echo "\$ curl -s -XPOST $BE/api/tasks -d '{\"title\":\"persist-marker\"}'   # create BEFORE the Pod delete"
MARK=$(curl -s -XPOST "$BE/api/tasks" -H 'Content-Type: application/json' -d '{"title":"persist-marker","description":"must survive a backend Pod delete"}')
echo "$MARK"
MID=$(printf '%s' "$MARK" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
OLD_POD=$(kn get pod -l tier=backend -o jsonpath='{.items[0].metadata.name}')
echo
echo "# backend Pod before: $OLD_POD"
echo "\$ kubectl -n $NS delete pod $OLD_POD"
kn delete pod "$OLD_POD"
echo
echo "\$ kubectl -n $NS get pods -l tier=backend --watch     (ReplicaSet recreates it)"
timeout 15 kubectl -n "$NS" get pods -l tier=backend --watch
echo
kn rollout status deploy/backend --timeout=90s
NEW_POD=$(kn get pod -l tier=backend -o jsonpath='{.items[0].metadata.name}')
echo "# backend Pod after:  $NEW_POD   (new name => a NEW Pod from the same ReplicaSet)"
echo
echo "\$ kubectl -n $NS exec <frontend> -- curl -s http://backend:8080/api/tasks/$MID"
echo "  # task $MID is STILL THERE -> the PersistentVolume outlived the deleted Pod"
incurl "http://backend:8080/api/tasks/$MID"; echo
echo
echo "# --- stronger check: delete the DATABASE Pod; PVC/PV stay bound ---"
DB_OLD=$(kn get pod -l tier=database -o jsonpath='{.items[0].metadata.name}')
echo "\$ kubectl -n $NS delete pod $DB_OLD"
kn delete pod "$DB_OLD"
kn rollout status deploy/db --timeout=120s
echo "\$ kubectl -n $NS get pvc db-data      # still Bound to the SAME PV"
kn get pvc db-data
echo
echo "\$ kubectl -n $NS exec <frontend> -- curl -s http://backend:8080/api/tasks/$MID"
echo "  # task $MID survived a DB Pod restart too -- data lives on the PV, not the Pod"
incurl "http://backend:8080/api/tasks/$MID"; echo
echo
echo "# cleanup marker"
incurl -o /dev/null -w 'delete marker -> %{http_code}\n' -XDELETE "http://backend:8080/api/tasks/$MID"

hr "TASK 7d: Declarative vs imperative (backend Service)"
echo "# Declarative -- the committed manifest (idempotent, reports 'unchanged'):"
echo "\$ kubectl apply -f backend/service.yaml"
kubectl apply -f "$ROOT/backend/service.yaml"
echo
echo "# Imperative -- the equivalent one-off commands (create a second, throwaway Service):"
echo "\$ kubectl -n $NS create service clusterip backend-imperative --tcp=8080:8080"
kn create service clusterip backend-imperative --tcp=8080:8080
echo "\$ kubectl -n $NS set selector service backend-imperative 'app=task-tracker,tier=backend'"
kn set selector service backend-imperative 'app=task-tracker,tier=backend'
kn label service backend-imperative app=task-tracker tier=backend --overwrite >/dev/null
echo
echo "\$ kubectl -n $NS get svc backend backend-imperative -o wide      # equivalent result"
kn get svc backend backend-imperative -o wide
echo
echo "# tidy up the imperative one -- the declarative Service is the real, tracked object"
kn delete service backend-imperative

hr "DONE"
} 2>&1 | tee "$EV_DIR/task7-transcript.txt"
