#!/bin/bash
###############################################################################
# StarCCM+ Benchmark Results Analyser
#
# Parses all XML benchmark reports in a run directory and produces:
#   1. A sorted summary table on stdout
#   2. A CSV file for spreadsheet import
#   3. A markdown report with best/worst highlights
#
# Usage:
#   ./analyse_results.sh <RUN_DIR>
#   ./analyse_results.sh runs/20260217_183045
#   ./analyse_results.sh runs               # scans all subdirectories
#
# If no argument is given, uses the most recent timestamped directory
# under runs/.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Resolve run directory ----------------------------------------------------
if [ $# -ge 1 ]; then
    RUN_DIR="$1"
else
    # Find the most recent timestamped directory (YYYYMMDD_HHMMSS) under runs/
    RUN_DIR=$(find "${SCRIPT_DIR}/runs" -mindepth 1 -maxdepth 1 -type d -name '20[0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]' | sort -r | head -1)
    if [ -z "${RUN_DIR}" ]; then
        echo "ERROR: No run directories found under ${SCRIPT_DIR}/runs/"
        exit 1
    fi
fi

if [ ! -d "${RUN_DIR}" ]; then
    echo "ERROR: Directory not found: ${RUN_DIR}"
    exit 1
fi

# Make path absolute
RUN_DIR="$(cd "${RUN_DIR}" && pwd)"
export RUN_DIR

# --- Find XML files -----------------------------------------------------------
XML_FILES=$(find "${RUN_DIR}" -name "*.xml" -type f | sort)
XML_COUNT=$(echo "${XML_FILES}" | grep -c . || true)

if [ "${XML_COUNT}" -eq 0 ]; then
    echo "ERROR: No XML benchmark reports found in ${RUN_DIR}"
    exit 1
fi

echo "Analysing ${XML_COUNT} benchmark report(s) in ${RUN_DIR}"
echo ""

# --- Run Python analyser ------------------------------------------------------
python3 << 'PYEOF'
import xml.etree.ElementTree as ET
import os
import sys
import glob
import csv
from datetime import datetime
from pathlib import Path

run_dir = os.environ["RUN_DIR"]

# Collect all XML files
xml_files = sorted(glob.glob(os.path.join(run_dir, "**", "*.xml"), recursive=True))

if not xml_files:
    print("No XML files found.")
    sys.exit(1)

# --- Parse all results --------------------------------------------------------
results = []

for xml_path in xml_files:
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
    except ET.ParseError as e:
        print(f"WARNING: Skipping {xml_path}: {e}", file=sys.stderr)
        continue

    # Job ID from parent directory name, run_id from grandparent
    job_id = os.path.basename(os.path.dirname(xml_path))
    run_id = os.path.basename(os.path.dirname(os.path.dirname(xml_path)))
    run_subdir = os.path.dirname(os.path.dirname(xml_path))  # path to timestamp dir

    # Top-level metadata
    model_name = root.findtext("Name", "N/A")
    version = root.findtext("Version", "N/A")
    mpi_type = root.findtext("MpiType", "N/A")
    tag = root.findtext("Tag", "N/A")
    run_date = root.findtext("RunDate", "N/A")
    server_cmd = root.findtext("ServerCommand", "")

    # Extract cpubind and fabric from ServerCommand
    cpubind = "N/A"
    fabric = "auto"
    parts = server_cmd.split()
    for i, p in enumerate(parts):
        if p == "-cpubind" and i + 1 < len(parts):
            cpubind = parts[i + 1]
        if p == "-fabric" and i + 1 < len(parts):
            fabric = parts[i + 1]
    if "-cpubind" not in server_cmd:
        cpubind = "off"

    # Host info
    host = root.find(".//HostNode")
    hostname = host.findtext("HostName", "N/A") if host is not None else "N/A"
    chip = host.findtext("ChipModel", "N/A") if host is not None else "N/A"
    sockets = host.findtext("NumberOfSockets", "?") if host is not None else "?"
    cores_per_sock = host.findtext("NumberOfCoresPerSocket", "?") if host is not None else "?"

    # Mesh
    total_cells = root.findtext(".//TotalNumberOfCells", "N/A")

    # Samples (one per NPS value)
    samples = root.findall(".//BenchmarkSamples/Sample")
    for sample in samples:
        nworkers = sample.findtext("NumberOfWorkers", "?")
        nits = sample.findtext("NumberOfSampleIterations", "?")
        preits = sample.findtext("NumberOfPreSteps", "?")
        avg_elapsed = sample.findtext("AverageElapsedTime", "")
        avg_cpu = sample.findtext("AverageCpuTime", "")
        std_elapsed = sample.findtext("StdDeviationElapsedTime", "")
        total_elapsed = sample.findtext("TotalElapsedTime", "")
        init_elapsed = sample.findtext("InitialElapsedTime", "")
        pre_elapsed = sample.findtext("PreIterationsElapsedTime", "")
        cell_iters = sample.findtext("CellItersPerWorkerSecond", "")
        speedup = sample.findtext("SpeedUp", "")
        virt_mem = sample.findtext("VirtualHWMMemory", "")
        res_mem = sample.findtext("ResidentHWMMemory", "")

        def safe_float(s, default=None):
            try:
                return float(s)
            except (ValueError, TypeError):
                return default

        # Parse wall time from the corresponding .out file
        wall_time_s = None
        out_file = os.path.join(run_subdir, f"starccm-bench_{job_id}.out")
        if os.path.isfile(out_file):
            start_t = end_t = None
            with open(out_file, "r", errors="replace") as of:
                for line in of:
                    if line.startswith("Start time"):
                        start_t = line.split(":", 1)[1].strip()
                    elif line.startswith("End time"):
                        end_t = line.split(":", 1)[1].strip()
            if start_t and end_t:
                try:
                    fmt = "%a %b %d %H:%M:%S %Z %Y"
                    dt0 = datetime.strptime(start_t, fmt)
                    dt1 = datetime.strptime(end_t, fmt)
                    wall_time_s = (dt1 - dt0).total_seconds()
                except ValueError:
                    pass

        row = {
            "run_id": run_id,
            "job_id": job_id,
            "tag": tag,
            "model": model_name,
            "cells_M": f"{int(total_cells)/1e6:.1f}" if total_cells != "N/A" else "N/A",
            "mpi_type": mpi_type,
            "fabric": fabric,
            "cpubind": cpubind,
            "hostname": hostname,
            "np": nworkers,
            "preits": preits,
            "nits": nits,
            "avg_iter_s": safe_float(avg_elapsed),
            "std_iter_s": safe_float(std_elapsed),
            "total_s": safe_float(total_elapsed),
            "init_s": safe_float(init_elapsed),
            "pre_s": safe_float(pre_elapsed),
            "cell_iters_per_ws": safe_float(cell_iters),
            "speedup": safe_float(speedup),
            "res_mem_GB": safe_float(res_mem, 0) / 1e6 if safe_float(res_mem) else None,
            "wall_time_s": wall_time_s,
        }
        results.append(row)

if not results:
    print("No benchmark samples found in any XML file.")
    sys.exit(1)

# --- Sort by avg_iter_s (best first) -----------------------------------------
results.sort(key=lambda r: r["avg_iter_s"] if r["avg_iter_s"] is not None else 1e9)

# --- Console table ------------------------------------------------------------
print("=" * 120)
print("BENCHMARK RESULTS — Sorted by Average Iteration Time (best first)")
print("=" * 120)
print()

# Header
hdr = f"{'Rank':>4}  {'Job':>6}  {'Run':<17}  {'Tag':<25}  {'NP':>4}  {'PreIts':>6}  {'Iters':>5}  {'Avg (s)':>8}  {'Std (s)':>8}  " \
      f"{'CellIter/ws':>12}  {'Wall (s)':>9}  {'Fabric':<6}  {'CPUBind':<10}  {'Host':<14}  {'Mem (GB)':>9}"
print(hdr)
print("-" * len(hdr))

for i, r in enumerate(results):
    avg = f"{r['avg_iter_s']:.3f}" if r['avg_iter_s'] is not None else "N/A"
    std = f"{r['std_iter_s']:.4f}" if r['std_iter_s'] is not None else "N/A"
    ciws = f"{r['cell_iters_per_ws']:.0f}" if r['cell_iters_per_ws'] is not None else "N/A"
    mem = f"{r['res_mem_GB']:.1f}" if r['res_mem_GB'] is not None else "N/A"
    wall = f"{r['wall_time_s']:.0f}" if r['wall_time_s'] is not None else "N/A"
    print(f"{i+1:>4}  {r['job_id']:>6}  {r['run_id']:<17}  {r['tag']:<25}  {r['np']:>4}  {r['preits']:>6}  {r['nits']:>5}  {avg:>8}  {std:>8}  "
          f"{ciws:>12}  {wall:>9}  {r['fabric']:<6}  {r['cpubind']:<10}  {r['hostname']:<14}  {mem:>9}")

print()

# --- Statistics ---------------------------------------------------------------
valid = [r for r in results if r["avg_iter_s"] is not None]
if valid:
    best = valid[0]
    worst = valid[-1]
    avg_all = sum(r["avg_iter_s"] for r in valid) / len(valid)

    print("SUMMARY")
    print("-" * 60)
    print(f"  Total configurations : {len(valid)}")
    print(f"  Best                 : {best['tag']} — {best['avg_iter_s']:.3f} s/iter (job {best['job_id']})")
    print(f"  Worst                : {worst['tag']} — {worst['avg_iter_s']:.3f} s/iter (job {worst['job_id']})")
    print(f"  Mean                 : {avg_all:.3f} s/iter")
    if best["avg_iter_s"] > 0:
        spread = (worst["avg_iter_s"] - best["avg_iter_s"]) / best["avg_iter_s"] * 100
        print(f"  Spread (worst/best)  : +{spread:.1f}%")
    print()

    # Group by dimension
    for dim_name, dim_key in [("MPI", "mpi_type"), ("Fabric", "fabric"), ("CPU Bind", "cpubind")]:
        groups = {}
        for r in valid:
            k = r[dim_key]
            groups.setdefault(k, []).append(r["avg_iter_s"])
        if len(groups) > 1:
            print(f"  By {dim_name}:")
            for k in sorted(groups.keys()):
                vals = groups[k]
                mean = sum(vals) / len(vals)
                best_v = min(vals)
                print(f"    {k:<25}  mean={mean:.3f}s  best={best_v:.3f}s  (n={len(vals)})")
            print()

# --- Write CSV ----------------------------------------------------------------
csv_path = os.path.join(run_dir, "benchmark_results.csv")
fieldnames = ["rank", "run_id", "job_id", "tag", "model", "cells_M", "mpi_type", "fabric", "cpubind",
              "hostname", "np", "preits", "nits", "avg_iter_s", "std_iter_s", "total_s", "init_s",
              "pre_s", "cell_iters_per_ws", "speedup", "res_mem_GB", "wall_time_s"]

with open(csv_path, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    for i, r in enumerate(results):
        row = dict(r)
        row["rank"] = i + 1
        writer.writerow(row)

print(f"CSV written to: {csv_path}")

# --- Write Markdown report ----------------------------------------------------
md_path = os.path.join(run_dir, "benchmark_report.md")

# Count distinct runs
run_ids = sorted(set(r["run_id"] for r in results))
n_runs = len(run_ids)

with open(md_path, "w") as f:
    if n_runs > 1:
        f.write("# StarCCM+ Consolidated Benchmark Report\n\n")
        f.write(f"**Run directory:** `{run_dir}`  \n")
        f.write(f"**Runs included:** {n_runs} ({', '.join(run_ids)})  \n")
        f.write(f"**Total configurations:** {len(valid)}  \n")
        f.write(f"**Model:** {results[0].get('model', 'N/A')}  \n\n")
    else:
        f.write("# StarCCM+ Benchmark Report\n\n")
        f.write(f"**Run directory:** `{run_dir}`  \n")
        f.write(f"**Date:** {results[0].get('model', 'N/A')} — {len(valid)} configurations  \n\n")

    # System info
    if valid:
        r0 = valid[0]
        f.write("## System\n\n")
        f.write(f"- **CPU:** {chip}  \n")
        f.write(f"- **Sockets:** {sockets} × {cores_per_sock} cores  \n")
        f.write(f"- **Model:** {r0['model']} ({r0['cells_M']}M cells)  \n")
        f.write(f"- **StarCCM+ version:** {version}  \n\n")

    # Results table
    f.write("## Results (sorted by avg iteration time)\n\n")
    f.write("| Rank | Job | Run | Tag | NP | PreIts | Iters | Avg (s) | Std (s) | CellIter/ws | Wall (s) | Fabric | CPUBind | Mem (GB) |\n")
    f.write("|---:|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---:|\n")
    for i, r in enumerate(results):
        avg = f"{r['avg_iter_s']:.3f}" if r['avg_iter_s'] is not None else "N/A"
        std = f"{r['std_iter_s']:.4f}" if r['std_iter_s'] is not None else "N/A"
        ciws = f"{r['cell_iters_per_ws']:.0f}" if r['cell_iters_per_ws'] is not None else "N/A"
        mem = f"{r['res_mem_GB']:.1f}" if r['res_mem_GB'] is not None else "N/A"
        wall = f"{r['wall_time_s']:.0f}" if r['wall_time_s'] is not None else "N/A"
        f.write(f"| {i+1} | {r['job_id']} | {r['run_id']} | {r['tag']} | {r['np']} | {r['preits']} | {r['nits']} | {avg} | {std} | {ciws} | {wall} | {r['fabric']} | {r['cpubind']} | {mem} |\n")

    f.write("\n")

    # Summary
    if valid:
        f.write("## Summary\n\n")
        f.write(f"- **Best:** {best['tag']} — **{best['avg_iter_s']:.3f}** s/iter (job {best['job_id']})  \n")
        f.write(f"- **Worst:** {worst['tag']} — **{worst['avg_iter_s']:.3f}** s/iter (job {worst['job_id']})  \n")
        f.write(f"- **Mean:** {avg_all:.3f} s/iter  \n")
        if best["avg_iter_s"] > 0:
            f.write(f"- **Spread:** +{spread:.1f}%  \n")
        f.write("\n")

        # By dimension
        for dim_name, dim_key in [("MPI Implementation", "mpi_type"), ("Network Fabric", "fabric"), ("CPU Binding", "cpubind")]:
            groups = {}
            for r in valid:
                k = r[dim_key]
                groups.setdefault(k, []).append(r["avg_iter_s"])
            if len(groups) > 1:
                f.write(f"### By {dim_name}\n\n")
                f.write(f"| {dim_name} | Mean (s) | Best (s) | Count |\n")
                f.write("|---|---:|---:|---:|\n")
                for k in sorted(groups.keys(), key=lambda x: sum(groups[x])/len(groups[x])):
                    vals = groups[k]
                    mean = sum(vals) / len(vals)
                    best_v = min(vals)
                    f.write(f"| {k} | {mean:.3f} | {best_v:.3f} | {len(vals)} |\n")
                f.write("\n")

print(f"Report written to: {md_path}")
print()
print("Done.")

PYEOF
