#!/bin/bash
#SBATCH --job-name=openfoam-bench
#SBATCH --partition=hpc
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=176
#SBATCH --exclusive
#SBATCH --time=12:00:00
#SBATCH --output=benchmark_%j.out
#SBATCH --error=benchmark_%j.err

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

BENCH_DIR="$SLURM_SUBMIT_DIR/benchmark_$SLURM_JOB_ID"
RESULTS_FILE="$SLURM_SUBMIT_DIR/benchmark_results_$SLURM_JOB_ID.csv"
CASE_DIR="$FOAM_TUTORIALS/incompressibleFluid/drivaerFastback"
MESH_SIZE="L"

mkdir -p "$BENCH_DIR"

log "INFO" "============================================="
log "INFO" "OpenFOAM MPI Benchmark"
log "INFO" "Job ID       : $SLURM_JOB_ID"
log "INFO" "Node         : $SLURM_JOB_NODELIST"
log "INFO" "Total cores  : $SLURM_NTASKS"
log "INFO" "Mesh size    : $MESH_SIZE"
log "INFO" "Bench dir    : $BENCH_DIR"
log "INFO" "Results file : $RESULTS_FILE"
log "INFO" "============================================="

echo "test_id,cores,bind_to,map_by,extra_flags,mesh_time_s,solver_time_s,solver_clock_s,last_iter_time_s,wall_time_s,status" > "$RESULTS_FILE"

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

# ===================================================================
# PHASE 1: Create meshed base cases for each core count
# ===================================================================
# Pass 1 (Job 1226) core counts: (176 128 96 88 64 44 32) — M mesh
# Pass 2 (Job 1227) core counts: (112 120 128 132 140 144 160 176) — M mesh
# Pass 3 (Job 1228) core counts: (128 176) — M mesh, 3 repeats
# Pass 4 (Job 1230) core counts: (128 176) — L mesh, top 3 configs, 3 repeats
# Pass 5: 176 only, L mesh, UCX deep-dive around the winning config
CORE_COUNTS=(176)

declare -A MESH_BASE_DIR
declare -A MESH_TIME

