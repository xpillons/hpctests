#!/usr/bin/env python3
###############################################################################
# StarCCM+ Benchmark Results Analyser
#
# Parses all XML benchmark reports in a run directory and produces:
#   1. A sorted summary table on stdout
#   2. A CSV file for spreadsheet import
#   3. A markdown report with best/worst highlights
#
# Usage:
#   python3 analyse_results.py <RUN_DIR>
#   python3 analyse_results.py runs/20260217_183045
#   python3 analyse_results.py runs               # scans all subdirectories
#
# If no argument is given, uses the most recent timestamped directory
# under runs/.
###############################################################################

import xml.etree.ElementTree as ET
import os
import sys
import re
import glob
import csv
from datetime import datetime
from pathlib import Path


def safe_float(s, default=None):
    """Convert string to float, returning default on failure."""
    try:
        return float(s)
    except (ValueError, TypeError):
        return default


def resolve_run_dir(args):
    """Resolve the run directory from command-line arguments."""
    script_dir = Path(__file__).resolve().parent

    if args:
        run_dir = Path(args[0])
    else:
        # Find the most recent timestamped directory (YYYYMMDD_HHMMSS) under runs/
        runs_root = script_dir / "runs"
        pattern = re.compile(r"^20\d{6}_\d{6}$")
        candidates = sorted(
            [d for d in runs_root.iterdir() if d.is_dir() and pattern.match(d.name)],
            key=lambda d: d.name,
            reverse=True,
        )
        if not candidates:
            print(f"ERROR: No run directories found under {runs_root}/", file=sys.stderr)
            sys.exit(1)
        run_dir = candidates[0]

    if not run_dir.is_dir():
        print(f"ERROR: Directory not found: {run_dir}", file=sys.stderr)
        sys.exit(1)

    return run_dir.resolve()


def parse_wall_time(out_file):
    """Parse wall time from start/end timestamps in a .out file."""
    if not out_file.is_file():
        return None
    start_t = end_t = None
    with open(out_file, "r", errors="replace") as f:
        for line in f:
            if line.startswith("Start time"):
                start_t = line.split(":", 1)[1].strip()
            elif line.startswith("End time"):
                end_t = line.split(":", 1)[1].strip()
    if start_t and end_t:
        try:
            fmt = "%a %b %d %H:%M:%S %Z %Y"
            dt0 = datetime.strptime(start_t, fmt)
            dt1 = datetime.strptime(end_t, fmt)
            return (dt1 - dt0).total_seconds()
        except ValueError:
            pass
    return None


def parse_xml(xml_path):
    """Parse a single XML benchmark report and return a list of result rows."""
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
    except ET.ParseError as e:
        print(f"WARNING: Skipping {xml_path}: {e}", file=sys.stderr)
        return []

    xml_path = Path(xml_path)
    job_id = xml_path.parent.name
    run_id = xml_path.parent.parent.name
    run_subdir = xml_path.parent.parent

    # Top-level metadata
    model_name = root.findtext("Name", "N/A")
    version = root.findtext("Version", "N/A")
    mpi_type = root.findtext("MpiType", "N/A")
    tag = root.findtext("Tag", "N/A")
    server_cmd = root.findtext("ServerCommand", "")

    # Extract cpubind and fabric from ServerCommand
    cpubind = "off"
    fabric = "auto"
    parts = server_cmd.split()
    for i, p in enumerate(parts):
        if p == "-cpubind" and i + 1 < len(parts):
            cpubind = parts[i + 1]
        if p == "-fabric" and i + 1 < len(parts):
            fabric = parts[i + 1]

    # Host info
    host = root.find(".//HostNode")
    hostname = host.findtext("HostName", "N/A") if host is not None else "N/A"
    chip = host.findtext("ChipModel", "N/A") if host is not None else "N/A"
    sockets = host.findtext("NumberOfSockets", "?") if host is not None else "?"
    cores_per_sock = host.findtext("NumberOfCoresPerSocket", "?") if host is not None else "?"

    # Mesh
    total_cells = root.findtext(".//TotalNumberOfCells", "N/A")

    # Samples (one per NPS value)
    rows = []
    for sample in root.findall(".//BenchmarkSamples/Sample"):
        nworkers = sample.findtext("NumberOfWorkers", "?")
        nits = sample.findtext("NumberOfSampleIterations", "?")
        preits = sample.findtext("NumberOfPreSteps", "?")
        avg_elapsed = sample.findtext("AverageElapsedTime", "")
        std_elapsed = sample.findtext("StdDeviationElapsedTime", "")
        total_elapsed = sample.findtext("TotalElapsedTime", "")
        init_elapsed = sample.findtext("InitialElapsedTime", "")
        pre_elapsed = sample.findtext("PreIterationsElapsedTime", "")
        cell_iters = sample.findtext("CellItersPerWorkerSecond", "")
        speedup = sample.findtext("SpeedUp", "")
        res_mem = sample.findtext("ResidentHWMMemory", "")

        wall_time_s = parse_wall_time(run_subdir / f"starccm-bench_{job_id}.out")

        rows.append({
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
            # Carry host metadata for the report header
            "_chip": chip,
            "_sockets": sockets,
            "_cores_per_sock": cores_per_sock,
            "_version": version,
        })

    return rows


