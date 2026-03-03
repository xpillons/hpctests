#!/bin/bash
#SBATCH --job-name=openfoam-mesh-opt
#SBATCH --partition=hpc
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=176
#SBATCH --exclusive
#SBATCH --time=04:00:00
#SBATCH --output=benchmark_mesh_opt_%j.out
#SBATCH --error=benchmark_mesh_opt_%j.err

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message"
}

# ---- OpenFOAM Environment Setup ----
source /cvmfs/software.eessi.io/versions/2023.06/init/bash
ml OpenFOAM
source $FOAM_BASH || true

export UCX_LOG_LEVEL=error

BENCH_DIR="$SLURM_SUBMIT_DIR/benchmark_mesh_opt_$SLURM_JOB_ID"
RESULTS_FILE="$SLURM_SUBMIT_DIR/benchmark_mesh_opt_results_$SLURM_JOB_ID.csv"
CASE_DIR="$FOAM_TUTORIALS/incompressibleFluid/drivaerFastback"
MESH_SIZE="M"
SOLVER_CORES=176
SOLVER_FLAGS="--bind-to core --map-by l3cache --mca pml ucx -x UCX_ZCOPY_THRESH=16384"

mkdir -p "$BENCH_DIR"

log "INFO" "============================================="
log "INFO" "OpenFOAM Mesh Optimization Benchmark"
log "INFO" "Job ID        : $SLURM_JOB_ID"
log "INFO" "Node          : $SLURM_JOB_NODELIST"
log "INFO" "Total cores   : $SLURM_NTASKS"
log "INFO" "Solver cores  : $SOLVER_CORES"
log "INFO" "Solver flags  : $SOLVER_FLAGS"
log "INFO" "Mesh size     : $MESH_SIZE"
log "INFO" "Bench dir     : $BENCH_DIR"
log "INFO" "Results file  : $RESULTS_FILE"
log "INFO" "============================================="

echo "test_id,mesh_cores,strategy,mesh_time_s,reconstruct_time_s,redecompose_time_s,solver_time_s,solver_clock_s,last_iter_time_s,total_wall_s,status" > "$RESULTS_FILE"

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

