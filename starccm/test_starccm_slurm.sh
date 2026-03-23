#!/bin/bash
###############################################################################
# StarCCM+ Slurm Integration Test Suite
#
# Submits one 2-node job per option combination to verify that starccm.slurm
# runs correctly under Slurm with various MPI/fabric/tuning settings.
# Each job runs exactly 100 iterations using the run_iterations.java macro.
#
# Usage:
#   ./test_starccm_slurm.sh [MODEL_PATH]
#
# After submission, monitor with:
#   squeue -u $USER -n "test-*"
#
# When all jobs complete, run:
#   ./test_starccm_slurm.sh --check <RUN_DIR>
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLURM_SCRIPT="${SCRIPT_DIR}/starccm.slurm"
MACRO="${SCRIPT_DIR}/macros/run_iterations.java"
ITERATIONS=100
NODES=2

# --- Default model -----------------------------------------------------------
MODEL=${1:-/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim}

# ---------- Check mode -------------------------------------------------------
if [[ "${1:-}" == "--check" ]]; then
    RUN_DIR="${2:?Usage: $0 --check <RUN_DIR>}"
    echo "============================================================"
    echo "Checking test results in: ${RUN_DIR}"
    echo "============================================================"
    PASS=0
    FAIL=0
    for dir in "${RUN_DIR}"/test-*; do
        [ -d "${dir}" ] || continue
        label=$(basename "${dir}")
        outfiles=("${dir}"/*.out)
        errfiles=("${dir}"/*.err)

        if [ ! -f "${outfiles[0]}" ]; then
            echo "  PENDING : ${label}  (no output yet)"
            continue
        fi

        # Check for successful completion
        if grep -q "=== Simulation complete at iteration" "${outfiles[0]}" 2>/dev/null; then
            final_iter=$(grep "Simulation complete at iteration" "${outfiles[0]}" | grep -oP 'iteration \K[0-9]+')
            echo -e "  \033[32mPASS\033[0m : ${label}  (completed at iteration ${final_iter})"
            PASS=$(( PASS + 1 ))
        elif grep -qi "error\|fatal\|abort\|exception" "${errfiles[0]}" 2>/dev/null; then
            errmsg=$(head -5 "${errfiles[0]}")
            echo -e "  \033[31mFAIL\033[0m : ${label}"
            echo "         ${errmsg}"
            FAIL=$(( FAIL + 1 ))
        else
            echo "  RUNNING : ${label}  (no completion marker yet)"
        fi
    done
    TOTAL=$(( PASS + FAIL ))
    echo ""
    echo "============================================================"
    echo "  Checked: ${TOTAL}   Passed: ${PASS}   Failed: ${FAIL}"
    echo "============================================================"
    exit "${FAIL}"
fi

# ---------- Pre-flight checks ------------------------------------------------
if [ ! -f "${SLURM_SCRIPT}" ]; then
    echo "ERROR: Slurm script not found: ${SLURM_SCRIPT}"
    exit 1
fi

if [ ! -f "${MACRO}" ]; then
    echo "ERROR: Macro not found: ${MACRO}"
    exit 1
fi

if [ ! -f "${MODEL}" ]; then
    echo "ERROR: Model file not found: ${MODEL}"
    exit 1
fi

# ---------- Test matrix -------------------------------------------------------
# Format: "MPI|FABRIC|CPUBIND|LABEL|STARCCM_HPCX|XSYSTEMUCX|UCX_TLS|MPPFLAGS|UCX_ENVS"
#
# Each row is a distinct option combination to validate.
TESTS=(
    # --- A. Defaults: OpenMPI, no fabric, bandwidth binding ---
    "openmpi||bandwidth|defaults|||||"

    # --- B. OpenMPI + UCX fabric ---
    "openmpi|ucx|bandwidth|openmpi-ucx|||||"

    # --- C. OpenMPI + CPUBIND off ---
    "openmpi||off|cpubind-off|||||"

    # --- D. HPCX only (bundled UCX) ---
    "openmpi|ucx|bandwidth|hpcx-only|1||||"

    # --- E. HPCX + UCX + system UCX ---
    "openmpi|ucx|off|hpcx-sysucx|1|1|||"

    # --- E. HPCX + UCX + NUMA mapping (44 ranks/NUMA = 176/node on 4 NUMA domains) ---
    "openmpi|ucx|off|hpcx-numa|1|1||--map-by ppr:44:numa --bind-to core|"

    # --- F. HPCX + UCX + UCX_TLS=rc,sm ---
    "openmpi|ucx|off|hpcx-rc-sm|1|1|rc,sm|--map-by ppr:44:numa --bind-to core|"

    # --- G. HPCX + UCX + UCX tuning envs ---
    "openmpi|ucx|off|hpcx-ucx-tuned|1|1|rc,sm|--map-by ppr:44:numa --bind-to core|UCX_RNDV_THRESH=8192 UCX_RNDV_SCHEME=put_zcopy"

    # --- H. Intel MPI ---
    "intel||bandwidth|intel-mpi|||||"
)

# ---------- Create timestamped run directory ----------------------------------
RUN_TS=$(date +%Y%m%d_%H%M%S)
RUN_DIR="${SCRIPT_DIR}/test_runs/${RUN_TS}"
mkdir -p "${RUN_DIR}"

# ---------- Submit jobs -------------------------------------------------------
echo "============================================================"
echo "StarCCM+ Slurm Integration Tests"
echo "============================================================"
echo "Slurm script : ${SLURM_SCRIPT}"
echo "Macro        : ${MACRO}"
echo "Model        : $(basename "${MODEL}")"
echo "Nodes        : ${NODES}"
echo "Iterations   : ${ITERATIONS}"
echo "Test count   : ${#TESTS[@]}"
echo "Run dir      : ${RUN_DIR}"
echo "============================================================"
echo ""

JOBIDS=()

for combo in "${TESTS[@]}"; do
    IFS='|' read -r mpi fabric cpubind label hpcx sysucx ucx_tls mppflags ucx_envs <<< "${combo}"

    # Create per-test working directory
    TEST_DIR="${RUN_DIR}/test-${label}"
    mkdir -p "${TEST_DIR}"

    # Write iteration count for the macro
    echo "${ITERATIONS}" > "${TEST_DIR}/iterations.txt"

    echo -n "Submitting: ${label} (mpi=${mpi}"
    [ -n "${fabric}" ]   && echo -n ", fabric=${fabric}"
    [ -n "${cpubind}" ] && [ "${cpubind}" != "off" ] && echo -n ", cpubind=${cpubind}"
    [ -n "${hpcx}" ]     && echo -n ", hpcx"
    [ -n "${sysucx}" ]   && echo -n ", sysucx"
    [ -n "${ucx_tls}" ]  && echo -n ", ucx_tls=${ucx_tls}"
    [ -n "${mppflags}" ] && echo -n ", mppflags"
    [ -n "${ucx_envs}" ] && echo -n ", ucx_envs"
    echo ")"

    # Build env array — only include non-empty optional vars
    ENV_ARGS=(
        MODEL="${MODEL}"
        MPI="${mpi}"
        CPUBIND="${cpubind}"
        BATCH_MACRO="${MACRO}"
        WORKDIR="${TEST_DIR}"
    )
    [ -n "${fabric}" ]   && ENV_ARGS+=(FABRIC="${fabric}")
    [ -n "${hpcx}" ]     && ENV_ARGS+=(STARCCM_HPCX="${hpcx}")
    [ -n "${sysucx}" ]   && ENV_ARGS+=(XSYSTEMUCX="${sysucx}")
    [ -n "${ucx_tls}" ]  && ENV_ARGS+=(UCX_TLS="${ucx_tls}")
    [ -n "${mppflags}" ] && ENV_ARGS+=(MPPFLAGS="${mppflags}")
    [ -n "${ucx_envs}" ] && ENV_ARGS+=(UCX_ENVS="${ucx_envs}")

    JOBID=$(
        env "${ENV_ARGS[@]}" \
        sbatch --parsable \
            --job-name="test-${label}" \
            --nodes="${NODES}" \
            --chdir="${TEST_DIR}" \
            --output="${TEST_DIR}/%x-%j.out" \
            --error="${TEST_DIR}/%x-%j.err" \
            "${SLURM_SCRIPT}"
    )

    echo "  → Job ${JOBID}"
    JOBIDS+=("${JOBID}:${label}")
done

# ---------- Summary -----------------------------------------------------------
echo ""
echo "============================================================"
echo "All ${#TESTS[@]} test jobs submitted"
echo "============================================================"
printf "  %-12s  %s\n" "JOB ID" "TEST"
printf "  %-12s  %s\n" "------" "----"
for entry in "${JOBIDS[@]}"; do
    IFS=':' read -r jid jlabel <<< "${entry}"
    printf "  %-12s  %s\n" "${jid}" "${jlabel}"
done

echo ""
echo "Monitor:  squeue -u \$USER -n 'test-*'"
echo "Check:    $0 --check ${RUN_DIR}"
echo ""
