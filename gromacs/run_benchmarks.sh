#!/bin/bash
###############################################################################
# GROMACS Benchmark Suite - Runner
#
# Submits multiple GROMACS benchmark jobs with different parameter combinations
# to find optimal performance on H100 GPU nodes (80 cores, 2 GPUs).
#
# Usage:
#   ./run_benchmarks.sh [--quick] [--dry-run]
#
# Options:
#   --quick    Run with 5000 steps (fast first-pass screening)
#   --dry-run  Show what would be submitted without actually submitting
#
# The script explores combinations of:
#   - MPI ranks (np): 1, 2, 4, 6, 8 (must be multiple of 2 GPUs)
#   - OpenMP threads per rank (ntomp): auto-calculated to fill cores
#   - PME ranks (npme): 0 (auto), 1
#   - GPU direct communication: yes, no
#   - GPU PME decomposition: yes, no
#   - Neighbor list interval (nstlist): 0 (default), 150, 175, 200
#
# Uses UCX transport (pml=ucx) for multi-rank GPU-aware MPI to avoid
# smcuda CUDA errors and achieve ~2x speedup over default transport.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLURM_SCRIPT="${SCRIPT_DIR}/gromacs_bench.slurm"
WORKDIR="${SCRIPT_DIR}"
TOTAL_CORES=80
NUM_GPUS=2

# Default: full benchmark (20000 steps)
NSTEPS=20000
QUICK=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            QUICK=true
            NSTEPS=5000
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --steps)
            NSTEPS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--quick] [--dry-run] [--steps N]"
            echo ""
            echo "Options:"
            echo "  --quick     Run with 5000 steps (fast screening)"
            echo "  --dry-run   Show what would be submitted without submitting"
            echo "  --steps N   Use custom number of steps"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check prerequisites
if [[ ! -f "${SLURM_SCRIPT}" ]]; then
    echo "ERROR: Slurm script not found: ${SLURM_SCRIPT}"
    exit 1
fi

# Check for benchmark input files
if [[ ! -d "${WORKDIR}/benchPEP-h" ]] && [[ ! -f "${WORKDIR}/benchPEP.tpr" ]] && [[ ! -f "${WORKDIR}/benchPEP-h.tpr" ]]; then
    echo "Benchmark input files not found. Downloading..."
    echo "Run the following commands manually:"
    echo "  cd ${WORKDIR}"
    echo "  wget https://www.mpinat.mpg.de/benchPEP-h"
    echo "  unzip benchPEP-h"
    echo ""
    echo "Then re-run this script."
    exit 1
fi

# Create timestamped results directory for this pass
PASS_LABEL=$(date +%Y%m%d_%H%M%S)
if [[ "${QUICK}" == true ]]; then
    PASS_LABEL="${PASS_LABEL}_quick"
else
    PASS_LABEL="${PASS_LABEL}_full"
fi
RESULTS_DIR="${WORKDIR}/results/${PASS_LABEL}"
mkdir -p "${RESULTS_DIR}"

# Initialize CSV header
CSV_FILE="${RESULTS_DIR}/benchmark_results.csv"
echo "run_id,np,ntomp,npme,gpu_comm,gpu_pme_decomp,nsteps,ns_per_day,wall_time_sec" > "${CSV_FILE}"

# Create a symlink to the latest results
ln -sfn "${PASS_LABEL}" "${WORKDIR}/results/latest"

echo "=========================================="
echo "GROMACS Benchmark Suite"
echo "=========================================="
echo "Steps per run: ${NSTEPS}"
echo "Quick mode:    ${QUICK}"
echo "Dry run:       ${DRY_RUN}"
echo "Results dir:   ${RESULTS_DIR}"
echo "=========================================="
echo ""

# Define parameter space
# On a 2-GPU H100 node with 80 cores:
#   np * ntomp should approximately equal total cores
#   np must be >= NUM_GPUS for GPU tasks to be distributed

# Since GROMACS requires explicit -npme for multi-rank GPU PME runs,
# npme=0 with np>=2 will auto-default to npme=1 in the slurm script.
# We only need to test npme=0 (auto->1) and higher npme values.
NP_VALUES=(1 2 4 6 8)
NPME_VALUES=(0 1)
GPU_COMM_VALUES=("no" "yes")
GPU_PME_DECOMP_VALUES=("no" "yes")

SUBMITTED=0

