## PX Bench (OpenShift-ready)

Automated Portworx performance benchmarking toolkit for OpenShift. Runs fio baselines and Portworx-backed tests in single-pod or per-node modes, collects JSON/CSV, and ships a lightweight viewer.

References: [PX POC Performance guide](https://px-docs-poc.netlify.app/performance)

### Features

- Single-pod or per-node (label-selected) execution
- Time-based runs ("run for X hours") with cache drop (privileged)
- Baseline hostPath tests and Portworx StorageClass tests
- Results written to a shared RWX PVC, exported to CSV, simple HTML viewer
- Extensible to iometer/vdbench (see Notes)

### Quick start (OpenShift)

1) Create namespace and SA, bind SCCs (requires cluster-admin once):

```bash
oc apply -f manifests/namespace.yaml
oc apply -f manifests/serviceaccount.yaml
# privileged needed for cache drop; anyuid to let upstream image run
oc adm policy add-scc-to-user privileged -z px-bench -n px-bench
oc adm policy add-scc-to-user anyuid -z px-bench -n px-bench
```

2) Create shared results PVC (adjust storageClassName if needed for RWX):

```bash
oc apply -f manifests/results-pvc.yaml
```

3) Load fio job set:

```bash
oc apply -f manifests/configmap-fiojobs.yaml
```

4) Baseline hostPath test (ensure each target node has /data mounted on the same media type as PX):

```bash
# label the 3 Portworx nodes you want to target
oc label node <node1> <node2> <node3> px-bench=true
oc apply -f manifests/fio-baseline-pod.yaml
```

5) Run Portworx-backed tests:

```bash
# Prepare StorageClasses (edit as needed)
oc apply -f manifests/storageclasses.sample.yaml

# Generate and run for 2 hours on three nodes across 4 StorageClasses
scripts/run-fio-suite.sh \
  --namespace px-bench \
  --mode per-node \
  --hours 2 \
  --sc-list "fio-repl1 fio-repl1-encrypted fio-repl2 fio-repl2-encrypted"
```

6) Convert and view results locally:

```bash
# Pull all results locally
scripts/collect-results.sh --namespace px-bench --out ./results

# Convert JSON to CSV and make a small summary
scripts/process-results.py ./results

# Serve a tiny viewer on http://127.0.0.1:8080
scripts/serve_results.sh ./results
```

### Kubernetes-native operation

- Per-node DaemonSet with generic ephemeral PVCs (one PVC per pod):

```bash
oc apply -f manifests/fio-runner-daemonset-ephemeral.yaml
# Edit SC_NAME and storageClassName in the manifest to your target SC
```

- Recurring runs via CronJob:

```bash
oc apply -f manifests/fio-runner-cronjob.yaml
```

- In-cluster results processing and simple viewer:

```bash
oc apply -f manifests/results-processor-configmap.yaml
oc apply -f manifests/results-processor-job.yaml
oc apply -f manifests/viewer-deployment.yaml
# Access the Route shown by: oc get route -n px-bench
```

### Duration model and waiting guidance

- Env knobs:
  - `HOURS`: total wall-clock duration of the run loop per pod. The runner repeats the entire `fiocfg` suite until `HOURS` elapse.
  - `RUNTIME_PER_JOB`: optional per-fio-job runtime in seconds. When set, each job runs time-based (uses `--time_based --runtime=<sec>`). When empty, each job uses the size-based default from the config.
  - `SIZE`: override the fio size (e.g., `1GiB`, `10GiB`).
  - `KEEP_ALIVE`: if `true`, pod will sleep after finishing to keep logs/execs available (useful for DaemonSets).
  - `JOB_MODE`: when set to `per_section`, runs each fio section separately producing per-section outputs.
  - `JOBS`: optional comma-separated subset of sections to run (e.g., `4k-read,4k-write`). If empty and `JOB_MODE=per_section`, runs all sections found in the config.
  - `ITERATION_SLEEP_SECS`: optional pause between per-section executions (useful to reduce contention while sampling).
  - `RAMP_TIME`: per-job warm-up seconds to exclude initial transients (maps to `--ramp_time`).
  - `RANDREPEAT`: when true, makes random sequences repeatable (sets `--randrepeat=1`).
  - `CPUSET`: optional CPU core list for pinning via `taskset -c` (e.g., `2-5`).

- What runs during `HOURS`:
  - By default, the runner executes all jobs listed in `manifests/configmap-fiojobs.yaml` sequentially.
  - With `JOB_MODE=per_section`, each fio section is run as a separate command with its own JSON file. Set `JOBS` to restrict to specific sections.
  - One full pass is one iteration. Iterations repeat back-to-back until the elapsed time reaches `HOURS`.
  - Results paths:
    - Default: `/results/<SC_NAME>/<node>/<timestamp>.json`
    - Per-section: `/results/<SC_NAME>/<node>/<section>/<timestamp>.json`

