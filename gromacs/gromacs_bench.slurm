#!/bin/bash
#SBATCH --job-name=gromacs-bench
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --gpus-per-node=2
#SBATCH --time=02:00:00
#SBATCH --exclusive

###############################################################################
# GROMACS Benchmark Slurm Script
#
# Expected environment variables (passed via sbatch --export):
#   BENCH_NP             - Number of MPI ranks
#   BENCH_NTOMP          - Number of OpenMP threads per rank
#   BENCH_NPME           - Number of PME ranks (0 = auto)
#   BENCH_NSTEPS         - Number of simulation steps
#   BENCH_GPU_COMM       - Enable GPU direct communication (yes/no)
#   BENCH_GPU_PME_DECOMP - Enable GPU PME decomposition (yes/no)
#   BENCH_TUNEPME        - Enable PME tuning (yes/no, default no)
#   BENCH_NSTLIST        - Neighbor list update frequency (0 = GROMACS default)
#   BENCH_DLB            - Dynamic load balancing (auto/yes/no, default auto)
#   BENCH_WORKDIR        - Working directory for this run
#   BENCH_RUNID          - Unique run identifier
###############################################################################

set -euo pipefail

# Validate required environment variables
for var in BENCH_NP BENCH_NTOMP BENCH_NPME BENCH_NSTEPS BENCH_GPU_COMM BENCH_GPU_PME_DECOMP BENCH_WORKDIR BENCH_RESULTS_DIR BENCH_RUNID; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: Required environment variable ${var} is not set"
        exit 1
    fi
done

# Optional variables with defaults
BENCH_TUNEPME="${BENCH_TUNEPME:-no}"
BENCH_NSTLIST="${BENCH_NSTLIST:-0}"
BENCH_DLB="${BENCH_DLB:-auto}"

echo "=========================================="
echo "GROMACS Benchmark Run: ${BENCH_RUNID}"
echo "=========================================="
echo "Node:       $(hostname)"
echo "Date:       $(date)"
echo "NP:         ${BENCH_NP}"
echo "NTOMP:      ${BENCH_NTOMP}"
echo "NPME:       ${BENCH_NPME}"
echo "NSTEPS:     ${BENCH_NSTEPS}"
echo "GPU_COMM:   ${BENCH_GPU_COMM}"
echo "GPU_PME_DECOMP: ${BENCH_GPU_PME_DECOMP}"
echo "TUNEPME:    ${BENCH_TUNEPME}"
echo "NSTLIST:    ${BENCH_NSTLIST}"
echo "DLB:        ${BENCH_DLB}"
echo "=========================================="

# Load GROMACS (disable nounset temporarily as EESSI init uses unset variables)
set +u
source /cvmfs/software.eessi.io/versions/2023.06/init/bash
ml load GROMACS/2024.4-foss-2023b-CUDA-12.4.0
set -u

# GPU info
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
echo ""

# Use local NVMe if available for better I/O
if [[ -d /nvme/tmp ]]; then
    RUNDIR="/nvme/tmp/gromacs_bench_${SLURM_JOB_ID}"
    echo "Using local NVMe storage: ${RUNDIR}"
else
    RUNDIR="${BENCH_WORKDIR}/run_${SLURM_JOB_ID}"
    echo "Using shared storage: ${RUNDIR}"
fi

mkdir -p "${RUNDIR}"

# Copy input files
cp "${BENCH_WORKDIR}/benchPEP-h.tpr" "${RUNDIR}/" 2>/dev/null || \
cp "${BENCH_WORKDIR}/benchPEP-h/"*.tpr "${RUNDIR}/" 2>/dev/null || \
cp "${BENCH_WORKDIR}/benchPEP-h/benchPEP.tpr" "${RUNDIR}/" 2>/dev/null || \
cp "${BENCH_WORKDIR}/benchPEP.tpr" "${RUNDIR}/" 2>/dev/null || \
{ echo "ERROR: Cannot find .tpr input file"; exit 1; }

cd "${RUNDIR}"

# Find the TPR file
TPR_FILE=$(ls *.tpr 2>/dev/null | head -1)
if [[ -z "${TPR_FILE}" ]]; then
    echo "ERROR: No .tpr file found in ${RUNDIR}"
    exit 1
fi
echo "Using input file: ${TPR_FILE}"

# Resolve full path to gmx_mpi (srun tasks may not inherit module PATH)
GMX_MPI=$(which gmx_mpi)
if [[ -z "${GMX_MPI}" ]]; then
    echo "ERROR: gmx_mpi not found in PATH after loading module"
    exit 1
fi
echo "Using binary: ${GMX_MPI}"

# Build GROMACS mdrun command
GMX_CMD="${GMX_MPI} mdrun -s ${TPR_FILE} -nsteps ${BENCH_NSTEPS} -ntomp ${BENCH_NTOMP} -resethway -noconfout -pin on"

# PME tuning: disable by default for short runs to avoid resetstep conflicts;
# enable for longer runs (>=20000 steps) where tuning completes before resethway
if [[ "${BENCH_TUNEPME}" == "yes" ]]; then
    echo "PME tuning: ENABLED"
