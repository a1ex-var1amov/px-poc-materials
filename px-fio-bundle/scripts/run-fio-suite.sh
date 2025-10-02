#!/usr/bin/env bash
set -euo pipefail

NS=px-bench
MODE=single
HOURS=1
RUNTIME_PER_JOB=""
DURATION_SECONDS=""
SIZE=1GiB
SC_LIST="fio-repl1 fio-repl1-encrypted fio-repl2 fio-repl2-encrypted"
PVC_SIZE=5Gi
PARALLEL=1
JOB_MODE=""
JOB_FILTER=""
JOB_EXCLUDE=""
RANDREPEAT="false"
ITERATION_SLEEP_SECS=0
RAMP_TIME=0
PROFILES=""
RUN_TAG=""

usage() {
  cat >&2 <<'USAGE'
Usage: run-fio-suite.sh [--namespace NS] [--mode single|per-node] [--hours H] [--runtime-per-job SEC] [--size SIZE]
                        [--sc-list "SC1 SC2..."] [--sc SC] [--parallel N]
                        [--job-mode per_section|all_in_one] [--job-filter REGEX] [--job-exclude REGEX]
                        [--profiles reads,writes,random,sequential,all_in_one] [--randrepeat true|false] [--iter-sleep SEC] [--ramp-time SEC] [--duration-seconds SEC]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2;;
    --mode) MODE="$2"; shift 2;;
    --hours) HOURS="$2"; shift 2;;
    --runtime-per-job) RUNTIME_PER_JOB="$2"; shift 2;;
    --size) SIZE="$2"; shift 2;;
    --sc-list) SC_LIST="$2"; shift 2;;
    --sc) SC_LIST="$2"; shift 2;;
    --parallel) PARALLEL="$2"; shift 2;;
    --job-mode) JOB_MODE="$2"; shift 2;;
    --job-filter) JOB_FILTER="$2"; shift 2;;
    --job-exclude) JOB_EXCLUDE="$2"; shift 2;;
    --profiles) PROFILES="$2"; shift 2;;
    --randrepeat) RANDREPEAT="$2"; shift 2;;
    --iter-sleep) ITERATION_SLEEP_SECS="$2"; shift 2;;
    --ramp-time) RAMP_TIME="$2"; shift 2;;
    --duration-seconds) DURATION_SECONDS="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

kubectl_cmd() {
  if command -v oc >/dev/null 2>&1; then
    oc -n "$NS" "$@"
  else
    kubectl -n "$NS" "$@"
  fi
}

apply_ns() {
  if command -v oc >/dev/null 2>&1; then
    oc apply -f manifests/namespace.yaml
  else
    kubectl apply -f manifests/namespace.yaml
  fi
}

apply_basics() {
  kubectl_cmd apply -f manifests/serviceaccount.yaml
  kubectl_cmd apply -f manifests/results-pvc.yaml
  kubectl_cmd apply -f manifests/configmap-fiojobs.yaml
  kubectl_cmd apply -f manifests/configmap-runner.yaml
}

