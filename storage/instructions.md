- Build a bash script using FIO or IOR to benchmark /home/shared and if exists /data
- suggest tuning options

## Files

| File | Description |
|------|-------------|
| `storage_benchmark.sh` | Main benchmark script — runs FIO tests and metadata benchmarks |
| `parse_fio_result.py` | Parses a single FIO JSON result and prints BW/IOPS/latency |
| `calc_rate.py` | Calculates ops/second from count and elapsed milliseconds |
| `generate_fio_report.py` | Parses all FIO JSON results into a Markdown summary table |

## Usage

```bash
./storage_benchmark.sh              # full run (~30 min)
./storage_benchmark.sh --quick      # quick mode (30s/test, 1G files)
./storage_benchmark.sh --target /nvme  # also benchmark local NVMe
./storage_benchmark.sh --size 4G --jobs 8 --runtime 120  # custom params
```

Results are saved to `results_<timestamp>/` with per-test JSON files and a `SUMMARY.md`.

## Findings

- `/shared/home` is NFS v3 (`10.29.0.36:/home-path`), 256 KB rsize/wsize, nconnect=8
- Sequential BW is capped at **~256 MB/s** — hard limit from NFS server rsize/wsize
- Random 4K: up to **65K IOPS** at 4+ jobs (likely server-side caching)
- Metadata: **~370 create/s**, **~400 stat/s** — typical NFS v3 overhead
- Adding readahead (16 MB) had no measurable impact (FIO uses O_DIRECT / psync)
- `/sched` mount (NFSv4.2) already uses 1M rsize/wsize — upgrading `/shared` to v4.x would help

