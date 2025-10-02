#!/usr/bin/env bash
set -euo pipefail

NS="px-bench"
PVC_NAME="px-bench-results"
JOB_NAME="px-bench-results-cleanup"
MODE="all"   # all | local | cluster
LOCAL_RESULTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/results"
DRY_RUN="false"

usage() {
  cat >&2 <<USAGE
Usage: cleanup-results.sh [--namespace NS] [--pvc-name NAME] [--mode all|local|cluster] [--dry-run]

Modes:
  all      Delete local ./results and clean the cluster PVC (default)
  local    Delete local ./results only
  cluster  Clean files from the shared results PVC only

Examples:
  cleanup-results.sh --mode local
  cleanup-results.sh --mode cluster --namespace px-bench
  cleanup-results.sh --mode all --pvc-name px-bench-results
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2;;
    --pvc-name) PVC_NAME="$2"; shift 2;;
    --mode) MODE="$2"; shift 2;;
    --dry-run) DRY_RUN="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

kubectl_cmd() {
  if command -v oc >/dev/null 2>&1; then
    oc -n "$NS" "$@"
  else
    kubectl -n "$NS" "$@"
  fi
}

cleanup_local() {
  if [[ ! -d "$LOCAL_RESULTS_DIR" ]]; then
    echo "[local] No results dir at $LOCAL_RESULTS_DIR"
    return 0
  fi
  echo "[local] Removing $LOCAL_RESULTS_DIR/*"
  if [[ "$DRY_RUN" == "true" ]]; then
    find "$LOCAL_RESULTS_DIR" -mindepth 1 -maxdepth 1 -print
  else
    rm -rf "$LOCAL_RESULTS_DIR"/*
  fi
}

cleanup_cluster() {
  echo "[cluster] Creating cleanup Job $JOB_NAME in namespace $NS for PVC $PVC_NAME"
  local job_yaml
  job_yaml=$(cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NS}
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: px-bench
      containers:
      - name: cleaner
        image: alpine:3.20
        command: ["/bin/sh","-lc","set -euo pipefail; ls -al /results || true; rm -rf /results/*; echo '[cluster] Cleanup done';"]
        volumeMounts:
        - name: results
          mountPath: /results
      volumes:
      - name: results
        persistentVolumeClaim:
          claimName: ${PVC_NAME}
EOF
)

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[cluster] Dry run - would apply Job:" >&2
    echo "$job_yaml"
    return 0
  fi

  # Delete any previous job with same name to avoid immutable template errors
  kubectl_cmd delete job "$JOB_NAME" --ignore-not-found
  echo "$job_yaml" | kubectl_cmd apply -f -
  echo "[cluster] Waiting for job to complete ..."
  kubectl_cmd wait --for=condition=complete job/"$JOB_NAME" --timeout=10m || true
  echo "[cluster] Logs:"
  kubectl_cmd logs job/"$JOB_NAME" || true
}

case "$MODE" in
  all)
    cleanup_local
    cleanup_cluster
    ;;
  local)
    cleanup_local
    ;;
  cluster)
    cleanup_cluster
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    usage
    exit 1
    ;;
esac

echo "[done] Results cleanup ($MODE) finished."


