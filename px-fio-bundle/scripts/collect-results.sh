#!/usr/bin/env bash
set -euo pipefail

NS=px-bench
OUT=./results

usage(){ echo "Usage: $0 [--namespace NS] [--out DIR]"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg $1"; usage; exit 1;;
  esac
done

mkdir -p "$OUT"

# Start a temp helper pod to rsync results PVC
cat <<EOF | kubectl -n "$NS" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: px-results-copy
spec:
  restartPolicy: Never
  containers:
  - name: copy
    image: alpine:3.20
    command: ["/bin/sh","-lc","sleep 3600"]
    volumeMounts:
    - name: results
      mountPath: /results
  volumes:
  - name: results
    persistentVolumeClaim:
      claimName: px-bench-results
EOF

kubectl -n "$NS" wait --for=condition=ready pod/px-results-copy --timeout=2m
kubectl -n "$NS" cp px-results-copy:/results "$OUT"
kubectl -n "$NS" delete pod px-results-copy --ignore-not-found

echo "Results copied to $OUT/results"

