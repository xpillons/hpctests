#!/bin/bash
#SBATCH --job-name=starccm
#SBATCH --partition=hpc
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=176
#SBATCH --time=08:00:00
#SBATCH --exclusive
#SBATCH --hint=nomultithread
#SBATCH --output=%x-%j.out
#SBATCH --error=%x-%j.err

###############################################################################
# StarCCM+ Multi-Node Batch Run
#
# Environment variables (all optional except MODEL):
#   MODEL         Path to .sim file (required)
#   MPI           MPI driver: openmpi (default), intel
#   FABRIC        Network fabric: ibv, ucx, ofi, tcp (unset = auto-detect)
#   CPUBIND       CPU binding mode: bandwidth (default), off, auto
#   STARCCM_HPCX  If "1", load system HPCX module (recommended for multi-node)
#   XSYSTEMUCX    If "1", use system UCX instead of bundled
#   MPPFLAGS      Extra MPI flags (e.g. "--map-by ppr:44:numa --bind-to core")
#   UCX_TLS       UCX transport override (e.g. "rc,sm")
#   UCX_ENVS      Space-separated KEY=VALUE pairs for UCX tuning
#   BATCH_MACRO   Batch target: "run" (default) or path to a .java macro
#
# Examples:
#   MODEL=/path/to/model.sim sbatch starccm.slurm
#
#   MODEL=/path/to/model.sim sbatch --nodes=4 starccm.slurm
#
#   STARCCM_HPCX=1 FABRIC=ucx MODEL=/path/to/model.sim sbatch --nodes=4 starccm.slurm
#
#   MPPFLAGS="--map-by ppr:44:numa --bind-to core" MODEL=/path/to/model.sim sbatch --nodes=4 starccm.slurm
###############################################################################

set -euo pipefail

# --- Configuration -----------------------------------------------------------
MODEL=${MODEL:?ERROR: MODEL environment variable is required}
MPI=${MPI:-openmpi}
FABRIC=${FABRIC:-}
CPUBIND=${CPUBIND:-bandwidth}
UCX_TLS_OPT=${UCX_TLS:-}
UCX_ENVS=${UCX_ENVS:-}
MPPFLAGS=${MPPFLAGS:-}
XSYSTEMUCX=${XSYSTEMUCX:-}
STARCCM_HPCX=${STARCCM_HPCX:-}
BATCH_MACRO=${BATCH_MACRO:-run}

# --- Validate MPI driver -----------------------------------------------------
case "${MPI}" in
    openmpi|intel) ;;
    *)
        echo "ERROR: Unsupported MPI driver '${MPI}'. Valid: openmpi, intel"
        exit 1
        ;;
esac

# --- Load environment module -------------------------------------------------
# Resolve the original script directory (Slurm copies scripts to a spool, so
# BASH_SOURCE points to the temp copy; query scontrol for the real path).
SCRIPT_DIR="$(cd "$(dirname "$(scontrol show job "${SLURM_JOB_ID}" | awk -F= '/Command=/{print $2}')")" && pwd)"
MODULEFILE_DIR="${SCRIPT_DIR}/modulefiles"
module use "${MODULEFILE_DIR}"
module load starccm
echo "Loaded module: $(module list 2>&1 | grep starccm)"

# --- HPCX support ------------------------------------------------------------
if [ "${STARCCM_HPCX:-}" = "1" ]; then
    module load mpi/hpcx
    echo "Loaded HPCX: $(module list 2>&1 | grep hpcx)"
    unset PMIX_INSTALL_PREFIX
    unset OPAL_PREFIX
fi

