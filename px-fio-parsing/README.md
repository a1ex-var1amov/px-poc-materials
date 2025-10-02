# FIO Results Parser

Parse a directory of fio output files (JSON or text) and export a readable Excel summary.

## 1) Requirements

- Python 3.9+
- Install deps from `requirements.txt`:
  - `pandas`
  - `openpyxl` (for writing .xlsx)

## 2) Create and activate a virtual environment

macOS/Linux (bash/zsh):

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

Windows (PowerShell):

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

Deactivate when done:

```bash
deactivate
```

## 3) Usage

From the project directory:

```bash
python parse_fio.py
```

Specify input directory and output file:

```bash
python parse_fio.py --input /path/to/fio/results --output fio_summary.xlsx
```

Recurse and restrict to extensions:

```bash
python parse_fio.py --input /path/to/fio/results --recurse --include json,txt,log
```

## 4) Extracted metrics

From JSON (preferred), per job and per op (read/write):
- jobname, rw, bs, iodepth, numjobs, runtime
- iops, bandwidth (MB/s), mean latency (ms), p99 clat (ms) when present

From text logs (best effort):
- rw, bs, iodepth (if present)
- per-op IOPS and BW, first seen avg latency

## 5) Output

Creates an Excel file (default `fio_summary.xlsx`) with:
- One sheet per task (derived from directory names like `parallel-3-random-...`). Each task sheet contains all rows for that task plus charts: IOPS/BW by op, IOPS by block size (grouped), IOPS vs iodepth (line), BW heatmap (bs × iodepth), and job spread stats.
- `summary` sheet: totals per task (IOPS and MB/s split by op) and overall totals, with grouped bar charts. Runner-aware aggregation avoids double-counting repeats by averaging per runner first, then summing across runners. Latency percentiles are averaged.
- `bs_compare` sheet: cross-task comparison by block size/op with grouped bar charts for IOPS and MB/s.
- `latency` sheet: p99/p95/p50 per task/op with charts for p99 and p95.
- `summary_detailed` sheet: per task × block size view with the same simplified columns.

## 6) How summary metrics are calculated

- Runner normalization:
  - For each task/op (and task×bs×op in detailed views), we first average metrics per runner across repeated attempts.
  - Throughput metrics (IOPS, MB/s) are then summed across runners.
  - Latency metrics (p50/p95/p99) are averaged across runners.

- Summary columns:
  - `iops_read`, `iops_write`: sum of per-runner means for the given op.
  - `iops_total_all`: `iops_read + iops_write`.
  - `bw_MBps_read`, `bw_MBps_write`: sum of per-runner means for the given op.
  - `bw_total_all_MBps`: `bw_MBps_read + bw_MBps_write`.
  - `latency_mean_ms`: weighted mean by IO count across runners and ops.
  - `latency_mean_ms_per_runner`: per-runner IO-weighted mean, then averaged across runners.
  - `latency_p99_ms` (and `latency_p95_ms`): mean of the per-op latency across available ops for the task.
  - `runs_count`: number of distinct runners contributing to the task (or task×bs for detailed).

- Optional task suffix removal:
  - If `--remove-suffix` is passed, we drop a trailing `-YYYYMMDDTHHMMSSZ` from task names for grouping on the summary sheets only.

- Sort order:
  - Tasks are ordered by parallel degree: 3, 6, 9, 12, 15, then others by degree/name.
  - In detailed views, block sizes are sorted by size.

## 7) Notes

- Ensure your venv is activated before running.
- If no matching files are found, an Excel with a message is still produced.
- CSV export can be added if desired; open an issue or request the option.
