#!/bin/bash
###############################################################################
# StarCCM+ Benchmark Suite — Single Node
#
# Submits a matrix of benchmark jobs varying:
#   - Core counts (NPS)
#   - MPI implementations (Open MPI bundled, HPCX, Intel MPI)
#   - Network fabrics (UCX, OFI)
#
# Each combination is submitted as a separate Slurm job with a descriptive tag
# for easy comparison of the resulting HTML/XML reports.
#
# Usage:
#   ./run_bench_suite.sh [MODEL_PATH]
#
# If MODEL_PATH is not given, defaults to the AeroSUV Segregated 57M model.
#
# Customize by editing the arrays below.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_SLURM="${SCRIPT_DIR}/starccm_bench.slurm"

# --- Default model -----------------------------------------------------------
MODEL=${1:-/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim}

if [ ! -f "${MODEL}" ]; then
    echo "ERROR: Model file not found: ${MODEL}"
    exit 1
fi

# --- Benchmark parameters ----------------------------------------------------
# Core counts to test (scaling study within each job)
CORE_COUNTS="176"

# Number of timed / warm-up iterations
NITS=20
PREITS=10

# Constrain to XPMEM-enabled nodes
NODELIST="ccw-hpc-[1-4]"

# MPI + fabric + cpubind combinations to test
# Format: "MPI_DRIVER|FABRIC|CPUBIND|LABEL|UCX_TLS|MPPFLAGS|UCX_ENVS"
#   MPI_DRIVER  — StarCCM+ -mpi argument (openmpi, intel)
#   FABRIC      — StarCCM+ -fabric argument (ucx, ofi, or empty for auto)
#   CPUBIND     — StarCCM+ -cpubind argument (bandwidth, off, auto, or empty for default)
#   LABEL       — Human-readable tag for output files
#   UCX_TLS     — UCX transport selection (e.g. sm,self for single-node shared memory)
#   MPPFLAGS    — Extra MPI flags passed via -mppflags (e.g. NUMA mapping)
#   UCX_ENVS    — Space-separated UCX env var overrides (e.g. UCX_RNDV_THRESH=65536)
# Labels ending in "-sysucx" automatically enable -xsystemucx (system UCX)
COMBINATIONS=(
    # ==========================================================================
    # HBv4 tuning pass — NUMA-aware (ppr:44:numa) + HCOLL + PML + shm-only
    # All tests use: HPCX mpirun, UCX fabric, -xsystemucx, XPMEM via ldconfig
    # Nodes ccw-hpc-[1-4] have HPCX UCX registered as system default.
    #
    # Note: UCX_NET_DEVICES=mlx5_ib0:1 is set as default in starccm_bench.slurm
    # to exclude mlx5_an0 (Azure AccelNet NIC) which causes UAR errors.
    # ==========================================================================

    ## --- Previous pass (A–E) — kept for reference ----------------------------
    ## --- A. NUMA-aware: 44 ranks per NUMA domain (4 NUMA × 44 = 176) ---
    #"openmpi|ucx|off|hpcx-sysucx-numa44-xpmem|all|--map-by ppr:44:numa --bind-to core|"

    ## --- B. NUMA-aware + RNDV 8K (best from previous pass) ---
    #"openmpi|ucx|off|hpcx-sysucx-numa44-xpmem-rndv|all|--map-by ppr:44:numa --bind-to core|UCX_RNDV_THRESH=8192 UCX_RNDV_SCHEME=put_zcopy"

    ## --- C. NUMA-aware + HCOLL (hardware-offloaded collectives) ---
    #"openmpi|ucx|off|hpcx-sysucx-numa44-hcoll|all|--map-by ppr:44:numa --bind-to core -mca coll_hcoll_enable 1 -x HCOLL_MAIN_IB=mlx5_ib0:1|"

    ## --- D. NUMA-aware + shm-only UCX_TLS (skip IB transport init) ---
    #"openmpi|ucx|off|hpcx-sysucx-numa44-shm|shm,self|--map-by ppr:44:numa --bind-to core|"

    ## --- E. NUMA-aware + explicit PML UCX (disable unused BTLs) ---
    #"openmpi|ucx|off|hpcx-sysucx-numa44-pml|all|--map-by ppr:44:numa --bind-to core -mca pml ucx --mca btl ^vader,tcp,openib|"

    # ==========================================================================
    # HBv5-inspired tuning pass (F–J) — system tuning + transport + CCD binding
    # Based on https://learn.microsoft.com/en-us/azure/virtual-machines/hbv5-series-overview
    #
    # System tuning (THP madvise, drop caches) applied in starccm_bench.slurm.
    # HBv4 topology: 24 CCDs (20×8 + 4×4 cores), 4 NUMA domains, 96 MB L3/CCD.
    # ==========================================================================

    # --- F. Baseline with system tuning (same as A, benefits from Slurm preamble) ---
    "openmpi|ucx|off|hpcx-sysucx-numa44-tuned|all|--map-by ppr:44:numa --bind-to core|"

    # --- G. UCX_TLS=rc,sm — targeted transports (skip unused IB init) ---
    "openmpi|ucx|off|hpcx-sysucx-numa44-rc|rc,sm|--map-by ppr:44:numa --bind-to core|"

    ## --- H. Bind-to l3cache — BROKEN: 4 CCDs have only 4 cores (hypervisor)
    ##    ppr:44:numa places ~7-8 ranks/CCD → oversubscribes 4-core CCDs
    #"openmpi|ucx|off|hpcx-sysucx-numa44-l3bind|all|--map-by ppr:44:numa --bind-to l3cache|"

    # --- H. rc,sm + RNDV 8K — best transport + best threshold from prior passes ---
    "openmpi|ucx|off|hpcx-sysucx-numa44-rc-rndv|rc,sm|--map-by ppr:44:numa --bind-to core|UCX_RNDV_THRESH=8192 UCX_RNDV_SCHEME=put_zcopy"

    # --- I. Rank-by slot — sequential fill for better CCD locality ---
    "openmpi|ucx|off|hpcx-sysucx-numa44-rankslot|all|--map-by ppr:44:numa --rank-by slot --bind-to core|"

    ## --- J. Combined rc,sm + l3cache — BROKEN: same CCD oversubscription as H
    #"openmpi|ucx|off|hpcx-sysucx-numa44-rc-l3|rc,sm|--map-by ppr:44:numa --rank-by slot --bind-to l3cache|"

    # --- J. rc,sm + rank-by slot + RNDV 8K — combined best settings ---
    "openmpi|ucx|off|hpcx-sysucx-numa44-rc-slot-rndv|rc,sm|--map-by ppr:44:numa --rank-by slot --bind-to core|UCX_RNDV_THRESH=8192 UCX_RNDV_SCHEME=put_zcopy"
)