submit_job() {
    local np=$1
    local ntomp=$2
    local npme=$3
    local gpu_comm=$4
    local gpu_pme_decomp=$5
    local tunepme=${6:-no}
    local nstlist=${7:-0}
    local dlb=${8:-auto}

    # Generate unique run ID
    local run_id="np${np}_nt${ntomp}_npme${npme}_gc${gpu_comm}_gpd${gpu_pme_decomp}"
    # Append tuning suffixes when non-default values are used
    if [[ "${tunepme}" == "yes" ]]; then
        run_id="${run_id}_tpme"
    fi
    if [[ ${nstlist} -gt 0 ]]; then
        run_id="${run_id}_nsl${nstlist}"
    fi
    if [[ "${dlb}" != "auto" ]]; then
        run_id="${run_id}_dlb${dlb}"
    fi

    # Skip invalid: np must be a multiple of the number of GPUs (2)
    if [[ $((np % NUM_GPUS)) -ne 0 && ${np} -gt 1 ]]; then
        return
    fi

    # PME decomposition requires GPU direct communication
    if [[ "${gpu_pme_decomp}" == "yes" && "${gpu_comm}" == "no" ]]; then
        return
    fi

    # PME decomposition requires more than 1 rank
    if [[ "${gpu_pme_decomp}" == "yes" && ${np} -lt 2 ]]; then
        return
    fi

    # npme must be less than np
    if [[ ${npme} -ge ${np} ]]; then
        return
    fi

    # Total threads must not exceed available cores
    local total_threads=$((np * ntomp))
    if [[ ${total_threads} -gt ${TOTAL_CORES} ]]; then
        return
    fi

    # Build export variable list
    local export_vars="BENCH_NP=${np},BENCH_NTOMP=${ntomp},BENCH_NPME=${npme},BENCH_NSTEPS=${NSTEPS},BENCH_GPU_COMM=${gpu_comm},BENCH_GPU_PME_DECOMP=${gpu_pme_decomp},BENCH_TUNEPME=${tunepme},BENCH_NSTLIST=${nstlist},BENCH_DLB=${dlb},BENCH_WORKDIR=${WORKDIR},BENCH_RESULTS_DIR=${RESULTS_DIR},BENCH_RUNID=${run_id}"

    if [[ "${DRY_RUN}" == true ]]; then
        echo "[DRY RUN] Would submit: ${run_id} (np=${np} ntomp=${ntomp} npme=${npme} gpu_comm=${gpu_comm} gpd=${gpu_pme_decomp} tpme=${tunepme} nsl=${nstlist} dlb=${dlb})"
    else
        local job_id
        job_id=$(sbatch --ntasks-per-node="${np}" --cpus-per-task="${ntomp}" \
            --output="${RESULTS_DIR}/%x_%j.out" \
            --error="${RESULTS_DIR}/%x_%j.err" \
            --export="${export_vars}" "${SLURM_SCRIPT}" 2>&1)
        echo "Submitted: ${run_id} -> ${job_id}"
    fi
    SUBMITTED=$((SUBMITTED + 1))
}

# Iterate over parameter space
for np in "${NP_VALUES[@]}"; do
    # Calculate ntomp to fill available cores
    local_ntomp=$((TOTAL_CORES / np))

    # Skip if ntomp would be 0
    if [[ ${local_ntomp} -lt 1 ]]; then
        continue
    fi

    for npme in "${NPME_VALUES[@]}"; do
        for gpu_comm in "${GPU_COMM_VALUES[@]}"; do
            for gpu_pme_decomp in "${GPU_PME_DECOMP_VALUES[@]}"; do
                submit_job "${np}" "${local_ntomp}" "${npme}" "${gpu_comm}" "${gpu_pme_decomp}"
            done
        done
    done
done

# Also test a few specific ntomp values for the most common np values
# to see if NOT filling all cores is faster (reduces thread overhead)
# Optimized targeted configurations based on benchmark findings:
# - UCX transport eliminates CUDA errors and doubles multi-rank performance
# - np=6 with nstlist=175 is the overall best (6.84 ns/day)
# - np=6 and np=8 strongly outperform np=1,2,4 with UCX
# - nstlist sweet spot is 150-200 (peaks at 175)
# - npme=1 is optimal; npme=2 requires cuFFTMp (unsupported)
EXTRA_CONFIGS=(
    # np  ntomp  npme  gpu_comm  gpu_pme_decomp  tunepme  nstlist  dlb
    # === Top configs from optimization passes ===
    # --- np=6 champion configs ---
    "6 13 1 yes no no 175 auto"
    "6 13 1 yes yes no 200 auto"
    "6 13 1 yes no no 200 auto"
    "6 13 1 yes no no 150 auto"
    "6 10 1 yes no no 200 auto"
    "6 8 1 yes no no 200 auto"
    # --- np=8 runner-up configs ---
    "8 10 1 yes no no 200 auto"
    "8 10 1 yes yes no 200 auto"
    "8 10 1 yes no no 150 auto"
    "8 10 1 yes no no 175 auto"
    "8 5 1 yes no no 200 auto"
    # --- np=4 with nstlist tuning ---
    "4 20 1 yes no no 200 auto"
    "4 20 1 yes yes no 200 auto"
    "4 20 1 yes no no 150 auto"
    "4 20 1 yes yes no 150 auto"
    "4 8 1 yes no no 0 auto"
    "4 8 1 yes yes no 0 auto"
    # --- np=2 with nstlist ---
    "2 40 0 yes no no 200 auto"
    "2 40 1 yes no no 200 auto"
    # --- np=1 baselines ---
    "1 40 0 yes no no 0 auto"
    "1 60 0 yes no no 0 auto"
    # --- np=10/12 for reference ---
    "10 8 1 yes no no 200 auto"
    "12 6 1 yes no no 200 auto"
)

echo ""
echo "--- Additional targeted configurations ---"
for config in "${EXTRA_CONFIGS[@]}"; do
    read -r np ntomp npme gpu_comm gpu_pme_decomp tunepme nstlist dlb <<< "${config}"
    submit_job "${np}" "${ntomp}" "${npme}" "${gpu_comm}" "${gpu_pme_decomp}" "${tunepme}" "${nstlist}" "${dlb}"
done

echo ""
echo "=========================================="
echo "Total jobs submitted: ${SUBMITTED}"
echo "=========================================="
echo ""
if [[ "${DRY_RUN}" == false ]]; then
    echo "Monitor progress with: squeue -u \$USER"
    echo "Analyze results with:  ./analyze_results.sh"
else
    echo "(Dry run - no jobs were actually submitted)"
fi
