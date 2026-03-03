#!/usr/bin/env bash
###############################################################################
# storage_benchmark.sh — FIO-based storage benchmark for HPC shared filesystems
#
# Benchmarks:
#   1. /shared/home  (always — NFS mount)
#   2. /data          (if it exists)
#
# Tests performed per target:
#   • Sequential write   (1M block, 1–16 jobs)
#   • Sequential read    (1M block, 1–16 jobs)
#   • Random write       (4K block, 1–16 jobs)
#   • Random read        (4K block, 1–16 jobs)
#   • Mixed random R/W   (4K block, 70/30 read/write)
#   • Metadata – create  (many small files)
#   • Metadata – stat
#   • Metadata – delete
#
# Usage:
#   chmod +x storage_benchmark.sh
#   ./storage_benchmark.sh              # run all defaults
#   ./storage_benchmark.sh --size 4G    # override test file size
#   ./storage_benchmark.sh --jobs 8     # override max numjobs
#   ./storage_benchmark.sh --quick      # short run (30s runtime, 1G size)
#   ./storage_benchmark.sh --help
#
# Requirements: fio (auto-installed if missing and user has sudo)
###############################################################################
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────────────────────────────────────
FILE_SIZE="2G"
RUNTIME=60          # seconds per test
RAMP_TIME=5         # warm-up before measuring
MAX_JOBS=16         # highest numjobs to test
IO_DEPTH=32         # iodepth for async engines
QUICK=0
RESULTS_DIR=""      # set below after parsing args
TARGETS=()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}════════════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}\n"; }
sep()  { echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --size SIZE       Test file size (default: ${FILE_SIZE})
  --runtime SECS    Duration per test in seconds (default: ${RUNTIME})
  --jobs N          Maximum numjobs (default: ${MAX_JOBS})
  --iodepth N       I/O depth (default: ${IO_DEPTH})
  --quick           Quick mode: 30s runtime, 1G size
  --output DIR      Results directory (default: auto-generated)
  --target PATH     Additional target directory to benchmark (repeatable)
  --help            Show this help
EOF
    exit 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --size)     FILE_SIZE="$2"; shift 2 ;;
        --runtime)  RUNTIME="$2";   shift 2 ;;
        --jobs)     MAX_JOBS="$2";  shift 2 ;;
        --iodepth)  IO_DEPTH="$2";  shift 2 ;;
        --quick)    QUICK=1;        shift   ;;
        --output)   RESULTS_DIR="$2"; shift 2 ;;
        --target)   TARGETS+=("$2"); shift 2 ;;
        --help|-h)  usage ;;
        *)          err "Unknown option: $1"; usage ;;
    esac
done

if [[ "$QUICK" -eq 1 ]]; then
    FILE_SIZE="1G"
    RUNTIME=30
    RAMP_TIME=2
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME_SHORT=$(hostname -s)
[[ -z "$RESULTS_DIR" ]] && RESULTS_DIR="/shared/home/${USER}/hpctests/storage/results_${TIMESTAMP}"
mkdir -p "$RESULTS_DIR"

# ──────────────────────────────────────────────────────────────────────────────
# Ensure FIO is available
# ──────────────────────────────────────────────────────────────────────────────
install_fio() {
    if command -v fio &>/dev/null; then
        log "fio found: $(fio --version)"
        return 0
    fi
    warn "fio not found — attempting installation..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq fio
    elif command -v yum &>/dev/null; then
        sudo yum install -y fio
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y fio
    else
        err "Cannot install fio automatically. Please install it manually."
        exit 1
    fi
    log "fio installed: $(fio --version)"
}

# ──────────────────────────────────────────────────────────────────────────────
# Collect system information
# ──────────────────────────────────────────────────────────────────────────────
collect_sysinfo() {
    local outfile="${RESULTS_DIR}/system_info.txt"
    {
        echo "=== Storage Benchmark — System Information ==="
        echo "Date:     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "Hostname: $(hostname)"
        echo "Kernel:   $(uname -r)"
        echo "OS:       $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"')"
        echo "CPUs:     $(nproc)"
        echo "Memory:   $(free -h | awk '/Mem:/{print $2}')"
        echo ""
        echo "=== Mount Points ==="
        df -hT /shared/home /data 2>/dev/null || true
        echo ""
        echo "=== NFS Mounts ==="
        mount | grep -i nfs || echo "(none)"
        echo ""
        echo "=== Block Devices ==="
        lsblk 2>/dev/null || true
        echo ""
        echo "=== FIO Version ==="
        fio --version 2>/dev/null || echo "not installed"
    } > "$outfile"
    log "System info saved to $outfile"
}

