#!/bin/bash
#SBATCH --job-name=ofbench-test
#SBATCH --partition=hpc
#SBATCH --ntasks-per-node=176
#SBATCH --exclusive
#SBATCH --time=02:00:00

# Multi-node OpenFOAM benchmark — Single solver test
# Submitted by benchmark_multinode.sh orchestrator.
# Environment variables expected:
#   PASS_DIR      — shared pass directory for all jobs
#   RESULTS_FILE  — shared CSV results file
#   TOTAL_CORES   — total MPI ranks (nodes × 176)
#   NNODES        — number of nodes
#   TEST_ID       — test number
#   TEST_CORES    — core count for this test
#   TEST_BIND     — bind-to value (e.g. core)
#   TEST_MAP      — map-by value (e.g. l3cache, slot, node)
#   TEST_EXTRA    — extra MPI flags (may be empty)
#   MESH_SIZE     — mesh size (L, XL, etc.)

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message"
}

extract_timing() {
    local log_file="$1"
    if [ ! -f "$log_file" ]; then
        echo "N/A,N/A,N/A"
        return
    fi
    local total_exec total_clock t1 t2 last_iter
    total_exec=$(grep "ExecutionTime" "$log_file" | tail -1 | awk '{print $3}') || true
    total_clock=$(grep "ClockTime" "$log_file" | tail -1 | awk '{print $(NF-1)}') || true
    t1=$(grep "ExecutionTime" "$log_file" | tail -2 | head -1 | awk '{print $3}') || true
    t2=$(grep "ExecutionTime" "$log_file" | tail -1 | awk '{print $3}') || true
    last_iter=$(echo "$t2 - $t1" | bc 2>/dev/null) || last_iter="N/A"
    echo "${total_exec:-N/A},${total_clock:-N/A},${last_iter:-N/A}"
}

# ---- OpenFOAM Environment Setup ----
source /cvmfs/software.eessi.io/versions/2023.06/init/bash
ml OpenFOAM
source $FOAM_BASH || true

export UCX_LOG_LEVEL=error

# ---- MPI Sanity Check ----
# SCRIPT_DIR is passed via --export from the orchestrator
source "${SCRIPT_DIR}/mpi_sanity_check.sh"
if ! run_mpi_sanity_check "$TOTAL_CORES" "$PASS_DIR"; then
    log "ERROR" "MPI sanity check failed — aborting test job"
    # Record failure in results CSV
    MESH_TIME=$(cat "${PASS_DIR}/mesh_time_${MESH_SIZE}.txt" 2>/dev/null || echo "N/A")
    test_name="test_${TEST_ID}_n${NNODES}_c${TEST_CORES}_${TEST_BIND}_${TEST_MAP}_${MESH_SIZE}"
    result_line="$TEST_ID,$MESH_SIZE,$NNODES,$TEST_CORES,$TEST_BIND,$TEST_MAP,$TEST_EXTRA,$MESH_TIME,FAIL,FAIL,FAIL,0,SANITY_FAIL"
    (
        flock -w 30 200
        echo "$result_line" >> "$RESULTS_FILE"
    ) 200>"${RESULTS_FILE}.lock"
    exit 1
fi

base_dir="${PASS_DIR}/base_c${TOTAL_CORES}_${MESH_SIZE}"
MESH_TIME=$(cat "${PASS_DIR}/mesh_time_${MESH_SIZE}.txt" 2>/dev/null || echo "N/A")

test_name="test_${TEST_ID}_n${NNODES}_c${TEST_CORES}_${TEST_BIND}_${TEST_MAP}_${MESH_SIZE}"
test_dir="${PASS_DIR}/${test_name}"

log "INFO" "========================================================"
log "INFO" "TEST $TEST_ID: nodes=$NNODES cores=$TEST_CORES bind=$TEST_BIND map=$TEST_MAP extra='$TEST_EXTRA'"
log "INFO" "Job ID: $SLURM_JOB_ID  Nodes: $SLURM_JOB_NODELIST"
log "INFO" "========================================================"

rm -rf "$test_dir"
cp -r "$base_dir" "$test_dir"
chmod -R u+w "$test_dir"
rm -f "$test_dir"/log.foamRun

export FOAM_MPIRUN_FLAGS="--bind-to $TEST_BIND --map-by $TEST_MAP $TEST_EXTRA"
log "INFO" "FOAM_MPIRUN_FLAGS=$FOAM_MPIRUN_FLAGS"

cd "$test_dir"
. "$WM_PROJECT_DIR/bin/tools/RunFunctions"

log "INFO" "Running solver..."
solver_start=$(date +%s)
runParallel "$(getApplication)" 2>&1
solver_rc=$?
solver_end=$(date +%s)
wall_time=$((solver_end - solver_start))

timing=$(extract_timing "$test_dir/log.foamRun")
IFS=',' read -r solver_exec solver_clock last_iter <<< "$timing"

if [ $solver_rc -eq 0 ] && [ -f "$test_dir/log.foamRun" ]; then
    log "INFO" "Solver completed: exec=${solver_exec}s clock=${solver_clock}s last_iter=${last_iter}s wall=${wall_time}s"
    result_line="$TEST_ID,$MESH_SIZE,$NNODES,$TEST_CORES,$TEST_BIND,$TEST_MAP,$TEST_EXTRA,$MESH_TIME,$solver_exec,$solver_clock,$last_iter,$wall_time,OK"
else
    log "ERROR" "Solver FAILED for test $TEST_ID (wall=${wall_time}s)"
    result_line="$TEST_ID,$MESH_SIZE,$NNODES,$TEST_CORES,$TEST_BIND,$TEST_MAP,$TEST_EXTRA,$MESH_TIME,${solver_exec:-FAIL},${solver_clock:-FAIL},${last_iter:-FAIL},$wall_time,SOLVER_FAIL"
fi

# Append to shared results CSV with file locking
(
    flock -w 30 200
    echo "$result_line" >> "$RESULTS_FILE"
) 200>"${RESULTS_FILE}.lock"

rm -rf "$test_dir"/processor*

log "INFO" "Test $TEST_ID complete"