else
    GMX_CMD="${GMX_CMD} -notunepme"
fi

# Neighbor list update frequency
if [[ ${BENCH_NSTLIST} -gt 0 ]]; then
    GMX_CMD="${GMX_CMD} -nstlist ${BENCH_NSTLIST}"
fi

# Dynamic load balancing
if [[ "${BENCH_DLB}" != "auto" ]]; then
    GMX_CMD="${GMX_CMD} -dlb ${BENCH_DLB}"
fi

# PME ranks: GROMACS requires explicit -npme when using GPU PME with multiple ranks
if [[ ${BENCH_NPME} -gt 0 ]]; then
    GMX_CMD="${GMX_CMD} -npme ${BENCH_NPME}"
elif [[ ${BENCH_NP} -ge 2 ]]; then
    # Multi-rank GPU PME requires explicit -npme; default to 1 dedicated PME rank
    GMX_CMD="${GMX_CMD} -npme 1"
fi

# Use verbs provider for all multi-rank runs to avoid PSM3 shared memory failures
if [[ ${BENCH_NP} -ge 2 ]]; then
    export FI_PROVIDER=verbs
fi

# For multi-rank GPU-aware MPI, use UCX PML instead of the default smcuda BTL
# to avoid "cuMemGetAddressRange failed" errors from Open MPI's built-in CUDA transport.
# UCX handles GPU memory registration correctly via its own cuda_copy and cuda_ipc transports.
if [[ ${BENCH_NP} -ge 2 ]]; then
    export OMPI_MCA_pml=ucx
    export OMPI_MCA_btl=^smcuda,ofi
    export OMPI_MCA_osc=ucx
    export UCX_TLS=rc,sm,cuda_copy,cuda_ipc,gdr_copy
    export UCX_RNDV_SCHEME=put_zcopy
    echo "MPI transport: UCX (pml=ucx, btl=^smcuda,ofi)"
    echo "UCX_TLS: ${UCX_TLS}"
fi

# GPU direct communication
if [[ "${BENCH_GPU_COMM}" == "yes" ]]; then
    GMX_CMD="${GMX_CMD} -bonded gpu -nb gpu -pme gpu -update gpu"
    export GMX_ENABLE_DIRECT_GPU_COMM=1
    export GMX_FORCE_GPU_AWARE_MPI=1
else
    GMX_CMD="${GMX_CMD} -nb gpu -pme gpu"
    unset GMX_ENABLE_DIRECT_GPU_COMM 2>/dev/null || true
    unset GMX_FORCE_GPU_AWARE_MPI 2>/dev/null || true
fi

# GPU PME decomposition
if [[ "${BENCH_GPU_PME_DECOMP}" == "yes" ]]; then
    GMX_CMD="${GMX_CMD} -pmefft gpu"
    export GMX_GPU_PME_DECOMPOSITION=1
else
    unset GMX_GPU_PME_DECOMPOSITION 2>/dev/null || true
fi

echo ""
echo "Running command:"
echo "  srun --export=ALL --mpi=pmix ${GMX_CMD}"
echo ""

# Run GROMACS
START_TIME=$(date +%s)
srun --export=ALL --mpi=pmix ${GMX_CMD} 2>&1 | tee "${BENCH_RESULTS_DIR}/${BENCH_RUNID}.log"
END_TIME=$(date +%s)

ELAPSED=$((END_TIME - START_TIME))
echo ""
echo "Wall time: ${ELAPSED} seconds"

# Extract performance metric
NSDAY=$(grep "Performance:" "${BENCH_RESULTS_DIR}/${BENCH_RUNID}.log" | awk '{print $2}')
if [[ -n "${NSDAY}" ]]; then
    echo ""
    echo "RESULT: ${BENCH_RUNID} | np=${BENCH_NP} ntomp=${BENCH_NTOMP} npme=${BENCH_NPME} gpu_comm=${BENCH_GPU_COMM} gpu_pme_decomp=${BENCH_GPU_PME_DECOMP} | ns/day=${NSDAY}"
    # Write to CSV results file
    echo "${BENCH_RUNID},${BENCH_NP},${BENCH_NTOMP},${BENCH_NPME},${BENCH_GPU_COMM},${BENCH_GPU_PME_DECOMP},${BENCH_NSTEPS},${NSDAY},${ELAPSED}" >> "${BENCH_RESULTS_DIR}/benchmark_results.csv"
else
    echo "WARNING: Could not extract ns/day from output"
    echo "${BENCH_RUNID},${BENCH_NP},${BENCH_NTOMP},${BENCH_NPME},${BENCH_GPU_COMM},${BENCH_GPU_PME_DECOMP},${BENCH_NSTEPS},FAILED,${ELAPSED}" >> "${BENCH_RESULTS_DIR}/benchmark_results.csv"
fi

# Cleanup local NVMe storage
if [[ "${RUNDIR}" == /nvme/tmp/* ]]; then
    rm -rf "${RUNDIR}"
    echo "Cleaned up local NVMe storage"
fi

echo ""
echo "Benchmark run ${BENCH_RUNID} completed at $(date)"