def fmt(value, spec, na="N/A"):
    """Format a value with the given spec, returning na if None."""
    if value is None:
        return na
    return f"{value:{spec}}"


def print_console_table(results):
    """Print the sorted results table to stdout."""
    print("=" * 120)
    print("BENCHMARK RESULTS — Sorted by Average Iteration Time (best first)")
    print("=" * 120)
    print()

    hdr = (
        f"{'Rank':>4}  {'Job':>6}  {'Run':<17}  {'Tag':<25}  {'NP':>4}  "
        f"{'PreIts':>6}  {'Iters':>5}  {'Avg (s)':>8}  {'Std (s)':>8}  "
        f"{'CellIter/ws':>12}  {'Wall (s)':>9}  {'Fabric':<6}  "
        f"{'CPUBind':<10}  {'Host':<14}  {'Mem (GB)':>9}"
    )
    print(hdr)
    print("-" * len(hdr))

    for i, r in enumerate(results):
        print(
            f"{i+1:>4}  {r['job_id']:>6}  {r['run_id']:<17}  {r['tag']:<25}  "
            f"{r['np']:>4}  {r['preits']:>6}  {r['nits']:>5}  "
            f"{fmt(r['avg_iter_s'], '.3f'):>8}  {fmt(r['std_iter_s'], '.4f'):>8}  "
            f"{fmt(r['cell_iters_per_ws'], '.0f'):>12}  "
            f"{fmt(r['wall_time_s'], '.0f'):>9}  {r['fabric']:<6}  "
            f"{r['cpubind']:<10}  {r['hostname']:<14}  "
            f"{fmt(r['res_mem_GB'], '.1f'):>9}"
        )

    print()


def print_summary(valid):
    """Print summary statistics to stdout."""
    if not valid:
        return

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


def write_csv(results, csv_path):
    """Write results to a CSV file."""
    fieldnames = [
        "rank", "run_id", "job_id", "tag", "model", "cells_M", "mpi_type",
        "fabric", "cpubind", "hostname", "np", "preits", "nits", "avg_iter_s",
        "std_iter_s", "total_s", "init_s", "pre_s", "cell_iters_per_ws",
        "speedup", "res_mem_GB", "wall_time_s",
    ]

    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for i, r in enumerate(results):
            row = dict(r)
            row["rank"] = i + 1
            writer.writerow(row)

    print(f"CSV written to: {csv_path}")


