#!/bin/bash
#SBATCH --job-name=starccm-bench
#SBATCH --partition=hpc
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=176
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=starccm-bench_%j.out
#SBATCH --error=starccm-bench_%j.err

###############################################################################
# StarCCM+ Benchmark — Single Node (built-in -benchmark mode)
#
# Uses StarCCM+'s native -benchmark client for automated performance data
# collection, scaling studies, and HTML/XML report generation.
#
# Supports two model types:
#   1. Pre-extracted .sim file
#   2. Compressed .txz archive (extracts into per-job working dir)
#
# Environment variables (all optional except MODEL):
#   MODEL        Path to .sim or .sim.txz file (required)
#   NITS         Number of timed iterations (default: 20)
#   PREITS       Number of warm-up iterations before timing (default: 10)
#   NPS          Comma-separated core counts for scaling study (e.g. "44,88,176")
#                Defaults to SLURM_NTASKS_PER_NODE (all cores, no serial sweep)
#   TAG          Tag string appended to output filenames
#   PROFILE      If set, enable event-log profiling (value = iterations, default 10)
#   MEMPROFILE   If set, enable memory profiling (value = iterations, default 10)
#   MPI          MPI driver: openmpi (default), intel, hpe, openmpi40, openmpi41, crayxt
#   FABRIC       Network fabric: ibv, ucx, ofi, tcp, etc. (unset = auto-detect)
#   CPUBIND      CPU binding mode: bandwidth (default), off, auto, etc.
#   STARCCM_HPCX If set to "1", load system HPCX module (uses openmpi driver with HPCX mpirun)
#   MPITESTS     If set to "1", run MPI stress tests
#   HOSTINFO     If set to "1", report system info only (no iterations)
#   BENCH_EXTRA  Any additional -benchmark sub-options (passed verbatim)
#
# Examples:
#   MODEL=/shared/apps/starccm/models/acoustic_wave.sim sbatch starccm_bench.slurm
#
#   NITS=50 PREITS=10 MODEL=/path/to/model.sim sbatch starccm_bench.slurm
#
#   NPS=44,88,176 MODEL=/path/to/model.sim sbatch starccm_bench.slurm
#
#   MPI=intel FABRIC=ucx MODEL=/path/to/model.sim sbatch starccm_bench.slurm
#
#   MPI=hpe MODEL=/path/to/model.sim sbatch starccm_bench.slurm
#
#   PROFILE=10 MEMPROFILE=10 TAG=test1 MODEL=/path/to/model.sim sbatch starccm_bench.slurm
#
#   HOSTINFO=1 MODEL=/path/to/model.sim sbatch starccm_bench.slurm
###############################################################################

set -euo pipefail

# --- Configuration -----------------------------------------------------------
INSTALL_DIR=/shared/apps/starccm
MODEL=${MODEL}
NITS=${NITS:-20}
PREITS=${PREITS:-10}
NPS=${NPS:-${SLURM_NTASKS_PER_NODE}}
TAG=${TAG:-}
PROFILE=${PROFILE:-}
MEMPROFILE=${MEMPROFILE:-}
MPI=${MPI:-openmpi}
FABRIC=${FABRIC:-}
CPUBIND=${CPUBIND:-bandwidth}
UCX_TLS_OPT=${UCX_TLS:-}
UCX_ENVS=${UCX_ENVS:-}
MPPFLAGS=${MPPFLAGS:-}
XSYSTEMUCX=${XSYSTEMUCX:-}
MPITESTS=${MPITESTS:-}
HOSTINFO=${HOSTINFO:-}
BENCH_EXTRA=${BENCH_EXTRA:-}

# --- Validate MPI driver -----------------------------------------------------
case "${MPI}" in
    openmpi|openmpi40|openmpi41|intel|hpe|crayxt)
        ;;
    *)
        echo "ERROR: Unsupported MPI driver '${MPI}'. Valid options: openmpi, openmpi40, openmpi41, intel, hpe, crayxt"
        exit 1
        ;;
esac

# --- Load environment module -------------------------------------------------
MODULEFILE_DIR="${SLURM_SUBMIT_DIR}/modulefiles"
module use "${MODULEFILE_DIR}"
module load starccm
echo "Loaded module: $(module list 2>&1 | grep starccm)"

# --- HPCX support ------------------------------------------------------------
# When STARCCM_HPCX=1, load the system HPCX module so StarCCM+'s openmpi driver
# picks up the HPCX mpirun (Open MPI-based with NVIDIA optimizations) instead of
# its bundled Open MPI.
STARCCM_HPCX=${STARCCM_HPCX:-}
if [ -n "${STARCCM_HPCX}" ] && [ "${STARCCM_HPCX}" = "1" ]; then
    module load mpi/hpcx
    echo "Loaded HPCX: $(module list 2>&1 | grep hpcx)"
    # Unset PMIx/OPAL variables that conflict with StarCCM+'s bundled Open MPI.
    # HPCX sets PMIX_INSTALL_PREFIX pointing to its own PMIx, which clashes with
    # the internal PMIx in StarCCM+'s Open MPI 4.1.5.
    unset PMIX_INSTALL_PREFIX
    unset OPAL_PREFIX
