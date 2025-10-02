## px-bench run examples

The commands below assume you are using the Deployment `fio-runner-ephemeral` in namespace `px-bench` and want to run per-section jobs from `fiocfg/fiojobs.fio`.

Notes:
- JOB_MODE=per_section makes the runner iterate sections one-by-one in separate fio invocations.
- Use JOB_FILTER (regex) to include sections; use JOB_EXCLUDE (regex) to exclude.
- RUNTIME_PRE_JOB sets per-section duration (seconds). HOURS sets how long the runner keeps iterating.
- After changing env vars, restart the Deployment to pick up changes.

Base env you can reuse (optional):
```bash
oc -n px-bench set env deploy/fio-runner-ephemeral \
  MODE=per-node JOB_MODE=per_section \
  RUNTIME_PRE_JOB=60 HOURS=1 RANDREPEAT=true ITERATION_SLEEP_SECS=0
```

Restart after changes:
```bash
oc -n px-bench rollout restart deploy/fio-runner-ephemeral
```

### Only reads
Include read-only sections (sequential and random), exclude mixed randrw sections.
```bash
oc -n px-bench set env deploy/fio-runner-ephemeral \
  JOB_FILTER='read$' JOB_EXCLUDE='(randrw|mix)'
oc -n px-bench rollout restart deploy/fio-runner-ephemeral
```

### Only writes
Include write-only sections (sequential), exclude random and mixed.
```bash
oc -n px-bench set env deploy/fio-runner-ephemeral \
  JOB_FILTER='write$' JOB_EXCLUDE='rand|mix'
oc -n px-bench rollout restart deploy/fio-runner-ephemeral
```

If you want all write flavors (sequential and random writes) but not mixed:
```bash
oc -n px-bench set env deploy/fio-runner-ephemeral \
  JOB_FILTER='(write$|rand-write$)' JOB_EXCLUDE='mix'
oc -n px-bench rollout restart deploy/fio-runner-ephemeral
```

### Only random (no sequential)
Include random read/write sections, exclude sequential and mixed (adjust to include mix if desired).
```bash
oc -n px-bench set env deploy/fio-runner-ephemeral \
  JOB_FILTER='rand-(read|write)$' JOB_EXCLUDE='mix'
oc -n px-bench rollout restart deploy/fio-runner-ephemeral
```

To include mixed random (randrw) as well:
```bash
oc -n px-bench set env deploy/fio-runner-ephemeral \
  JOB_FILTER='rand' JOB_EXCLUDE=''
oc -n px-bench rollout restart deploy/fio-runner-ephemeral
```

### Only sequential
Include sequential read/write sections; exclude any section containing "rand" or "mix".
```bash
oc -n px-bench set env deploy/fio-runner-ephemeral \
  JOB_FILTER='(read|write)$' JOB_EXCLUDE='rand|mix'
oc -n px-bench rollout restart deploy/fio-runner-ephemeral
```

### Bonus: all tests in one run
Run the full `fiojobs.fio` in a single fio invocation per iteration.
```bash
oc -n px-bench set env deploy/fio-runner-ephemeral \
  JOB_MODE=all_in_one JOBS- JOB_FILTER- JOB_EXCLUDE- RUNTIME_PRE_JOB-
oc -n px-bench rollout restart deploy/fio-runner-ephemeral
```

Tip: The provided fio config uses `[global]` stonewall, so sections execute sequentially within a single run. To execute sections truly concurrently, you would need a different fio config (e.g., remove stonewall, set `group_reporting`, and/or use `numjobs`).

### DaemonSet variant (if you use the DaemonSet instead of Deployment)
Replace `deploy/fio-runner-ephemeral` with `ds/fio-runner-ephemeral` in the commands above.

## Parallel one-off runs using Job (N pods)

Kubernetes Jobs can run multiple pods concurrently by setting `parallelism` and `completions`.

- **Pattern**: run N pods in parallel, each completes once
```bash
oc -n px-bench create -f manifests/fio-runner-job.yaml --dry-run=client -o yaml \
| yq e '.spec.parallelism = N | .spec.completions = N' - \
| oc set env -f - JOB_MODE=per_section JOB_FILTER='read$' RUNTIME_PRE_JOB=60 HOURS=1 \
| oc apply -f -

oc -n px-bench get job fio-runner -o wide
oc -n px-bench wait --for=condition=complete job/fio-runner --timeout=2h
```