prepare_case() {
    local dest="$1"
    rm -rf "$dest"
    cp -r "$CASE_DIR" "$dest"
    chmod -R u+w "$dest"
    cd "$dest"
    for f in system/*.orig; do [ -f "$f" ] && cp "$f" "${f%.orig}"; done
}

nRefine=1
case "$MESH_SIZE" in
    S)  nRefine=0 ;;
    M)  nRefine=1 ;;
    L)  nRefine=2 ;;
    XL) nRefine=3 ;;
esac

# ===================================================================
# Test configurations:
#   A) "direct" — mesh and solve with same core count (176) — baseline
#   B) "remesh" — mesh with N cores, reconstructParMesh, re-decomposePar
#      to 176, then solve with 176.
#
# Mesh core counts to test: 8, 16, 32, 44, 64, 88, 176 (baseline)
# Each config tested twice for variance check.
# ===================================================================

MESH_CORE_COUNTS=(8 16 32 44 64 88 176)
REPEATS=2
TEST_ID=0

for mesh_cores in "${MESH_CORE_COUNTS[@]}"; do
    for rep in $(seq 1 $REPEATS); do
        TEST_ID=$((TEST_ID + 1))

        if [ "$mesh_cores" -eq "$SOLVER_CORES" ]; then
            strategy="direct"
        else
            strategy="remesh_${mesh_cores}"
        fi

        test_dir="${BENCH_DIR}/test_${TEST_ID}_mc${mesh_cores}_r${rep}"
        log "INFO" "========================================================"
        log "INFO" "TEST $TEST_ID: mesh_cores=$mesh_cores strategy=$strategy repeat=$rep"
        log "INFO" "========================================================"

        prepare_case "$test_dir"
        . "$WM_PROJECT_DIR/bin/tools/RunFunctions"

        # --- MESHING PHASE (with mesh_cores) ---
        foamDictionary -entry numberOfSubdomains -set "$mesh_cores" system/decomposeParDict
        export FOAM_MPIRUN_FLAGS="--bind-to core --map-by l3cache"

        mesh_start=$(date +%s)
        runApplication blockMesh
        runApplication decomposePar -copyZero

        r=0
        while [ $r -lt "$nRefine" ]; do
            runParallel -a refineMesh -overwrite
            r=$(( r + 1 ))
        done

        runParallel snappyHexMesh -overwrite
        mesh_end=$(date +%s)
        mesh_time=$((mesh_end - mesh_start))
        log "INFO" "Meshing done in ${mesh_time}s with $mesh_cores cores"

        # --- RECONSTRUCT + RE-DECOMPOSE (if mesh_cores != solver_cores) ---
        reconstruct_time=0
        redecompose_time=0

        if [ "$mesh_cores" -ne "$SOLVER_CORES" ]; then
            log "INFO" "Reconstructing mesh from $mesh_cores domains..."
            recon_start=$(date +%s)
            runParallel -a redistributePar -reconstruct
            recon_end=$(date +%s)
            reconstruct_time=$((recon_end - recon_start))
            log "INFO" "Reconstruct done in ${reconstruct_time}s"

            # Remove old processor directories
            rm -rf processor*

            log "INFO" "Re-decomposing to $SOLVER_CORES domains..."
            foamDictionary -entry numberOfSubdomains -set "$SOLVER_CORES" system/decomposeParDict
            redecomp_start=$(date +%s)
            runApplication -a decomposePar -copyZero
            redecomp_end=$(date +%s)
            redecompose_time=$((redecomp_end - redecomp_start))
            log "INFO" "Re-decompose done in ${redecompose_time}s"
        fi

        # --- SOLVER PHASE (always 176 cores) ---
        export FOAM_MPIRUN_FLAGS="$SOLVER_FLAGS"
        rm -f log.foamRun

        log "INFO" "Running solver with $SOLVER_CORES cores..."
        solver_start=$(date +%s)
        runParallel "$(getApplication)" 2>&1
        solver_rc=$?
        solver_end=$(date +%s)
        solver_wall=$((solver_end - solver_start))

        total_wall=$((mesh_time + reconstruct_time + redecompose_time + solver_wall))

        timing=$(extract_timing "$test_dir/log.foamRun")
        IFS=',' read -r solver_exec solver_clock last_iter <<< "$timing"

        if [ $solver_rc -eq 0 ] && [ -f "$test_dir/log.foamRun" ]; then
            log "INFO" "OK: mesh=${mesh_time}s recon=${reconstruct_time}s redecomp=${redecompose_time}s solver=${solver_exec}s total_wall=${total_wall}s"
            echo "$TEST_ID,$mesh_cores,$strategy,$mesh_time,$reconstruct_time,$redecompose_time,$solver_exec,$solver_clock,$last_iter,$total_wall,OK" >> "$RESULTS_FILE"
        else
            log "ERROR" "FAILED: test $TEST_ID (solver_rc=$solver_rc)"
            echo "$TEST_ID,$mesh_cores,$strategy,$mesh_time,$reconstruct_time,$redecompose_time,${solver_exec:-FAIL},${solver_clock:-FAIL},${last_iter:-FAIL},$total_wall,FAIL" >> "$RESULTS_FILE"
        fi

        # Cleanup processor dirs to save space
        rm -rf "$test_dir"/processor*
        log "INFO" "Test $TEST_ID complete"
        log "INFO" ""
    done
done

log "INFO" "============================================="
log "INFO" "ALL MESH OPTIMIZATION BENCHMARKS COMPLETE"
log "INFO" "============================================="
log "INFO" ""
log "INFO" "Results summary:"
echo ""
column -t -s',' "$RESULTS_FILE"