- How long to wait:
  - Job (single pod):
    - Set `HOURS` and (optionally) `RUNTIME_PER_JOB`, then: `oc -n px-bench wait --for=condition=complete job/fio-runner --timeout=24h`.
    - Completion means the full `HOURS` window elapsed and the pod exited.
  - DaemonSet (per-node):
    - Set `HOURS` on the DS (e.g., `oc -n px-bench set env ds/fio-runner-ephemeral RUNTIME_PER_JOB=180 HOURS=2`).
    - Each pod runs for ~`HOURS` and exits (unless `KEEP_ALIVE=true`). There is no built-in "DS complete"; check pod phase:
      - `oc -n px-bench get pods -l app=fio` and wait until pods move to `Completed`.
      - Or follow logs; the runner prints `[runner] Done.` when finished.

- Collecting results after completion:
  - Local: `scripts/collect-results.sh --namespace px-bench --out ./results && scripts/process-results.py ./results`.
  - In-cluster: run `results-processor-job` and view via `results-viewer` Route.

### Per-node vs single-pod

- `--mode single`: one pod runs sequential tests
- `--mode per-node`: one pod per labeled node runs in parallel; results are kept per-node

Label nodes you want to use:

```bash
oc label node <name> px-bench=true --overwrite
```

### Alternatives

- Consider `vdbench` for additional workload profiles (license review required).

### Cleanup

```bash
oc delete ns px-bench
```

### Notes

### Example runbooks

1) Full suite, per-node, size-based (baseline default)

```bash
# Label target PX nodes
oc label node <node1> <node2> <node3> px-bench=true --overwrite

# Deploy DS with ephemeral per-pod PVCs
oc apply -f manifests/fio-runner-daemonset-ephemeral.yaml

# Set the target Portworx StorageClass and run for 2 hours size-based
oc -n px-bench set env ds/fio-runner-ephemeral SC_NAME=fio-repl2 SIZE=10GiB HOURS=2 JOB_MODE=per_section RANDREPEAT=true RAMP_TIME=30

# Wait until pods show Completed (or follow logs)
oc -n px-bench get pods -l app=fio

# Process and view (in-cluster)
oc apply -f manifests/results-processor-configmap.yaml
oc apply -f manifests/results-processor-job.yaml
oc apply -f manifests/viewer-deployment.yaml
oc -n px-bench get route results-viewer
```

2) POC comparison across 4 SCs, single pod per SC, time-based

```bash
oc apply -f manifests/fio-runner-job.yaml

# For each SC; runs 1 hour, 120s per job, per-section results
for sc in fio-repl1 fio-repl1-encrypted fio-repl2 fio-repl2-encrypted; do
  oc -n px-bench delete job fio-runner --ignore-not-found
  # Create PVC for this SC
  cat <<EOF | oc apply -f -
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: ${sc}-pvc
  namespace: px-bench
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: ${sc}
EOF
  oc -n px-bench set env job/fio-runner SC_NAME=${sc} HOURS=1 RUNTIME_PER_JOB=120 JOB_MODE=per_section RANDREPEAT=true RAMP_TIME=30
  # Attach the SC PVC by patching the job template
  oc -n px-bench patch job fio-runner --type json -p='[
    {"op":"replace","path":"/spec/template/spec/volumes/3/emptyDir","value":null},
    {"op":"add","path":"/spec/template/spec/volumes/3/persistentVolumeClaim","value":{"claimName":"'${sc}'-pvc"}}
  ]'
  oc -n px-bench wait --for=condition=complete job/fio-runner --timeout=24h || true
done

# Process and view locally
scripts/collect-results.sh --namespace px-bench --out ./results
scripts/process-results.py ./results
scripts/serve_results.sh ./results
```

3) Focused micro-benchmark: 4k random R/W, deterministic, 180s/job

```bash
oc -n px-bench set env ds/fio-runner-ephemeral JOB_MODE=per_section JOBS=4k-rand-read,4k-rand-write RUNTIME_PER_JOB=180 HOURS=2 RANDREPEAT=true RAMP_TIME=30 CPUSET=2-5 ITERATION_SLEEP_SECS=5
```

### Data collection and analysis guidance

- Directory layout:
  - Default: `/results/<SC>/<node>/<timestamp>.json`
  - Per-section: `/results/<SC>/<node>/<section>/<timestamp>.json`

- Merge/convert:
  - In-cluster: results processor writes `/results/summary.csv` and `/results/index.html` (served by viewer).
  - Local: `scripts/collect-results.sh` then `scripts/process-results.py ./results` creates `./results/summary.csv` and `./results/index.html`.

- Recommended comparisons:
  - Same SC, different nodes: quantify node variance.
  - Same node, different SCs (repl1 vs repl2, encrypted vs not): quantify replication/encryption impact.
  - Per-section across iterations: check last 2–3 iterations for <10% variance as steady-state.

- Suggested plots (in your spreadsheet/BI tool):
  - IOPS vs blocksize by workload (randread/randwrite/seq).
  - Latency (ms) CDF per workload using p50/p95/p99 columns now exported.
  - Bandwidth vs replication factor.

- Extra rigor (optional):
  - Pin CPUs (CPUSET) and set fixed pod limits/requests to reduce CPU noise.
  - Run with `RANDREPEAT=true` to ensure random streams are comparable across runs.
  - Use `RAMP_TIME` to exclude warm-up.
  - Repeat runs on separate days/time windows and average.

- OpenShift enforces non-root; SCC grants above are required because fio runners drop caches and need hostPath baseline.
- Ensure the results PVC uses Portworx RWX (e.g., sharedv4) StorageClass.


