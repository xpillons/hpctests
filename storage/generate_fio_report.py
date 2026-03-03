#!/usr/bin/env python3
"""Parse all FIO JSON results in a directory and output a Markdown summary table."""

import glob
import json
import os
import sys


def fmt_bw(kbps):
    if kbps >= 1048576:
        return f"{kbps/1048576:.2f} GB/s"
    elif kbps >= 1024:
        return f"{kbps/1024:.2f} MB/s"
    return f"{kbps:.2f} KB/s"


def fmt_iops(iops):
    if iops >= 1000:
        return f"{iops/1000:.1f}K"
    return f"{iops:.0f}"


def fmt_lat(ns):
    if ns >= 1_000_000:
        return f"{ns/1_000_000:.2f} ms"
    elif ns >= 1000:
        return f"{ns/1000:.2f} µs"
    return f"{ns:.0f} ns"


def main():
    if len(sys.argv) < 2:
        print("Usage: generate_fio_report.py <results_dir>", file=sys.stderr)
        sys.exit(1)

    results_dir = sys.argv[1]
    json_files = sorted(glob.glob(os.path.join(results_dir, "*.json")))

    if not json_files:
        print("No FIO results found.\n")
        sys.exit(0)

    print("## FIO Results\n")
    print(
        "| Test | BW (Read) | IOPS (Read) | Lat (Read) "
        "| BW (Write) | IOPS (Write) | Lat (Write) |"
    )
    print(
        "|------|-----------|-------------|------------|"
        "------------|--------------|-------------|"
    )

    for jf in json_files:
        name = os.path.splitext(os.path.basename(jf))[0]
        try:
            with open(jf) as f:
                data = json.load(f)
            job = data["jobs"][0]
            r = job.get("read", {})
            w = job.get("write", {})
            r_bw = r.get("bw", 0)
            r_iops = r.get("iops", 0)
            r_lat = r.get("lat_ns", r.get("clat_ns", {})).get("mean", 0)
            w_bw = w.get("bw", 0)
            w_iops = w.get("iops", 0)
            w_lat = w.get("lat_ns", w.get("clat_ns", {})).get("mean", 0)
            print(
                f"| {name} "
                f"| {fmt_bw(r_bw) if r_bw else '-'} "
                f"| {fmt_iops(r_iops) if r_iops else '-'} "
                f"| {fmt_lat(r_lat) if r_lat else '-'} "
                f"| {fmt_bw(w_bw) if w_bw else '-'} "
                f"| {fmt_iops(w_iops) if w_iops else '-'} "
                f"| {fmt_lat(w_lat) if w_lat else '-'} |"
            )
        except Exception as e:
            print(f"| {name} | ERROR: {e} | | | | | |")

    print()


if __name__ == "__main__":
    main()