for ncores in "${CORE_COUNTS[@]}"; do
    base_dir="${BENCH_DIR}/base_c${ncores}"
    log "INFO" "Preparing meshed base case for $ncores cores -> $base_dir"

    rm -rf "$base_dir"
    cp -r "$CASE_DIR" "$base_dir"
    chmod -R u+w "$base_dir"

    cd "$base_dir"
    . "$WM_PROJECT_DIR/bin/tools/RunFunctions"

    # Restore .orig files to their proper names (OpenFOAM tutorial convention)
    for orig_file in system/*.orig; do
        [ -f "$orig_file" ] && cp "$orig_file" "${orig_file%.orig}"
    done

    # Set numberOfSubdomains for this core count
    foamDictionary -entry numberOfSubdomains -set "$ncores" system/decomposeParDict

    export FOAM_MPIRUN_FLAGS="--bind-to core --map-by l3cache"

    nRefine=1
    case "$MESH_SIZE" in
        S)  nRefine=0 ;;
        M)  nRefine=1 ;;
        L)  nRefine=2 ;
            foamDictionary -entry endTime -set 2000 system/controlDict
            ;;
        XL) nRefine=3 ;
            foamDictionary -entry endTime -set 2000 system/controlDict
            ;;
    esac

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

    MESH_BASE_DIR[$ncores]="$base_dir"
    MESH_TIME[$ncores]=$mesh_time
    log "INFO" "Meshing for $ncores cores completed in ${mesh_time}s"
done

# ===================================================================
# PHASE 2: Run solver benchmarks with different MPI configurations
# ===================================================================
#
# Pass 1 (Job 1226, M mesh) configs — best was 128/core/slot at 89.75s:
#   (broad sweep 32-176 cores, binding/mapping variants)
#
# Pass 2 (Job 1227, M mesh) configs — best was 176/core/slot at 82.0s solver:
#   (fine sweep 112-176 cores, 128-core binding/mapping/transport variants)
#
# Pass 3 (Job 1228, M mesh) top 3 by solver time (3 repeats each):
#   1. 176 core/l3cache + ZCOPY=16384: 81.0/82.8/83.9s (best/mean/worst)
#   2. 176 core/slot + ZCOPY=16384:    81.7/82.7/83.2s
#   3. 176 core/slot (baseline):       83.1/84.5/85.7s
#
# Pass 4 (Job 1230, L mesh) top results (3 repeats each):
#   1. 176 core/l3cache + ZCOPY=16384: 1898/1902/1904s (best/mean/worst)
#   2. 176 core/slot + ZCOPY=16384:    1959/1980/1994s
#   3. 176 core/slot (baseline):       1976/1983/1994s
#   4. 128 core/l3cache + ZCOPY=16384: 2028/2032/2034s
#   l3cache gave 4.1% improvement over slot at 176 cores on L mesh
#
# Pass 5: UCX deep-dive at 176 cores + core/l3cache on L mesh
# Baseline: 176 core/l3cache + ZCOPY=16384 = 1898-1904s
# Testing: transport layers, rendezvous thresholds, eager limits,
#          memory registration, shared memory, network devices
CONFIGS=(
    # --- Baseline (3x for reference) ---
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384"
    # --- UCX_ZCOPY_THRESH variants ---
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=8192"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=8192"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=32768"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=32768"
    # --- UCX_RNDV_THRESH (rendezvous protocol threshold) ---
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_RNDV_THRESH=8192"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_RNDV_THRESH=8192"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_RNDV_THRESH=16384"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_RNDV_THRESH=16384"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_RNDV_THRESH=65536"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_RNDV_THRESH=65536"
    # --- UCX transport layer selection ---
    # self,sm,rc = shared mem + reliable connected (InfiniBand)
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,sm,rc"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,sm,rc"
    # self,sm,rc + pin to mlx5 device
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,sm,rc -x UCX_NET_DEVICES=mlx5_ib0:1"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,sm,rc -x UCX_NET_DEVICES=mlx5_ib0:1"
    # self,sm,ud = unreliable datagram (lower overhead for small msgs)
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,sm,ud"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,sm,ud"
    # self,sm,dc = dynamically connected (scales better with many ranks)
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,sm,dc"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,sm,dc"
    # --- Shared memory optimization ---
    # CMA (cross-memory attach) for intra-node
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,cma,rc"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,cma,rc"
    # KNEM for intra-node (if available)
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,shm,rc"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,shm,rc"
    # --- UCX_RNDV_SCHEME (rendezvous protocol variant) ---
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_RNDV_SCHEME=get_zcopy"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_RNDV_SCHEME=get_zcopy"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_RNDV_SCHEME=put_zcopy"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_RNDV_SCHEME=put_zcopy"
    # --- Disable BTL explicitly (ensure pure UCX path) ---
    "176|core|l3cache|--mca pml ucx --mca btl ^vader,tcp,openib -x UCX_ZCOPY_THRESH=16384"
    "176|core|l3cache|--mca pml ucx --mca btl ^vader,tcp,openib -x UCX_ZCOPY_THRESH=16384"
    # --- Combined best guesses ---
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_RNDV_THRESH=8192 -x UCX_TLS=self,sm,rc"
    "176|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_RNDV_THRESH=8192 -x UCX_TLS=self,sm,rc"
)

TEST_ID=0

for config in "${CONFIGS[@]}"; do
    IFS='|' read -r ncores bind_to map_by extra_flags <<< "$config"
    extra_flags="${extra_flags:-}"
    TEST_ID=$((TEST_ID + 1))

    test_name="test_${TEST_ID}_c${ncores}_${bind_to}_${map_by}"
    test_dir="${BENCH_DIR}/${test_name}"
    base_dir="${MESH_BASE_DIR[$ncores]}"

    log "INFO" "========================================================"
    log "INFO" "TEST $TEST_ID: cores=$ncores bind=$bind_to map=$map_by extra='$extra_flags'"
    log "INFO" "========================================================"

    rm -rf "$test_dir"
    cp -r "$base_dir" "$test_dir"
    chmod -R u+w "$test_dir"
    rm -f "$test_dir/log.foamRun"

    mesh_time="${MESH_TIME[$ncores]}"

    export FOAM_MPIRUN_FLAGS="--bind-to $bind_to --map-by $map_by $extra_flags"
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
        echo "$TEST_ID,$ncores,$bind_to,$map_by,$extra_flags,$mesh_time,$solver_exec,$solver_clock,$last_iter,$wall_time,OK" >> "$RESULTS_FILE"
    else
        log "ERROR" "Solver FAILED for test $TEST_ID (wall=${wall_time}s)"
        echo "$TEST_ID,$ncores,$bind_to,$map_by,$extra_flags,$mesh_time,${solver_exec:-FAIL},${solver_clock:-FAIL},${last_iter:-FAIL},$wall_time,SOLVER_FAIL" >> "$RESULTS_FILE"
    fi

    rm -rf "$test_dir"/processor*

    log "INFO" "Test $TEST_ID complete"
    log "INFO" ""
done

log "INFO" "============================================="
log "INFO" "ALL BENCHMARKS COMPLETE"
log "INFO" "============================================="
log "INFO" ""
log "INFO" "Results summary:"
echo ""
column -t -s',' "$RESULTS_FILE"