# --- Intel MPI support --------------------------------------------------------
if [ "${MPI}" = "intel" ]; then
    module load mpi/impi-2021
    echo "Loaded Intel MPI: $(module list 2>&1 | grep impi)"
    # Force fork bootstrap — the bundled hydra_bstrap_proxy crashes on this system
    export I_MPI_HYDRA_BOOTSTRAP=fork
    unset I_MPI_HYDRA_BOOTSTRAP_EXEC
    unset I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS
    # Use system Intel MPI libfabric instead of bundled 1.13 (SIGSEGV on current OFED)
    SYSTEM_IMPI_LIBFABRIC=/opt/intel/oneapi/mpi/2021.16/opt/mpi/libfabric
    export I_MPI_OFI_LIBRARY_INTERNAL=0
    export FI_PROVIDER_PATH="${SYSTEM_IMPI_LIBFABRIC}/lib/prov"
    export LD_LIBRARY_PATH="${SYSTEM_IMPI_LIBFABRIC}/lib:${LD_LIBRARY_PATH}"
fi

# --- Working directory --------------------------------------------------------
WORKDIR="${WORKDIR:-${SLURM_SUBMIT_DIR}}"
cd "${WORKDIR}"

# --- Generate machinefile -----------------------------------------------------
HOSTS_FILE="${WORKDIR}/hosts.${SLURM_JOB_ID}"
scontrol show hostnames "${SLURM_JOB_NODELIST}" > "${HOSTS_FILE}"
NNODES=$(wc -l < "${HOSTS_FILE}")
NP=$(( NNODES * SLURM_NTASKS_PER_NODE ))

echo "============================================================"
echo "Job ID       : ${SLURM_JOB_ID}"
echo "Nodes        : ${NNODES} (${SLURM_JOB_NODELIST})"
echo "Cores/node   : ${SLURM_NTASKS_PER_NODE}"
echo "Total cores  : ${NP}"
echo "Model        : $(basename "${MODEL}")"
echo "MPI driver   : ${MPI}"
[ "${STARCCM_HPCX:-}" = "1" ] && echo "HPCX         : enabled"
[ -n "${FABRIC}" ]             && echo "Fabric       : ${FABRIC}"
echo "CPU bind     : ${CPUBIND}"
[ -n "${UCX_TLS_OPT}" ]       && echo "UCX_TLS      : ${UCX_TLS_OPT}"
[ -n "${MPPFLAGS}" ]           && echo "MPI flags    : ${MPPFLAGS}"
[ -n "${UCX_ENVS}" ]           && echo "UCX envs     : ${UCX_ENVS}"
[ "${XSYSTEMUCX:-}" = "1" ]   && echo "System UCX   : enabled"
echo "License      : ${CDLMD_LICENSE_FILE}"
echo "Hosts file   : ${HOSTS_FILE}"
echo "Working dir  : ${WORKDIR}"
echo "Start time   : $(date)"
echo "============================================================"
cat "${HOSTS_FILE}"
echo "============================================================"

# --- UCX setup ----------------------------------------------------------------
export UCX_NET_DEVICES=${UCX_NET_DEVICES:-mlx5_ib0:1}

if [ -n "${UCX_TLS_OPT}" ]; then
    export UCX_TLS="${UCX_TLS_OPT}"
else
    unset UCX_TLS 2>/dev/null || true
fi

if [ -n "${UCX_ENVS}" ]; then
    for kv in ${UCX_ENVS}; do
        export "${kv}"
        echo "Set ${kv}"
    done
    unset UCX_ENVS
fi

# --- Build StarCCM+ command --------------------------------------------------
CMD=(starccm+
    -power
    -np "${NP}"
    -machinefile "${HOSTS_FILE}"
    -mpi "${MPI}"
)

if [ -n "${FABRIC}" ]; then
    CMD+=(-fabric "${FABRIC}")
fi

if [ -n "${CPUBIND}" ] && [ "${CPUBIND}" != "off" ]; then
    CMD+=(-cpubind "${CPUBIND}")
fi

if [ -n "${MPPFLAGS}" ]; then
    CMD+=(-mppflags "${MPPFLAGS}")
fi

if [ "${XSYSTEMUCX:-}" = "1" ]; then
    CMD+=(-xsystemucx)
fi

CMD+=(-batch "${BATCH_MACRO}" "${MODEL}")

echo "Command: ${CMD[*]}"
"${CMD[@]}"

echo "============================================================"
echo "End time     : $(date)"
echo "============================================================"

# --- Cleanup ------------------------------------------------------------------
rm -f "${HOSTS_FILE}" 
