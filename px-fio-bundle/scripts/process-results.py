#!/usr/bin/env python3
import json
import csv
import sys
import pathlib

def process_dir(root: pathlib.Path):
    summary_rows = []
    for sc_dir in sorted(root.glob('results/*')):
        sc_name = sc_dir.name
        for node_dir in sorted(sc_dir.glob('*')):
            node_name = node_dir.name
            for jf in sorted(node_dir.glob('*.json')):
                try:
                    data = json.loads(jf.read_text())
                except Exception:
                    continue
                for job in data.get('jobs', []):
                    row = {
                        'storage_class': sc_name,
                        'node': node_name,
                        'file': jf.name,
                        'jobname': job.get('jobname'),
                        'groupid': job.get('groupid'),
                        'read_iops': job.get('read', {}).get('iops'),
                        'write_iops': job.get('write', {}).get('iops'),
                        'read_lat_ms': (job.get('read', {}).get('lat', {}).get('mean') or 0)/1000.0 if isinstance(job.get('read', {}).get('lat', {}).get('mean'), (int,float)) else job.get('read', {}).get('lat', {}).get('mean'),
                        'write_lat_ms': (job.get('write', {}).get('lat', {}).get('mean') or 0)/1000.0 if isinstance(job.get('write', {}).get('lat', {}).get('mean'), (int,float)) else job.get('write', {}).get('lat', {}).get('mean'),
                        'read_bw_kib': job.get('read', {}).get('bw'),
                        'write_bw_kib': job.get('write', {}).get('bw'),
                        'read_p50_ms': (job.get('read', {}).get('clat_ns', {}).get('percentile', {}).get('50.000000') or 0)/1e6 if isinstance(job.get('read', {}).get('clat_ns', {}).get('percentile', {}).get('50.000000'), (int,float)) else job.get('read', {}).get('clat_ns', {}).get('percentile', {}).get('50.000000'),
                        'read_p95_ms': (job.get('read', {}).get('clat_ns', {}).get('percentile', {}).get('95.000000') or 0)/1e6 if isinstance(job.get('read', {}).get('clat_ns', {}).get('percentile', {}).get('95.000000'), (int,float)) else job.get('read', {}).get('clat_ns', {}).get('percentile', {}).get('95.000000'),
                        'read_p99_ms': (job.get('read', {}).get('clat_ns', {}).get('percentile', {}).get('99.000000') or 0)/1e6 if isinstance(job.get('read', {}).get('clat_ns', {}).get('percentile', {}).get('99.000000'), (int,float)) else job.get('read', {}).get('clat_ns', {}).get('percentile', {}).get('99.000000'),
                        'write_p50_ms': (job.get('write', {}).get('clat_ns', {}).get('percentile', {}).get('50.000000') or 0)/1e6 if isinstance(job.get('write', {}).get('clat_ns', {}).get('percentile', {}).get('50.000000'), (int,float)) else job.get('write', {}).get('clat_ns', {}).get('percentile', {}).get('50.000000'),
                        'write_p95_ms': (job.get('write', {}).get('clat_ns', {}).get('percentile', {}).get('95.000000') or 0)/1e6 if isinstance(job.get('write', {}).get('clat_ns', {}).get('percentile', {}).get('95.000000'), (int,float)) else job.get('write', {}).get('clat_ns', {}).get('percentile', {}).get('95.000000'),
                        'write_p99_ms': (job.get('write', {}).get('clat_ns', {}).get('percentile', {}).get('99.000000') or 0)/1e6 if isinstance(job.get('write', {}).get('clat_ns', {}).get('percentile', {}).get('99.000000'), (int,float)) else job.get('write', {}).get('clat_ns', {}).get('percentile', {}).get('99.000000'),
                    }
                    summary_rows.append(row)

    out_csv = root / 'summary.csv'
    with out_csv.open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(summary_rows[0].keys()) if summary_rows else [])
        if summary_rows:
            writer.writeheader()
            writer.writerows(summary_rows)
    print(f"Wrote {out_csv} ({len(summary_rows)} rows)")

    # write a minimal index.html
    index = root / 'index.html'
    index.write_text('''<!doctype html>
<meta charset="utf-8"/>
<title>PX Bench Results</title>
<style>
body{font-family:system-ui,Segoe UI,Arial,sans-serif;margin:20px}
table{border-collapse:collapse;width:100%}
th,td{border:1px solid #ddd;padding:6px}
th{background:#f4f4f4;position:sticky;top:0}
</style>
<h1>PX Bench Results</h1>
<p>CSV: <a href="summary.csv">summary.csv</a></p>
<div id="root">Loading...</div>
<script>
fetch('summary.csv').then(r=>r.text()).then(t=>{
  const rows=t.trim().split(/\n/).map(l=>l.split(','));
  if(rows.length<2){document.getElementById('root').textContent='No data';return}
  const [head,...rest]=rows;
  const tbl=document.createElement('table');
  const thead=document.createElement('thead');
  const trh=document.createElement('tr');
  head.forEach(h=>{const th=document.createElement('th');th.textContent=h;trh.appendChild(th)});
  thead.appendChild(trh);tbl.appendChild(thead);
  const tb=document.createElement('tbody');
  rest.forEach(r=>{const tr=document.createElement('tr');r.forEach(c=>{const td=document.createElement('td');td.textContent=c;tr.appendChild(td)});tb.appendChild(tr)});
  tbl.appendChild(tb);
  const root=document.getElementById('root');root.innerHTML='';root.appendChild(tbl);
});
</script>
''')
    print(f"Wrote {index}")

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: process-results.py <results_dir>")
        sys.exit(1)
    root = pathlib.Path(sys.argv[1]).resolve()
    process_dir(root)