Examples:
- 2 pods: replace `N` with 2
- 6 pods: replace `N` with 6
- 9 pods: replace `N` with 9
- 12 pods: replace `N` with 12

If you don’t have `yq`, you can patch with `oc`:
```bash
oc -n px-bench create -f manifests/fio-runner-job.yaml --dry-run=client -o yaml \
| oc apply -f -
oc -n px-bench patch job fio-runner --type=merge -p '{"spec":{"parallelism":N,"completions":N}}'
```

To change the workload (writes, random, sequential), reuse the filters from the sections above via `oc set env -f - ...` before `oc apply -f -`.

## Multi-StorageClass runs (matrix)

Use the suite helper to run the same profile across the 4 StorageClasses: `fio-repl1`, `fio-repl1-encrypted`, `fio-repl2`, `fio-repl2-encrypted`.

- Only reads, 6 pods per SC:
```bash
scripts/run-fio-suite.sh \
  --sc fio-repl1 \
  --mode single \
  --parallel 6 \
  --job-mode per_section \
  --job-filter 'read$'
```

- Only writes, 6 pods per SC (sequential writes):
```bash
scripts/run-fio-suite.sh \
  --mode single \
  --parallel 6 \
  --job-mode per_section \
  --job-filter 'write$' \
  --job-exclude 'rand|mix'
```

- Only random, 12 pods per SC (no mixed):
```bash
scripts/run-fio-suite.sh \
  --mode single \
  --parallel 12 \
  --job-mode per_section \
  --job-filter 'rand-(read|write)$' \
  --job-exclude 'mix'
```

- Only sequential, 9 pods per SC:
```bash
scripts/run-fio-suite.sh \
  --mode single \
  --parallel 9 \
  --job-mode per_section \
  --job-filter '(read|write)$' \
  --job-exclude 'rand|mix'
```

- Bonus: all tests in one run (per SC), 2 pods per SC:
```bash
scripts/run-fio-suite.sh \
  --mode single \
  --parallel 2 \
  --job-mode all_in_one
```

### Single-SC sequencing with profiles
Run all profiles for a specific StorageClass before moving to the next.

- Reads → Writes → Random → Sequential across one SC (e.g., fio-repl1):
```bash
scripts/run-fio-suite.sh \
  --sc fio-repl1 \
  --mode single \
  --parallel 6 \
  --profiles reads,writes,random,sequential
```

- All-in-one only for one SC:
```bash
scripts/run-fio-suite.sh --sc fio-repl2 --mode single --parallel 2 --profiles all_in_one
```

### Single-SC direct example: sequential reads only (3 pods, 20 minutes)
```bash
scripts/run-fio-suite.sh \
  --sc fio-repl1 \
  --mode single \
  --parallel 3 \
  --job-mode per_section \
  --duration-seconds 1200 \
  --job-filter 'read$' \
  --job-exclude 'rand'
```

## Cleanup results

Use the helper to clean local results and/or the cluster PVC contents.

- Local only:
```bash
scripts/cleanup-results.sh --mode local
```

- Cluster PVC only (defaults: namespace px-bench, PVC px-bench-results):
```bash
scripts/cleanup-results.sh --mode cluster --namespace px-bench
```

- Both local and cluster (default):
```bash
scripts/cleanup-results.sh --mode all
```

- Dry run (preview what would be removed):
```bash
scripts/cleanup-results.sh --mode all --dry-run
```

## Monitoring-friendly full sweep (with pauses)

Run all profiles (reads, writes, random, sequential) at parallel levels 3→15 with 20 minutes per profile, 2-minute gap between profiles, and 5-minute gap between levels, across all 4 StorageClasses. This creates visible plateaus in monitoring graphs.

```bash
scripts/run-matrix.sh \
  --profiles reads,writes,random,sequential \
  --parallel-min 3 --parallel-max 15 --parallel-step 3 \
  --profile-duration-seconds 1200 \
  --profile-gap-seconds 120 \
  --level-gap-seconds 300
```


