## PX Bench Test Plan (OpenShift)

This plan provides ordered runbooks, exact commands, and comparison guidance to benchmark Portworx performance. It expands on the baseline fio methodology described in the Portworx POC Performance guide: https://px-docs-poc.netlify.app/performance

### Prerequisites

```bash
oc apply -f manifests/namespace.yaml
oc apply -f manifests/serviceaccount.yaml
oc adm policy add-scc-to-user privileged -z px-bench -n px-bench
oc adm policy add-scc-to-user anyuid -z px-bench -n px-bench
oc apply -f manifests/results-pvc.yaml
oc apply -f manifests/configmap-fiojobs.yaml
oc apply -f manifests/configmap-runner.yaml
```

Optional: sample PX StorageClasses (edit as needed)

```bash
oc apply -f manifests/storageclasses.sample.yaml
```

Label three Portworx worker nodes you plan to test on:

```bash
oc label node <node1> <node2> <node3> px-bench=true --overwrite
```

### Runbook 1: Smoke + Wiring (10–20 min)

Purpose: Confirm PX path, SCCs, result writeout.

```bash
oc apply -f manifests/fio-runner-daemonset-ephemeral.yaml
oc -n px-bench set env ds/fio-runner-ephemeral JOB_MODE=per_section JOBS=4k-read,4k-write RUNTIME_PER_JOB=60 HOURS=0.5 RANDREPEAT=true
oc -n px-bench get pods -l app=fio
```

Completion: wait until pods show Completed or check logs for "[runner] Done.".

### Runbook 2: HostPath Baseline (30–60 min)

Purpose: Baseline the underlying media on the same disks PX uses.

Ensure that each target node mounts the same media at /data. Then:

```bash
oc apply -f manifests/fio-baseline-pod.yaml
oc -n px-bench exec -it fio-baseline -- fio --output-format=json /fiocfg/fiojobs.fio > fio-baseline.json
```

### Runbook 3: POC Comparison Across 4 SCs (1 hour)

Purpose: Compare repl1 vs repl2 and encrypted vs unencrypted.

Settings: per-section; time-based runs with warm-up.

```bash
oc apply -f manifests/fio-runner-job.yaml

for sc in fio-repl1 fio-repl1-encrypted fio-repl2 fio-repl2-encrypted; do
  oc -n px-bench delete job fio-runner --ignore-not-found
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
  # Attach the SC PVC to /data by replacing emptyDir with PVC in the job spec
  oc -n px-bench patch job fio-runner --type json -p='[
    {"op":"replace","path":"/spec/template/spec/volumes/3/emptyDir","value":null},
    {"op":"add","path":"/spec/template/spec/volumes/3/persistentVolumeClaim","value":{"claimName":"'${sc}'-pvc"}}
  ]'
  oc -n px-bench wait --for=condition=complete job/fio-runner --timeout=24h || true
done
```

### Runbook 4: Steady-State Deep Dive (2–4 hours)

Purpose: Stable characterization on representative mixes.

```bash
oc -n px-bench set env ds/fio-runner-ephemeral JOB_MODE=per_section \
  JOBS=4k-rand-read,4k-rand-write,64k-read,64k-write \
  RUNTIME_PER_JOB=300 HOURS=3 RAMP_TIME=30 RANDREPEAT=true CPUSET=2-5 SIZE=10GiB
```

Completion: wait for DS pods to reach Completed; or set KEEP_ALIVE=true to keep pods running for inspection.

### Runbook 5: Per-Node Variance (≥2 hours)

Purpose: Measure node-to-node differences across the 3 labeled hosts.

```bash
oc -n px-bench set env ds/fio-runner-ephemeral JOB_MODE=per_section \
  JOBS=4k-rand-read,4k-rand-write RUNTIME_PER_JOB=180 HOURS=2 RANDREPEAT=true RAMP_TIME=30
```

### Runbook 6: Encryption Impact (1–2 hours)

Purpose: Quantify secure=true overhead vs unencrypted.

Re-run Runbook 3 or 4 swapping SCs to their encrypted variants with identical env settings.

### Runbook 7: Replication/HA Behavior (1–2 hours + event)

Purpose: Verify repl2 resilience during a node event.

```bash
oc -n px-bench set env ds/fio-runner-ephemeral JOB_MODE=per_section JOBS=4k-rand-write \
  RUNTIME_PER_JOB=300 HOURS=2 RAMP_TIME=30 RANDREPEAT=true
# During the run, drain or cordon a replica node and observe latency spike & recovery
```

### Runbook 8: Bandwidth Profile (45–90 min)

Purpose: Large-block sequential throughput.

```bash
oc -n px-bench set env ds/fio-runner-ephemeral JOB_MODE=per_section JOBS=256k-read,256k-write \
  SIZE=20GiB RUNTIME_PER_JOB=180 HOURS=1 RAMP_TIME=30
```

### Results Collection

In-cluster (recommended):

```bash
oc apply -f manifests/results-processor-configmap.yaml
oc apply -f manifests/results-processor-job.yaml
oc apply -f manifests/viewer-deployment.yaml
oc -n px-bench get route results-viewer
# Open the Route; /results/index.html and /results/summary.csv are served from the PVC
```

Local collection (optional):

```bash
scripts/collect-results.sh --namespace px-bench --out ./results
scripts/process-results.py ./results
scripts/serve_results.sh ./results
```

### What You Get

- Raw JSONs per section/iteration: `/results/<SC>/<node>/<section>/<timestamp>.json`
- Consolidated CSV + simple viewer in the results PVC:
  - `/results/summary.csv`
  - `/results/index.html`

Columns in `summary.csv` include:

- storage_class, node, file, jobname, groupid
- read_iops, write_iops
- read_lat_ms, write_lat_ms (means)
- read_bw_kib, write_bw_kib
- read_p50_ms, read_p95_ms, read_p99_ms
- write_p50_ms, write_p95_ms, write_p99_ms

### Comparison Checklist

- Same node, different SCs: replication and encryption impact
- Same SC, different nodes: node variance
- Per-section across iterations: steady-state when last 2–3 iterations <10% variance
- Block-size trends: IOPS (4k), bandwidth (64k/256k)

### Advanced Controls (env vars)

- HOURS: wall-clock run duration; loop repeats until elapsed
- RUNTIME_PER_JOB: per-job time in seconds (time-based mode)
- SIZE: working set size (e.g., 1GiB, 10GiB, 20GiB)
- JOB_MODE=per_section & JOBS=comma list to isolate workloads
- RAMP_TIME: warm-up seconds excluded from metrics
- RANDREPEAT=true: deterministic random streams
- CPUSET=2-5: pin to CPU cores via taskset
- ITERATION_SLEEP_SECS: pause between per-section runs
- PERCENTILES: list for fio `--percentile_list` (default 50:95:99)

### Notes

- Ensure PX PVCs are used: check PV provisioner and in-pod mount shows `/dev/pxd*`.
- For per-node ephemeral DS: update the embedded `storageClassName` in `manifests/fio-runner-daemonset-ephemeral.yaml` or patch it via JSON:

```bash
oc -n px-bench patch ds fio-runner-ephemeral --type json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/3/ephemeral/volumeClaimTemplate/spec/storageClassName","value":"fio-repl2"}]'
oc -n px-bench set env ds/fio-runner-ephemeral SC_NAME=fio-repl2
```