# --- Create timestamped run directory -----------------------------------------
RUN_TS=$(date +%Y%m%d_%H%M%S)
RUN_DIR=${SCRIPT_DIR}/runs/${RUN_TS}
mkdir -p "${RUN_DIR}"

# --- Submit jobs --------------------------------------------------------------
echo "============================================================"
echo "StarCCM+ Benchmark Suite"
echo "============================================================"
echo "Run dir     : ${RUN_DIR}"
echo "Model       : $(basename ${MODEL})"
echo "Core counts : ${CORE_COUNTS}"
echo "Iterations  : ${PREITS} pre + ${NITS} timed"
echo "Combinations: ${#COMBINATIONS[@]}"
echo "============================================================"
echo ""

JOBIDS=()

for combo in "${COMBINATIONS[@]}"; do
    IFS='|' read -r mpi_driver fabric cpubind label ucx_tls mppflags ucx_envs <<< "${combo}"

    echo "Submitting: ${label} (mpi=${mpi_driver}, fabric=${fabric}, cpubind=${cpubind:-default}, ucx_tls=${ucx_tls:-auto}, mppflags=${mppflags:-none})"

    # For HPCX combinations, pass STARCCM_HPCX=1 so the Slurm script loads
    # the system HPCX module instead of using StarCCM+'s bundled Open MPI.
    HPCX_FLAG=""
    if [[ "${label}" == hpcx-* ]]; then
        HPCX_FLAG="1"
    fi

    # For sysucx combinations, pass XSYSTEMUCX=1 to use system UCX
    SYSUCX_FLAG=""
    if [[ "${label}" == *-sysucx* ]]; then
        SYSUCX_FLAG="1"
    fi

    # Use env prefix instead of --export= to avoid comma-in-value issues
    # (sbatch --export uses commas as delimiters, which breaks NPS=44,88,176)
    # Build env array — only include UCX_TLS and MPPFLAGS when non-empty
    # to avoid propagating empty values that confuse UCX/MPI
    ENV_ARGS=(
        MODEL="${MODEL}"
        MPI="${mpi_driver}"
        FABRIC="${fabric}"
        CPUBIND="${cpubind}"
        NPS="${CORE_COUNTS}"
        NITS="${NITS}"
        PREITS="${PREITS}"
        TAG="${label}"
        STARCCM_HPCX="${HPCX_FLAG}"
        RUN_DIR="${RUN_DIR}"
    )
    if [ -n "${ucx_tls}" ]; then
        ENV_ARGS+=(UCX_TLS="${ucx_tls}")
    fi
    if [ -n "${mppflags}" ]; then
        ENV_ARGS+=(MPPFLAGS="${mppflags}")
    fi
    if [ -n "${SYSUCX_FLAG}" ]; then
        ENV_ARGS+=(XSYSTEMUCX="${SYSUCX_FLAG}")
    fi
    if [ -n "${ucx_envs}" ]; then
        ENV_ARGS+=(UCX_ENVS="${ucx_envs}")
    fi

    SBATCH_ARGS=(
        --parsable
        --job-name="bench-${label}"
        --output="${RUN_DIR}/starccm-bench_%j.out"
        --error="${RUN_DIR}/starccm-bench_%j.err"
    )
    if [ -n "${NODELIST:-}" ]; then
        SBATCH_ARGS+=(--nodelist="${NODELIST}")
    fi

    JOBID=$(
        env "${ENV_ARGS[@]}" \
        sbatch "${SBATCH_ARGS[@]}" \
            "${BENCH_SLURM}"
    )

    echo "  → Job ${JOBID} submitted"
    JOBIDS+=("${JOBID}:${label}")
done

echo ""
echo "============================================================"
echo "All jobs submitted. Summary:"
echo "============================================================"
printf "%-12s  %s\n" "JOB ID" "CONFIGURATION"
printf "%-12s  %s\n" "------" "-------------"
for entry in "${JOBIDS[@]}"; do
    IFS=':' read -r jid jlabel <<< "${entry}"
    printf "%-12s  %s\n" "${jid}" "${jlabel}"
done

echo ""
echo "Monitor with: squeue -u \$USER"
echo "Results in:   ${RUN_DIR}/<JOBID>/"
echo ""
echo "After all jobs complete, compare reports with:"
echo "  ls ${RUN_DIR}/*/benchmark*.html"