run_for_sc() {
  local sc="$1"
  local duration_msg
  if [[ -n "${DURATION_SECONDS}" ]]; then
    duration_msg="${DURATION_SECONDS}s"
  else
    duration_msg="${HOURS}h"
  fi
  # Generate RUN_TAG if not set: parallel-X-<filter-or-profile>-<timestamp>
  if [[ -z "${RUN_TAG}" ]]; then
    local tag_ts
    tag_ts=$(date -u +%Y%m%dT%H%M%SZ)
    local tag_filter
    if [[ -n "${PROFILES}" ]]; then
      tag_filter="${PROFILES}"
    elif [[ -n "${JOB_FILTER}" ]]; then
      tag_filter="${JOB_FILTER}"
    else
      tag_filter="all"
    fi
    # sanitize for filesystem
    tag_filter=$(echo "$tag_filter" | tr -cd 'a-zA-Z0-9._-')
    RUN_TAG="parallel-${PARALLEL}-${tag_filter}-${tag_ts}"
  fi

  echo "Running fio for StorageClass=${sc} mode=${MODE} duration=${duration_msg} tag=${RUN_TAG}"

  # Create a PVC+Pod template on the fly from the job/daemonset by overriding env and volume
  if [[ "$MODE" == "single" ]]; then
    kubectl_cmd delete job fio-runner --ignore-not-found
    if [[ "${PARALLEL}" -gt 1 ]]; then
      # Parallel run: use per-pod ephemeral PVCs bound to the StorageClass
      # Build Job with ephemeral volume, parallelism and env overrides
      job_yaml=$(cat manifests/fio-runner-job.yaml \
        | sed -e "s/value: \"single\"/value: \"${sc}\"/" \
        | sed -e "s/name: HOURS\n          value: \"1\"/name: HOURS\n          value: \"${HOURS}\"/" \
        | sed -e "s/emptyDir: {}/ephemeral:\n          volumeClaimTemplate:\n            spec:\n              accessModes: [\"ReadWriteOnce\"]\n              resources:\n                requests:\n                  storage: ${PVC_SIZE}\n              storageClassName: ${sc}/")

      # Set parallelism/completions if yq exists; otherwise inject with awk. Then set env locally and apply.
      if command -v yq >/dev/null 2>&1; then
        echo "$job_yaml" \
          | yq e ".metadata.name=\"fio-runner\" | .spec.parallelism=${PARALLEL} | .spec.completions=${PARALLEL}" - \
          | kubectl_cmd set env -f - --local -o yaml \
              SC_NAME="${sc}" SIZE="${SIZE}" \
              JOB_MODE="${JOB_MODE}" JOB_FILTER="${JOB_FILTER}" JOB_EXCLUDE="${JOB_EXCLUDE}" \
              RUNTIME_PER_JOB="${RUNTIME_PER_JOB}" RUNTIME_PRE_JOB="${RUNTIME_PER_JOB}" \
              HOURS="${HOURS}" DURATION_SECONDS="${DURATION_SECONDS}" RUN_TAG="${RUN_TAG}" RANDREPEAT="${RANDREPEAT}" ITERATION_SLEEP_SECS="${ITERATION_SLEEP_SECS}" RAMP_TIME="${RAMP_TIME}" \
          | kubectl_cmd apply -f -
      else
        echo "$job_yaml" \
          | awk -v p="${PARALLEL}" 'BEGIN{ins=0} {print; if(!ins && $0 ~ /^spec:$/){print "  parallelism: " p; print "  completions: " p; ins=1}}' \
          | kubectl_cmd set env -f - --local -o yaml \
              SC_NAME="${sc}" SIZE="${SIZE}" \
              JOB_MODE="${JOB_MODE}" JOB_FILTER="${JOB_FILTER}" JOB_EXCLUDE="${JOB_EXCLUDE}" \
              RUNTIME_PER_JOB="${RUNTIME_PER_JOB}" RUNTIME_PRE_JOB="${RUNTIME_PER_JOB}" \
              HOURS="${HOURS}" DURATION_SECONDS="${DURATION_SECONDS}" RUN_TAG="${RUN_TAG}" RANDREPEAT="${RANDREPEAT}" ITERATION_SLEEP_SECS="${ITERATION_SLEEP_SECS}" RAMP_TIME="${RAMP_TIME}" \
          | kubectl_cmd apply -f -
      fi
    else
      # Single-pod run using a dedicated PVC
      cat manifests/fio-runner-job.yaml \
        | sed -e "s/name: test-volume/name: test-volume\n        persistentVolumeClaim:\n          claimName: ${sc}-pvc/" \
        | sed -e "s/value: \"single\"/value: \"${sc}\"/" \
        | sed -e "s/name: HOURS\n          value: \"1\"/name: HOURS\n          value: \"${HOURS}\"/" \
        | kubectl_cmd set env -f - --local -o yaml \
            SC_NAME="${sc}" SIZE="${SIZE}" \
            JOB_MODE="${JOB_MODE}" JOB_FILTER="${JOB_FILTER}" JOB_EXCLUDE="${JOB_EXCLUDE}" \
            RUNTIME_PER_JOB="${RUNTIME_PER_JOB}" RUNTIME_PRE_JOB="${RUNTIME_PER_JOB}" \
            HOURS="${HOURS}" DURATION_SECONDS="${DURATION_SECONDS}" RUN_TAG="${RUN_TAG}" RANDREPEAT="${RANDREPEAT}" ITERATION_SLEEP_SECS="${ITERATION_SLEEP_SECS}" RAMP_TIME="${RAMP_TIME}" \
        | kubectl_cmd apply -f -

      # PVC and pod for the storage class
      cat <<EOF | kubectl_cmd apply -f -
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: ${sc}-pvc
  namespace: ${NS}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: ${PVC_SIZE}
  storageClassName: ${sc}
EOF
    fi

    kubectl_cmd wait --for=condition=complete job/fio-runner --timeout=24h || true
  else
    # Per-node: one Job per labeled node, each with its own PVC, pinned via nodeName
    local nodes
    nodes=$(kubectl get nodes -l px-bench=true -o jsonpath='{.items[*].metadata.name}')
    if [[ -z "$nodes" ]]; then
      echo "No nodes labeled px-bench=true. Label target nodes first." >&2
      exit 1
    fi
    for node in $nodes; do
      # sanitize suffix
      local suffix
      suffix=$(echo "$node" | tr -cd 'a-z0-9-' | cut -c1-20)
      local pvc_name="${sc}-pvc-${suffix}"
      local job_name="fio-runner-${suffix}"

      kubectl_cmd delete job "$job_name" --ignore-not-found

      # PVC per node
      cat <<EOF | kubectl_cmd apply -f -
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: ${pvc_name}
  namespace: ${NS}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: ${PVC_SIZE}
  storageClassName: ${sc}
EOF

      # Job pinned to the node with its PVC
      cat manifests/fio-runner-job.yaml \
        | sed -e "s/name: fio-runner/name: ${job_name}/" \
        | sed -e "s/restartPolicy: Never/restartPolicy: Never\n      nodeName: ${node}/" \
        | sed -e "s/name: test-volume/name: test-volume\n        persistentVolumeClaim:\n          claimName: ${pvc_name}/" \
        | sed -e "s/value: \"single\"/value: \"${sc}\"/" \
        | sed -e "s/name: HOURS\n          value: \"1\"/name: HOURS\n          value: \"${HOURS}\"/" \
        | kubectl_cmd set env -f - --local -o yaml \
            SC_NAME="${sc}" SIZE="${SIZE}" \
            JOB_MODE="${JOB_MODE}" JOB_FILTER="${JOB_FILTER}" JOB_EXCLUDE="${JOB_EXCLUDE}" \
            RUNTIME_PER_JOB="${RUNTIME_PER_JOB}" RUNTIME_PRE_JOB="${RUNTIME_PER_JOB}" \
            HOURS="${HOURS}" DURATION_SECONDS="${DURATION_SECONDS}" RUN_TAG="${RUN_TAG}" RANDREPEAT="${RANDREPEAT}" ITERATION_SLEEP_SECS="${ITERATION_SLEEP_SECS}" RAMP_TIME="${RAMP_TIME}" \
        | kubectl_cmd apply -f -

      kubectl_cmd wait --for=condition=complete job/${job_name} --timeout=24h || true
    done
  fi
}