fi

# --- Intel MPI support --------------------------------------------------------
# StarCCM+ ships its own Intel MPI 2021.7.1 whose:
#   1. hydra_bstrap_proxy binary crashes (exit code 65280) on this system
#   2. bundled libfabric 1.13 OFI providers (libverbs-fi.so) SIGSEGV on current OFED
# Fixes applied:
#   - I_MPI_HYDRA_BOOTSTRAP=fork: bypass the broken proxy (single-node only)
#   - I_MPI_OFI_LIBRARY_INTERNAL=0: disable the old bundled libfabric
#   - FI_PROVIDER_PATH -> system Intel MPI 2021.16 libfabric 2.1.0 providers
#   - LD_LIBRARY_PATH -> system libfabric .so so the newer lib is loaded
if [ "${MPI}" = "intel" ]; then
    module load mpi/impi-2021
    echo "Loaded Intel MPI: $(module list 2>&1 | grep impi)"

    # Fix 1: Force fork bootstrap - bypasses the broken bundled hydra_bstrap_proxy
    export I_MPI_HYDRA_BOOTSTRAP=fork
    unset I_MPI_HYDRA_BOOTSTRAP_EXEC
    unset I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS

    # Fix 2: Use system Intel MPI newer libfabric instead of bundled 1.13
    SYSTEM_IMPI_LIBFABRIC=/opt/intel/oneapi/mpi/2021.16/opt/mpi/libfabric
    export I_MPI_OFI_LIBRARY_INTERNAL=0
    export FI_PROVIDER_PATH="${SYSTEM_IMPI_LIBFABRIC}/lib/prov"
    export LD_LIBRARY_PATH="${SYSTEM_IMPI_LIBFABRIC}/lib:${LD_LIBRARY_PATH}"

    echo "I_MPI_HYDRA_BOOTSTRAP=${I_MPI_HYDRA_BOOTSTRAP}"
    echo "I_MPI_OFI_LIBRARY_INTERNAL=${I_MPI_OFI_LIBRARY_INTERNAL}"
    echo "FI_PROVIDER_PATH=${FI_PROVIDER_PATH}"
fi

# Working directory
# RUN_DIR is set by run_bench_suite.sh; falls back to runs/ for standalone use
RUN_DIR=${RUN_DIR:-${SLURM_SUBMIT_DIR}/runs}
WORKDIR=${RUN_DIR}/${SLURM_JOB_ID}
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# --- Resolve model file ------------------------------------------------------
if [[ "${MODEL}" == *.txz ]]; then
    # Compressed archive — extract into working dir
    SIM_FILE=$(find "${WORKDIR}" -name "*.sim" -type f | head -1)
    if [ -z "${SIM_FILE}" ]; then
        echo "$(date): Extracting model archive ${MODEL}..."
        tar xJf "${MODEL}" -C "${WORKDIR}"
        echo "$(date): Extraction complete."
        SIM_FILE=$(find "${WORKDIR}" -name "*.sim" -type f | head -1)
    fi
elif [[ "${MODEL}" == *.sim ]]; then
    # Direct .sim file — use as-is
    SIM_FILE="${MODEL}"
else
    echo "ERROR: MODEL must be a .sim or .txz file: ${MODEL}"
    exit 1
fi

if [ -z "${SIM_FILE}" ] || [ ! -f "${SIM_FILE}" ]; then
    echo "ERROR: No .sim file found (MODEL=${MODEL})"
    exit 1
fi
echo "Using simulation file: ${SIM_FILE}"

# --- Build benchmark options string ------------------------------------------
BENCH_OPTS=""

if [ -n "${HOSTINFO}" ] && [ "${HOSTINFO}" = "1" ]; then
    BENCH_OPTS="-hostinfo"
else
    BENCH_OPTS="-nits ${NITS} -preits ${PREITS} -nps ${NPS}"
fi

if [ -n "${TAG}" ]; then
    BENCH_OPTS="${BENCH_OPTS} -tag ${TAG}"
fi

if [ -n "${PROFILE}" ]; then
    BENCH_OPTS="${BENCH_OPTS} -profile ${PROFILE}"
fi

if [ -n "${MEMPROFILE}" ]; then
    BENCH_OPTS="${BENCH_OPTS} -memprofile ${MEMPROFILE}"
fi

if [ -n "${MPITESTS}" ] && [ "${MPITESTS}" = "1" ]; then
    BENCH_OPTS="${BENCH_OPTS} -runmpitests"
fi

if [ -n "${BENCH_EXTRA}" ]; then
    BENCH_OPTS="${BENCH_OPTS} ${BENCH_EXTRA}"
fi

# --- Environment -------------------------------------------------------------
# CDLMD_LICENSE_FILE is set by the starccm module