def write_markdown(results, model_groups, md_path):
    """Write results to a Markdown report, split by model."""
    run_ids = sorted(set(r["run_id"] for r in results))
    n_runs = len(run_ids)
    multi_model = len(model_groups) > 1

    # Use metadata from first result
    r0 = results[0]
    version = r0.get("_version", "N/A")

    with open(md_path, "w") as f:
        # Top-level header
        if n_runs > 1:
            f.write("# StarCCM+ Consolidated Benchmark Report\n\n")
            f.write(f"**Run directory:** `{md_path.parent}`  \n")
            f.write(f"**Runs included:** {n_runs} ({', '.join(run_ids)})  \n")
            f.write(f"**Total configurations:** {len(results)}  \n")
            if multi_model:
                f.write(f"**Models:** {len(model_groups)} ({', '.join(model_groups.keys())})  \n")
            f.write(f"**StarCCM+ version:** {version}  \n\n")
        else:
            f.write("# StarCCM+ Benchmark Report\n\n")
            f.write(f"**Run directory:** `{md_path.parent}`  \n")
            f.write(f"**Total configurations:** {len(results)}  \n")
            f.write(f"**StarCCM+ version:** {version}  \n\n")

        # Per-model sections
        for model_name, model_results in model_groups.items():
            valid = [r for r in model_results if r["avg_iter_s"] is not None]
            if not valid:
                continue

            r0m = valid[0]
            chip = r0m.get("_chip", "N/A")
            sockets = r0m.get("_sockets", "?")
            cores_per_sock = r0m.get("_cores_per_sock", "?")

            if multi_model:
                f.write(f"---\n\n## Model: {model_name}\n\n")
            else:
                f.write(f"## System\n\n")

            f.write(f"- **CPU:** {chip}  \n")
            f.write(f"- **Sockets:** {sockets} × {cores_per_sock} cores  \n")
            f.write(f"- **Model:** {r0m['model']} ({r0m['cells_M']}M cells)  \n")
            f.write(f"- **StarCCM+ version:** {r0m.get('_version', 'N/A')}  \n")
            f.write(f"- **Configurations:** {len(valid)}  \n\n")

            # Best/worst/spread
            best = valid[0]
            worst = valid[-1]
            avg_all = sum(r["avg_iter_s"] for r in valid) / len(valid)
            spread = (worst["avg_iter_s"] - best["avg_iter_s"]) / best["avg_iter_s"] * 100 if best["avg_iter_s"] > 0 else 0

            # Results table
            heading = "Results" if not multi_model else f"Results"
            f.write(f"### {heading} (sorted by avg iteration time)\n\n")
            f.write("| Rank | Job | Run | Tag | NP | PreIts | Iters | Avg (s) | Std (s) | CellIter/ws | Wall (s) | Fabric | CPUBind | Mem (GB) |\n")
            f.write("|---:|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---:|\n")
            for i, r in enumerate(model_results):
                f.write(
                    f"| {i+1} | {r['job_id']} | {r['run_id']} | {r['tag']} "
                    f"| {r['np']} | {r['preits']} | {r['nits']} "
                    f"| {fmt(r['avg_iter_s'], '.3f')} | {fmt(r['std_iter_s'], '.4f')} "
                    f"| {fmt(r['cell_iters_per_ws'], '.0f')} "
                    f"| {fmt(r['wall_time_s'], '.0f')} "
                    f"| {r['fabric']} | {r['cpubind']} "
                    f"| {fmt(r['res_mem_GB'], '.1f')} |\n"
                )
            f.write("\n")

            # Summary
            f.write("### Summary\n\n")
            f.write(f"- **Best:** {best['tag']} — **{best['avg_iter_s']:.3f}** s/iter (job {best['job_id']})  \n")
            f.write(f"- **Worst:** {worst['tag']} — **{worst['avg_iter_s']:.3f}** s/iter (job {worst['job_id']})  \n")
            f.write(f"- **Mean:** {avg_all:.3f} s/iter  \n")
            if best["avg_iter_s"] > 0:
                f.write(f"- **Spread:** +{spread:.1f}%  \n")
            f.write("\n")

            # Grouped breakdowns
            for dim_name, dim_key in [("MPI Implementation", "mpi_type"), ("Network Fabric", "fabric"), ("CPU Binding", "cpubind")]:
                groups = {}
                for r in valid:
                    k = r[dim_key]
                    groups.setdefault(k, []).append(r["avg_iter_s"])
                if len(groups) > 1:
                    f.write(f"#### By {dim_name}\n\n")
                    f.write(f"| {dim_name} | Mean (s) | Best (s) | Count |\n")
                    f.write("|---|---:|---:|---:|\n")
                    for k in sorted(groups.keys(), key=lambda x: sum(groups[x]) / len(groups[x])):
                        vals = groups[k]
                        mean = sum(vals) / len(vals)
                        best_v = min(vals)
                        f.write(f"| {k} | {mean:.3f} | {best_v:.3f} | {len(vals)} |\n")
                    f.write("\n")

    print(f"Report written to: {md_path}")


def group_by_model(results):
    """Group results by model name, preserving sort order within each group."""
    models = {}
    for r in results:
        m = r.get("model", "N/A")
        models.setdefault(m, []).append(r)
    return models


def main():
    run_dir = resolve_run_dir(sys.argv[1:])

    # Collect all XML files
    xml_files = sorted(glob.glob(str(run_dir / "**" / "*.xml"), recursive=True))

    if not xml_files:
        print(f"ERROR: No XML benchmark reports found in {run_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Analysing {len(xml_files)} benchmark report(s) in {run_dir}")
    print()

    # Parse all results
    results = []
    for xml_path in xml_files:
        results.extend(parse_xml(xml_path))

    if not results:
        print("No benchmark samples found in any XML file.", file=sys.stderr)
        sys.exit(1)

    # Sort by avg_iter_s (best first)
    results.sort(key=lambda r: r["avg_iter_s"] if r["avg_iter_s"] is not None else 1e9)

    # Group by model
    model_groups = group_by_model(results)
    multi_model = len(model_groups) > 1

    # Console output — per model
    for model_name, model_results in model_groups.items():
        if multi_model:
            print(f"\n{'#' * 80}")
            print(f"  MODEL: {model_name}")
            print(f"{'#' * 80}")
        print_console_table(model_results)
        model_valid = [r for r in model_results if r["avg_iter_s"] is not None]
        print_summary(model_valid)

    # CSV — all results together (model column already present)
    csv_path = run_dir / "benchmark_results.csv"
    write_csv(results, csv_path)

    # Markdown — split by model
    md_path = run_dir / "benchmark_report.md"
    write_markdown(results, model_groups, md_path)

    print()
    print("Done.")


if __name__ == "__main__":
    main()
