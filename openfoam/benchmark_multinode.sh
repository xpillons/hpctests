#!/bin/bash
set -euo pipefail

# Multi-node OpenFOAM benchmark — Pass 6 (Orchestrator)
# Runs on login node. Submits one mesh job + one Slurm job per test config.
#
# Usage: ./benchmark_multinode.sh <num_nodes>
#   e.g. ./benchmark_multinode.sh 2
#        ./benchmark_multinode.sh 4
#
# Single-node reference (Pass 4/5, L mesh, 176 cores, 1 node):
#   Best config: --bind-to core --map-by l3cache --mca pml ucx -x UCX_ZCOPY_THRESH=16384
#   Best solver: 1893s (Job 1232)  Mean: 1896s  Wall: 1997s
#   Mesh time:   ~690s
#
# This script tests multi-node scaling with the winning single-node config
# as baseline, plus inter-node communication variants.

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message"
}

NNODES="${1:?Usage: $0 <num_nodes>}"
CORES_PER_NODE=176
TOTAL_CORES=$((NNODES * CORES_PER_NODE))
MESH_SIZES=(L XL)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PASS_DIR="${SCRIPT_DIR}/benchmark_mn${NNODES}_${TIMESTAMP}"
RESULTS_FILE="${PASS_DIR}/results.csv"

mkdir -p "$PASS_DIR"

log "INFO" "============================================="
log "INFO" "OpenFOAM Multi-Node MPI Benchmark — Pass 7"
log "INFO" "Nodes        : $NNODES"
log "INFO" "Total cores  : $TOTAL_CORES (${NNODES}x${CORES_PER_NODE})"
log "INFO" "Mesh sizes   : ${MESH_SIZES[*]}"
log "INFO" "Pass dir     : $PASS_DIR"
log "INFO" "Results file : $RESULTS_FILE"
log "INFO" "============================================="
log "INFO" ""
log "INFO" "Single-node reference (176 cores, L mesh):"
log "INFO" "  Best solver: 1893s  Mean: 1896s  Wall: 1997s"
log "INFO" "  Config: core/l3cache + UCX_ZCOPY_THRESH=16384"
log "INFO" ""

# Write CSV header (includes mesh_size column)
echo "test_id,mesh_size,nodes,cores,bind_to,map_by,extra_flags,mesh_time_s,solver_time_s,solver_clock_s,last_iter_time_s,wall_time_s,status" > "$RESULTS_FILE"

# ===================================================================
# PHASE 1 & 2: For each mesh size, submit mesh job + solver tests
# ===================================================================

TOTAL_TESTS=0
TOTAL_MESH_JOBS=0
TEST_ID=0

for MESH_SIZE in "${MESH_SIZES[@]}"; do

log "INFO" "--- Mesh size: $MESH_SIZE ---"

# ===================================================================
# PHASE 1: Submit mesh job for this mesh size
# ===================================================================
log "INFO" "Submitting mesh job ($NNODES nodes, $TOTAL_CORES cores, $MESH_SIZE mesh)..."

MESH_JOB_ID=$(sbatch --parsable \
    --nodes="$NNODES" \
    --ntasks-per-node="$CORES_PER_NODE" \
    --output="${PASS_DIR}/mesh_${MESH_SIZE}_%j.out" \
    --error="${PASS_DIR}/mesh_${MESH_SIZE}_%j.err" \
    --export="ALL,PASS_DIR=${PASS_DIR},TOTAL_CORES=${TOTAL_CORES},MESH_SIZE=${MESH_SIZE},NNODES=${NNODES},SCRIPT_DIR=${SCRIPT_DIR}" \
    "${SCRIPT_DIR}/benchmark_mn_mesh.sh")

TOTAL_MESH_JOBS=$((TOTAL_MESH_JOBS + 1))
log "INFO" "Mesh job submitted: $MESH_JOB_ID ($MESH_SIZE)"

# ===================================================================
# PHASE 2: Submit solver test jobs (depend on this mesh completion)
# ===================================================================
#
# Single-node reference (Pass 4/5, 176 cores, L mesh ~22.5M cells):
#   176 core/l3cache + ZCOPY=16384: best 1893s, mean 1896s, wall 1997s
#   176 core/slot + ZCOPY=16384:    best 1959s, mean 1980s, wall 2064s
#   176 core/slot (no UCX):         best 1976s, mean 1983s, wall 2091s
#   128 core/l3cache + ZCOPY=16384: best 2028s, mean 2032s, wall 2102s
#
# Multi-node tests:
#   - Baseline with winning single-node config (3x for reference)
#   - map-by variants (l3cache vs slot vs node for multi-node distribution)
#   - Inter-node UCX transport selection (rc, dc, ud)
#   - UCX memory registration and ZCOPY thresholds
#   - rank-by options (slot vs node: fill-first vs round-robin)
#   - ppr placement for balanced distribution
#   - Combined best guesses

REPEATS=7  # Number of repeats per config for statistical confidence