echo "============================================================"
echo "Job ID       : ${SLURM_JOB_ID}"
echo "Node         : $(hostname)"
echo "Partition    : ${SLURM_JOB_PARTITION}"
echo "CPUs/node    : ${SLURM_NTASKS_PER_NODE}"
echo "Model        : $(basename ${SIM_FILE})"
echo "MPI driver   : ${MPI}"
if [ -n "${STARCCM_HPCX}" ] && [ "${STARCCM_HPCX}" = "1" ]; then
echo "HPCX         : enabled (system HPCX mpirun)"
fi
if [ -n "${FABRIC}" ]; then
echo "Fabric       : ${FABRIC}"
fi
echo "CPU bind     : ${CPUBIND}"
if [ -n "${UCX_TLS_OPT}" ]; then
echo "UCX_TLS      : ${UCX_TLS_OPT}"
fi
if [ -n "${MPPFLAGS}" ]; then
echo "MPI flags    : ${MPPFLAGS}"
fi
if [ -n "${UCX_ENVS}" ]; then
echo "UCX envs     : ${UCX_ENVS}"
fi
if [ -n "${XSYSTEMUCX}" ] && [ "${XSYSTEMUCX}" = "1" ]; then
echo "System UCX   : enabled (-xsystemucx)"
fi
echo "Bench opts   : ${BENCH_OPTS}"
echo "License      : ${CDLMD_LICENSE_FILE}"
echo "StarCCM+ dir : ${STARCCM_DIR}"
echo "Working dir  : ${WORKDIR}"
echo "Start time   : $(date)"
echo "============================================================"

# --- System tuning (HBv5 best practices, applicable to HBv4) -----------------
# Ref: https://learn.microsoft.com/en-us/azure/virtual-machines/hbv5-series-overview
# THP madvise: avoid compaction stalls from 'always' mode
echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null 2>&1 || true
# Drop page caches: reduce run-to-run variability
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true
echo "Applied system tuning (THP=madvise, drop_caches)"

# --- UCX default: restrict to IB HCA ------------------------------------------
# Exclude mlx5_an0 (Azure AccelNet NIC) which causes non-fatal UAR allocation
# errors when many ranks share a single node (e.g. 176 on HBv4).
# UCX_NET_DEVICES controls which devices UCX selects for transports.
export UCX_NET_DEVICES=${UCX_NET_DEVICES:-mlx5_ib0:1}
echo "Set UCX_NET_DEVICES=${UCX_NET_DEVICES}"

# --- UCX transport override ---------------------------------------------------
# Defensive: unset UCX_TLS if no override requested, in case an empty value
# leaked through the environment (UCX treats empty UCX_TLS as an error).
if [ -n "${UCX_TLS_OPT}" ]; then
    export UCX_TLS="${UCX_TLS_OPT}"
    echo "Set UCX_TLS=${UCX_TLS}"
else
    unset UCX_TLS 2>/dev/null || true
fi

# --- UCX environment variable overrides ---------------------------------------
# UCX_ENVS is a space-separated list of KEY=VALUE pairs to export.
if [ -n "${UCX_ENVS}" ]; then
    for kv in ${UCX_ENVS}; do
        export "${kv}"
        echo "Set ${kv}"
    done
    # Remove UCX_ENVS itself so UCX doesn't warn about an unknown variable
    unset UCX_ENVS
fi

# --- Run StarCCM+ benchmark --------------------------------------------------
MPI_OPTS="-mpi ${MPI}"
if [ -n "${FABRIC}" ]; then
    MPI_OPTS="${MPI_OPTS} -fabric ${FABRIC}"
fi

BIND_OPTS=""
if [ -n "${CPUBIND}" ] && [ "${CPUBIND}" != "off" ]; then
    BIND_OPTS="-cpubind ${CPUBIND}"
fi

SYSUCX_OPT=""
if [ -n "${XSYSTEMUCX}" ] && [ "${XSYSTEMUCX}" = "1" ]; then
    SYSUCX_OPT="-xsystemucx"
fi

# Build the full starccm+ command as an array to handle quoting correctly
CMD=(starccm+
    -power
    -np ${SLURM_NTASKS_PER_NODE}
)
if [ -n "${BIND_OPTS}" ]; then
    CMD+=(${BIND_OPTS})
fi
CMD+=(${MPI_OPTS})
if [ -n "${MPPFLAGS}" ]; then
    CMD+=(-mppflags "${MPPFLAGS}")
fi
if [ -n "${SYSUCX_OPT}" ]; then
    CMD+=(${SYSUCX_OPT})
fi
CMD+=(-benchmark "${BENCH_OPTS}" "${SIM_FILE}")

echo "Command: ${CMD[*]}"
"${CMD[@]}"

echo "============================================================"
echo "End time     : $(date)"
echo "============================================================"

# --- Collect reports ----------------------------------------------------------
echo "Benchmark reports:"
find "${WORKDIR}" -name "*.xml" -o -name "*.html" | sort