# Profiles helper: sets JOB_MODE / JOB_FILTER / JOB_EXCLUDE based on a profile name
set_profile() {
  local profile="$1"
  case "$profile" in
    reads)
      JOB_MODE="per_section"
      JOB_FILTER='read$'
      JOB_EXCLUDE='(randrw|mix)'
      ;;
    writes)
      JOB_MODE="per_section"
      JOB_FILTER='write$'
      JOB_EXCLUDE='rand|mix'
      ;;
    random)
      JOB_MODE="per_section"
      JOB_FILTER='rand-(read|write)$'
      JOB_EXCLUDE='mix'
      ;;
    sequential)
      JOB_MODE="per_section"
      JOB_FILTER='(read|write)$'
      JOB_EXCLUDE='rand|mix'
      ;;
    all_in_one)
      JOB_MODE="all_in_one"
      JOB_FILTER=''
      JOB_EXCLUDE=''
      ;;
    *)
      echo "Unknown profile: $profile" >&2
      exit 1
      ;;
  esac
}

apply_ns
apply_basics

for sc in ${SC_LIST}; do
  if [[ -n "${PROFILES}" ]]; then
    IFS=',' read -r -a prof_arr <<< "${PROFILES}"
    for prof in "${prof_arr[@]}"; do
      set_profile "$prof"
      printf "\n=== SC=%s profile=%s ===\n" "$sc" "$prof"
      run_for_sc "$sc"
    done
  else
    run_for_sc "$sc"
  fi
done

echo "All requested runs submitted."

