#!/usr/bin/env python3
"""Parse a single FIO JSON result file and print a human-readable summary."""

import json
import sys


def fmt_bw(kbps):
    if kbps >= 1048576:
        return f"{kbps/1048576:.2f} GB/s"
    elif kbps >= 1024:
        return f"{kbps/1024:.2f} MB/s"
    return f"{kbps:.2f} KB/s"


def fmt_lat(ns):
    if ns >= 1_000_000:
        return f"{ns/1_000_000:.2f} ms"
    elif ns >= 1000:
        return f"{ns/1000:.2f} µs"
    return f"{ns:.2f} ns"


def main():
    if len(sys.argv) < 2:
        print("Usage: parse_fio_result.py <json_file> [rw_type]", file=sys.stderr)
        sys.exit(1)

    json_file = sys.argv[1]

    with open(json_file) as f:
        data = json.load(f)

    job = data["jobs"][0]

    for direction in ["read", "write"]:
        d = job.get(direction, {})
        bw = d.get("bw", 0)       # KB/s
        iops = d.get("iops", 0)
        lat = d.get("lat_ns", d.get("clat_ns", {})).get("mean", 0)
        if bw > 0:
            print(
                f"  {direction.upper():6s}: "
                f"BW={fmt_bw(bw):>12s}   "
                f"IOPS={iops:>10.0f}   "
                f"Lat(avg)={fmt_lat(lat)}"
            )


if __name__ == "__main__":
    main()
