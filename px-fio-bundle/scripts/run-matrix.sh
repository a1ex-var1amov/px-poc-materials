#!/usr/bin/env bash
set -euo pipefail

# Orchestrate a full matrix:
# - Profiles: reads, writes, random, sequential (default)
# - Parallelism: 3,6,9,12,15 (default)
# - StorageClasses: 4 default SCs (override with --sc-list)

NS="px-bench"
SC_LIST="fio-repl1 fio-repl1-encrypted fio-repl2 fio-repl2-encrypted"
PARALLEL_COUNTS="3 6 9 12 15"
PROFILES="reads,writes,random,sequential"
MODE="single"
HOURS="1"
DURATION_SECONDS=""
PROFILE_DURATION_SECONDS=""
PROFILE_GAP_SECONDS="120"
LEVEL_GAP_SECONDS="300"
RESUME_FILE=""
SIZE="1GiB"
RANDREPEAT="false"
ITERATION_SLEEP_SECS="0"
RAMP_TIME="0"

usage() {
  cat >&2 <<USAGE
Usage: run-matrix.sh [--namespace NS] [--sc-list "SC1 SC2 ..."] \
                     [--parallel-counts "3 6 9 12 15" | --parallel-min 3 --parallel-max 15 --parallel-step 3] \
                     [--profiles reads,writes,random,sequential] \
                     [--mode single|per-node] [--hours H | --duration-seconds SEC] \
                     [--size SIZE] [--randrepeat true|false] [--iter-sleep SEC] [--ramp-time SEC] \
                     [--profile-duration-seconds SEC] [--profile-gap-seconds SEC] [--level-gap-seconds SEC] \
                     [--resume-file PATH]
USAGE
}

PAR_MIN=""; PAR_MAX=""; PAR_STEP="";
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2;;
    --sc-list) SC_LIST="$2"; shift 2;;
    --parallel-counts) PARALLEL_COUNTS=$(echo "$2" | tr ',' ' '); shift 2;;
    --parallel-min) PAR_MIN="$2"; shift 2;;
    --parallel-max) PAR_MAX="$2"; shift 2;;
    --parallel-step) PAR_STEP="$2"; shift 2;;
    --profiles) PROFILES="$2"; shift 2;;
    --mode) MODE="$2"; shift 2;;
    --hours) HOURS="$2"; shift 2;;
    --duration-seconds) DURATION_SECONDS="$2"; shift 2;;
    --profile-duration-seconds) PROFILE_DURATION_SECONDS="$2"; shift 2;;
    --profile-gap-seconds) PROFILE_GAP_SECONDS="$2"; shift 2;;
    --level-gap-seconds) LEVEL_GAP_SECONDS="$2"; shift 2;;
    --size) SIZE="$2"; shift 2;;
    --randrepeat) RANDREPEAT="$2"; shift 2;;
    --iter-sleep) ITERATION_SLEEP_SECS="$2"; shift 2;;
    --ramp-time) RAMP_TIME="$2"; shift 2;;
    --resume-file) RESUME_FILE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -n "$PAR_MIN$PAR_MAX$PAR_STEP" ]]; then
  if [[ -z "$PAR_MIN" || -z "$PAR_MAX" || -z "$PAR_STEP" ]]; then
    echo "When using --parallel-{{min,max,step}}, all three must be provided" >&2
    exit 1
  fi
  PARALLEL_COUNTS=""
  i=$PAR_MIN
  while [[ $i -le $PAR_MAX ]]; do
    PARALLEL_COUNTS+="$i "
    i=$(( i + PAR_STEP ))
  done
fi

# Ensure namespace and basics exist (delegates to suite script)
suite() {
  "/Users/alvarlamov/workdir/px-bench/scripts/run-fio-suite.sh" "$@"
}

echo "[matrix] Namespace: $NS"
echo "[matrix] SCs: $SC_LIST"
echo "[matrix] Profiles: $PROFILES"
echo "[matrix] Parallel counts: $PARALLEL_COUNTS"
echo "[matrix] Mode: $MODE; Hours: $HOURS; DurationSeconds: ${DURATION_SECONDS:-}"
if [[ -n "$RESUME_FILE" ]]; then
  echo "[matrix] Resume file: $RESUME_FILE"
  touch "$RESUME_FILE"
fi

for sc in $SC_LIST; do
  for p in $PARALLEL_COUNTS; do
    IFS=',' read -r -a prof_arr <<< "$PROFILES"
    for prof in "${prof_arr[@]}"; do
      echo "\n[matrix] SC=$sc parallel=$p profile=$prof"
      key="$sc|$p|$prof"
      if [[ -n "$RESUME_FILE" ]] && grep -Fqx "$key" "$RESUME_FILE"; then
        echo "[matrix] Skipping (already completed): $key"
        continue
      fi
      # Build common args
      args=( --sc "$sc" --mode "$MODE" --parallel "$p" --profiles "$prof" --size "$SIZE" \
             --randrepeat "$RANDREPEAT" --iter-sleep "$ITERATION_SLEEP_SECS" --ramp-time "$RAMP_TIME" )
      if [[ -n "$PROFILE_DURATION_SECONDS" ]]; then
        args+=( --duration-seconds "$PROFILE_DURATION_SECONDS" )
      elif [[ -n "$DURATION_SECONDS" ]]; then
        args+=( --duration-seconds "$DURATION_SECONDS" )
      else
        args+=( --hours "$HOURS" )
      fi
      suite "${args[@]}"
      if [[ -n "$RESUME_FILE" ]]; then
        echo "$key" >> "$RESUME_FILE"
      fi
      echo "[matrix] Sleeping ${PROFILE_GAP_SECONDS}s between profiles ..."
      sleep "$PROFILE_GAP_SECONDS"
    done
    echo "[matrix] Sleeping ${LEVEL_GAP_SECONDS}s before next parallel level ..."
    sleep "$LEVEL_GAP_SECONDS"
  done
done

echo "[matrix] Collecting results to ./results ..."
"/Users/alvarlamov/workdir/px-bench/scripts/collect-results.sh" --namespace "$NS" --out "/Users/alvarlamov/workdir/px-bench"
echo "[matrix] Done. See ./results/"