# ──────────────────────────────────────────────────────────────────────────────
# Run a single FIO job and capture JSON output
# ──────────────────────────────────────────────────────────────────────────────
run_fio_test() {
    local test_name="$1"
    local target_dir="$2"
    local rw="$3"
    local bs="$4"
    local numjobs="$5"
    local extra_opts="${6:-}"

    local test_dir="${target_dir}/fio_bench_$$"
    mkdir -p "$test_dir"

    local json_file="${RESULTS_DIR}/${test_name}.json"
    local log_prefix="${test_name}"

    log "Running: ${test_name} (rw=${rw}, bs=${bs}, jobs=${numjobs}, size=${FILE_SIZE}, runtime=${RUNTIME}s)"

    local fio_cmd=(
        fio
        --name="$test_name"
        --directory="$test_dir"
        --rw="$rw"
        --bs="$bs"
        --size="$FILE_SIZE"
        --numjobs="$numjobs"
        --iodepth="$IO_DEPTH"
        --runtime="$RUNTIME"
        --time_based
        --ramp_time="$RAMP_TIME"
        --group_reporting
        --output-format=json
        --output="$json_file"
        --ioengine=libaio
        --direct=1
        --fallocate=none
        --end_fsync=1
    )

    # Append extra options (e.g. rwmixread)
    if [[ -n "$extra_opts" ]]; then
        # shellcheck disable=SC2086
        fio_cmd+=($extra_opts)
    fi

    "${fio_cmd[@]}" 2>&1 || {
        # If libaio fails (e.g., NFS without direct I/O support), retry with psync
        warn "libaio+direct failed for ${test_name}, retrying with psync engine (buffered I/O)..."
        fio_cmd=("${fio_cmd[@]/--ioengine=libaio/--ioengine=psync}")
        fio_cmd=("${fio_cmd[@]/--direct=1/--direct=0}")
        # Re-create array properly
        local retry_cmd=(
            fio
            --name="$test_name"
            --directory="$test_dir"
            --rw="$rw"
            --bs="$bs"
            --size="$FILE_SIZE"
            --numjobs="$numjobs"
            --iodepth=1
            --runtime="$RUNTIME"
            --time_based
            --ramp_time="$RAMP_TIME"
            --group_reporting
            --output-format=json
            --output="$json_file"
            --ioengine=psync
            --direct=0
            --fallocate=none
            --end_fsync=1
        )
        if [[ -n "$extra_opts" ]]; then
            # shellcheck disable=SC2086
            retry_cmd+=($extra_opts)
        fi
        "${retry_cmd[@]}" 2>&1 || { err "Test ${test_name} FAILED"; rm -rf "$test_dir"; return 1; }
    }

    # Clean up test files
    rm -rf "$test_dir"

    # Extract and display summary
    if [[ -f "$json_file" ]] && command -v python3 &>/dev/null; then
        python3 "${SCRIPT_DIR}/parse_fio_result.py" "$json_file"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Metadata benchmark (create / stat / delete many small files)
# ──────────────────────────────────────────────────────────────────────────────
run_metadata_test() {
    local target_dir="$1"
    local label="$2"
    local num_files=10000
    local test_dir="${target_dir}/meta_bench_$$"

    log "Running metadata test on ${target_dir} (${num_files} files)..."
    mkdir -p "$test_dir"

    # CREATE
    local t_start t_end
    t_start=$(date +%s%N)
    for i in $(seq 1 "$num_files"); do
        echo "x" > "${test_dir}/file_${i}"
    done
    t_end=$(date +%s%N)
    local create_ms=$(( (t_end - t_start) / 1000000 ))
    local create_rate
    create_rate=$(python3 "${SCRIPT_DIR}/calc_rate.py" "$num_files" "$create_ms")

    # STAT
    t_start=$(date +%s%N)
    for i in $(seq 1 "$num_files"); do
        stat "${test_dir}/file_${i}" > /dev/null 2>&1
    done
    t_end=$(date +%s%N)
    local stat_ms=$(( (t_end - t_start) / 1000000 ))
    local stat_rate
    stat_rate=$(python3 "${SCRIPT_DIR}/calc_rate.py" "$num_files" "$stat_ms")

    # DELETE
    t_start=$(date +%s%N)
    rm -rf "$test_dir"
    t_end=$(date +%s%N)
    local delete_ms=$(( (t_end - t_start) / 1000000 ))
    local delete_rate
    delete_rate=$(python3 "${SCRIPT_DIR}/calc_rate.py" "$num_files" "$delete_ms")

    echo "  CREATE: ${create_rate} files/s  (${create_ms} ms total)"
    echo "  STAT:   ${stat_rate} files/s  (${stat_ms} ms total)"
    echo "  DELETE: ${delete_rate} files/s  (${delete_ms} ms total)"

    # Save to file
    cat > "${RESULTS_DIR}/${label}_metadata.txt" <<EOF
Metadata Benchmark: ${target_dir}
Files: ${num_files}
CREATE: ${create_rate} files/s (${create_ms} ms)
STAT:   ${stat_rate} files/s (${stat_ms} ms)
DELETE: ${delete_rate} files/s (${delete_ms} ms)
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# Benchmark a single target filesystem
# ──────────────────────────────────────────────────────────────────────────────
benchmark_target() {
    local target_dir="$1"
    local label="$2"

    header "Benchmarking: ${target_dir}  (label: ${label})"

    # Get filesystem type
    local fstype
    fstype=$(df -T "$target_dir" 2>/dev/null | awk 'NR==2{print $2}') || fstype="unknown"
    log "Filesystem type: ${fstype}"
    log "Test file size: ${FILE_SIZE} | Runtime: ${RUNTIME}s | Max jobs: ${MAX_JOBS}"
    echo ""

    # ── Sequential Write ─────────────────────────────────────────────────
    sep
    echo -e "${GREEN}▸ Sequential Write (bs=1M)${NC}"
    for nj in 1 4 "${MAX_JOBS}"; do
        run_fio_test "${label}_seq_write_j${nj}" "$target_dir" "write" "1M" "$nj"
    done

    # ── Sequential Read ──────────────────────────────────────────────────
    sep
    echo -e "${GREEN}▸ Sequential Read (bs=1M)${NC}"
    for nj in 1 4 "${MAX_JOBS}"; do
        run_fio_test "${label}_seq_read_j${nj}" "$target_dir" "read" "1M" "$nj"
    done

    # ── Random Write (4K) ────────────────────────────────────────────────
    sep
    echo -e "${GREEN}▸ Random Write (bs=4K)${NC}"
    for nj in 1 4 "${MAX_JOBS}"; do
        run_fio_test "${label}_rand_write_j${nj}" "$target_dir" "randwrite" "4k" "$nj"
    done

    # ── Random Read (4K) ─────────────────────────────────────────────────
    sep
    echo -e "${GREEN}▸ Random Read (bs=4K)${NC}"
    for nj in 1 4 "${MAX_JOBS}"; do
        run_fio_test "${label}_rand_read_j${nj}" "$target_dir" "randread" "4k" "$nj"
    done

    # ── Mixed Random R/W (70/30) ─────────────────────────────────────────
    sep
    echo -e "${GREEN}▸ Mixed Random R/W 70/30 (bs=4K)${NC}"
    for nj in 1 4 "${MAX_JOBS}"; do
        run_fio_test "${label}_mixed_rw_j${nj}" "$target_dir" "randrw" "4k" "$nj" "--rwmixread=70"
    done

    # ── Metadata ─────────────────────────────────────────────────────────
    sep
    echo -e "${GREEN}▸ Metadata Operations${NC}"
    run_metadata_test "$target_dir" "$label"
}

# ──────────────────────────────────────────────────────────────────────────────
# Generate summary report
# ──────────────────────────────────────────────────────────────────────────────
generate_report() {
    local report="${RESULTS_DIR}/SUMMARY.md"

    cat > "$report" <<'HEADER'
# Storage Benchmark Summary

HEADER

    echo "**Date:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$report"
    echo "**Host:** $(hostname)" >> "$report"
    echo "**File size:** ${FILE_SIZE} | **Runtime:** ${RUNTIME}s | **Max jobs:** ${MAX_JOBS} | **IO depth:** ${IO_DEPTH}" >> "$report"
    echo "" >> "$report"

    # Parse all JSON results
    if command -v python3 &>/dev/null; then
        python3 "${SCRIPT_DIR}/generate_fio_report.py" "$RESULTS_DIR" >> "$report"
    fi

    # Append metadata results
    echo "## Metadata Results" >> "$report"
    echo "" >> "$report"
    for mf in "${RESULTS_DIR}"/*_metadata.txt; do
        [[ -f "$mf" ]] || continue
        echo '```' >> "$report"
        cat "$mf" >> "$report"
        echo '```' >> "$report"
        echo "" >> "$report"
    done

    # Append tuning suggestions
    cat >> "$report" <<'TUNING'

---

## Tuning Recommendations

### NFS Client Tuning (for /shared/home)

1. **Check NFS read/write sizes** — larger rsize/wsize improves throughput:
   ```bash
   # Check current values
   nfsstat -m
   # NOTE: rsize/wsize cannot be changed via remount — requires unmount+mount.
   # The max is server-negotiated (e.g. 256K for NFSv3, 1M for NFSv4).
   # To change, update /etc/fstab and remount properly:
   #   sudo umount /shared && sudo mount /shared
   # Or request the admin to increase the server-side max transfer size.
   ```

2. **Enable NFS readahead** — helps sequential reads:
   ```bash
   # Find the BDI for your NFS mount
   cat /sys/class/bdi/*/read_ahead_kb
   # Identify which BDI belongs to /shared (match the dev id from mountinfo)
   grep '/shared' /proc/self/mountinfo | awk '{print $3}'
   # Set to 16 MB (e.g. for BDI 0:73)
   echo 16384 | sudo tee /sys/class/bdi/0:73/read_ahead_kb
   ```

3. **Use NFSv4.1+ with pNFS** if your server supports it for parallel data access.

4. **Increase sunrpc slot table**:
   ```bash
   echo 128 | sudo tee /proc/sys/sunrpc/tcp_max_slot_table_entries
   # Then remount the NFS share to pick up new value
   ```

5. **NFS `actimeo` tuning** — for workloads tolerant of slightly stale metadata:
   ```bash
   sudo mount -o remount,actimeo=60 /shared
   ```

### Kernel / OS Tuning

6. **vm.dirty_ratio / vm.dirty_background_ratio** — control write-back thresholds:
   ```bash
   # Increase for write-heavy workloads (allow more dirty pages)
   sudo sysctl -w vm.dirty_ratio=40
   sudo sysctl -w vm.dirty_background_ratio=10
   # For latency-sensitive workloads, keep defaults or lower them
   ```

7. **vm.vfs_cache_pressure** — reduce to keep directory/inode caches longer:
   ```bash
   sudo sysctl -w vm.vfs_cache_pressure=50
   ```

8. **Increase file descriptor limits**:
   ```bash
   ulimit -n 1048576
   # Persist in /etc/security/limits.conf:
   # * soft nofile 1048576
   # * hard nofile 1048576
   ```

### I/O Scheduler Tuning

9. **Set I/O scheduler** — use `none` (noop) for NVMe, `mq-deadline` for NFS:
   ```bash
   # Check current scheduler
   cat /sys/block/nvme0n1/queue/scheduler
   # For NVMe
   echo none | sudo tee /sys/block/nvme0n1/queue/scheduler
   ```

10. **Increase NVMe queue depth**:
    ```bash
    echo 1024 | sudo tee /sys/block/nvme0n1/queue/nr_requests
    ```

### Application-Level Tips

11. **Use `O_DIRECT`** to bypass page cache for large sequential I/O (reduces memory pressure).

12. **Stripe I/O across multiple files/directories** to distribute NFS server load.

13. **Consider using `cp --reflink=auto`** for copy operations on supported filesystems.

14. **For parallel I/O**, use MPI-IO or HDF5 parallel file access patterns.

15. **Match I/O block size to filesystem/RAID stripe size** (typically 1M for HPC workloads).

TUNING

    log "Report saved to: ${report}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
main() {
    header "Storage Benchmark Suite (FIO)"
    log "Results directory: ${RESULTS_DIR}"
    log "Parameters: size=${FILE_SIZE} runtime=${RUNTIME}s jobs=${MAX_JOBS} iodepth=${IO_DEPTH}"

    install_fio
    collect_sysinfo

    # Always benchmark /shared/home
    if [[ -d "/shared/home" ]]; then
        benchmark_target "/shared/home/${USER}" "shared_home"
    else
        warn "/shared/home does not exist — skipping"
    fi

    # Benchmark /data if it exists
    if [[ -d "/data" ]]; then
        benchmark_target "/data" "data"
    else
        log "/data does not exist — skipping"
    fi

    # Benchmark any additional targets from --target flags
    for t in "${TARGETS[@]+"${TARGETS[@]}"}"; do
        if [[ -d "$t" ]]; then
            # Create safe label from path
            local safe_label
            safe_label=$(echo "$t" | sed 's|^/||;s|/|_|g')
            benchmark_target "$t" "$safe_label"
        else
            warn "Target $t does not exist — skipping"
        fi
    done

    generate_report

    header "Benchmark Complete"
    log "All results in: ${RESULTS_DIR}"
    log "Summary report: ${RESULTS_DIR}/SUMMARY.md"
    echo ""
    echo -e "${YELLOW}Review ${RESULTS_DIR}/SUMMARY.md for results and tuning recommendations.${NC}"
}

main "$@"