# Each unique config is listed once; the submission loop repeats it $REPEATS times.
UNIQUE_CONFIGS=(
    # Baseline — winning single-node config
    "${TOTAL_CORES}|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384"

    # map-by slot (fill one node first, then next)
    "${TOTAL_CORES}|core|slot|--mca pml ucx -x UCX_ZCOPY_THRESH=16384"

    # map-by node (round-robin across nodes — interleaves ranks)
    "${TOTAL_CORES}|core|node|--mca pml ucx -x UCX_ZCOPY_THRESH=16384"

    # map-by socket (2 sockets per node, 88 cores each)
    "${TOTAL_CORES}|core|socket|--mca pml ucx -x UCX_ZCOPY_THRESH=16384"

    # map-by numa (4 NUMA nodes per node)
    "${TOTAL_CORES}|core|numa|--mca pml ucx -x UCX_ZCOPY_THRESH=16384"

    # l3cache + explicit UCX transport (self,sm for intra-node, rc for inter-node)
    "${TOTAL_CORES}|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,sm,rc"

    # l3cache + dc transport (dynamically connected — better for many-to-many)
    "${TOTAL_CORES}|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,sm,dc"

    # l3cache + pin to mlx5 IB device
    "${TOTAL_CORES}|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_NET_DEVICES=mlx5_ib0:1"

    # l3cache + ZCOPY variants for inter-node
    "${TOTAL_CORES}|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=8192"

    # l3cache + larger RNDV threshold (delay rendezvous for inter-node)
    "${TOTAL_CORES}|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_RNDV_THRESH=65536"

    # slot + no UCX extras (vanilla multi-node)
    "${TOTAL_CORES}|core|slot|"

    # l3cache + pure UCX path (disable legacy BTLs)
    "${TOTAL_CORES}|core|l3cache|--mca pml ucx --mca btl ^vader,tcp,openib -x UCX_ZCOPY_THRESH=16384"

    # l3cache + CMA for intra-node shared memory
    "${TOTAL_CORES}|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,cma,rc"

    # combined best guess — rc + IB pin + ZCOPY
    "${TOTAL_CORES}|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_TLS=self,sm,rc -x UCX_NET_DEVICES=mlx5_ib0:1"

    # l3cache + multi-rail IB (if available)
    "${TOTAL_CORES}|core|l3cache|--mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_IB_NUM_PATHS=2"
)

# Build full CONFIGS array by repeating each unique config $REPEATS times
CONFIGS=()
for config in "${UNIQUE_CONFIGS[@]}"; do
    for ((r = 0; r < REPEATS; r++)); do
        CONFIGS+=("$config")
    done
done

log "INFO" "${#UNIQUE_CONFIGS[@]} unique configs × ${REPEATS} repeats = ${#CONFIGS[@]} tests for $MESH_SIZE mesh"

MESH_TEST_JOB_IDS=()

for config in "${CONFIGS[@]}"; do
    IFS='|' read -r ncores bind_to map_by extra_flags <<< "$config"
    extra_flags="${extra_flags:-}"
    TEST_ID=$((TEST_ID + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    test_job_id=$(sbatch --parsable \
        --nodes="$NNODES" \
        --ntasks-per-node="$CORES_PER_NODE" \
        --dependency="afterok:${MESH_JOB_ID}" \
        --output="${PASS_DIR}/test_${MESH_SIZE}_${TEST_ID}_%j.out" \
        --error="${PASS_DIR}/test_${MESH_SIZE}_${TEST_ID}_%j.err" \
        --export="ALL,PASS_DIR=${PASS_DIR},RESULTS_FILE=${RESULTS_FILE},TOTAL_CORES=${ncores},NNODES=${NNODES},TEST_ID=${TEST_ID},TEST_CORES=${ncores},TEST_BIND=${bind_to},TEST_MAP=${map_by},TEST_EXTRA=${extra_flags},MESH_SIZE=${MESH_SIZE},SCRIPT_DIR=${SCRIPT_DIR}" \
        "${SCRIPT_DIR}/benchmark_mn_test.sh")

    MESH_TEST_JOB_IDS+=("$test_job_id")
    log "INFO" "Test $TEST_ID [$MESH_SIZE] submitted: job=$test_job_id cores=$ncores bind=$bind_to map=$map_by extra='$extra_flags'"
done

# Submit a cleanup job that cancels all test jobs if the mesh job fails.
# Runs on a single core, takes seconds — just calls scancel.
CANCEL_LIST=$(IFS=,; echo "${MESH_TEST_JOB_IDS[*]}")
CLEANUP_JOB_ID=$(sbatch --parsable \
    --nodes=1 \
    --ntasks=1 \
    --dependency="afternotok:${MESH_JOB_ID}" \
    --output="${PASS_DIR}/cleanup_${MESH_SIZE}_%j.out" \
    --time=00:01:00 \
    --wrap="echo 'Mesh job ${MESH_JOB_ID} (${MESH_SIZE}) failed — cancelling ${#MESH_TEST_JOB_IDS[@]} dependent test jobs'; scancel ${CANCEL_LIST//,/ }")
log "INFO" "Cleanup job submitted: $CLEANUP_JOB_ID (cancels ${#MESH_TEST_JOB_IDS[@]} tests if mesh $MESH_JOB_ID fails)"

done  # end mesh size loop

log "INFO" ""
log "INFO" "============================================="
log "INFO" "ALL JOBS SUBMITTED ($TOTAL_TESTS tests + $TOTAL_MESH_JOBS mesh jobs)"
log "INFO" "Mesh sizes: ${MESH_SIZES[*]}"
log "INFO" "Pass dir: $PASS_DIR"
log "INFO" "Results:  $RESULTS_FILE"
log "INFO" "============================================="
log "INFO" ""
log "INFO" "Monitor with: squeue -u \$USER"
log "INFO" "View results: column -t -s',' $RESULTS_FILE"
