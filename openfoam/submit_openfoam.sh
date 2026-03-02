#!/bin/bash
#SBATCH --job-name=openfoam-case
#SBATCH --partition=hpc
#SBATCH --ntasks-per-node=176
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=openfoam_%j.out
#SBATCH --error=openfoam_%j.err
#
# Usage:
#   sbatch --nodes=1 submit_openfoam.sh              # single node, default M mesh
#   sbatch --nodes=1 submit_openfoam.sh L             # single node, L mesh
#   sbatch --nodes=4 submit_openfoam.sh XL            # 4 nodes, XL mesh
#   sbatch --nodes=2 submit_openfoam.sh L             # 2 nodes, L mesh

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message"
}

# ---- Mesh size parameter ----
# Accept mesh size as first argument (S, M, L, XL). Default: M
MESH_SIZE="${1:-M}"
case "$MESH_SIZE" in
    S|M|L|XL) ;;
    *) echo "ERROR: Invalid mesh size '$MESH_SIZE'. Must be S, M, L, or XL."; exit 1 ;;
esac

# ---- OpenFOAM Environment Setup ----
source /cvmfs/software.eessi.io/versions/2023.06/init/bash
ml OpenFOAM
source $FOAM_BASH || true

# ---- MPI Configuration ----
# Note: HPCX MPI from the node image cannot be used with EESSI OpenFOAM due to:
#   1. HPCX libmpi.so requires GLIBC_2.38 but EESSI compat layer provides older glibc
#   2. HPCX mpirun (4.1.9a1) has ORTE wire protocol mismatch with EESSI OpenMPI (4.1.5)
#   3. EESSI binaries have RPATH baked in, preventing LD_LIBRARY_PATH override
# Using EESSI OpenMPI with UCX warnings suppressed.
#
# Benchmark results (drivaerFastback, HB176rs_v4, AMD EPYC 9V33X):
#
# --- Single-node (Passes 1-5, L mesh ~22.5M cells, 2000 iterations) ---
#   Pass 1 (Job 1226): broad sweep 32-176 cores — 128 cores appeared best (bug: .orig files not restored)
#   Pass 2 (Job 1227): fine sweep 112-176 cores (bug fixed) — scaling monotonic, 176 fastest solver
#   Pass 3 (Job 1228): 3 repeats per config, M mesh, 128 vs 176 cores:
#     176 core/l3cache + ZCOPY=16384: 81.0-83.9s solver, 100-103s wall  <-- BEST
#     176 core/slot    + ZCOPY=16384: 81.7-83.2s solver, 100-105s wall
#     176 core/slot    (baseline)   : 83.1-85.7s solver, 102-106s wall
#     128 core/l3cache (baseline)   : 89.0-91.1s solver, 103-105s wall
#     128 core/slot    (baseline)   : 90.1-91.7s solver, 104-105s wall
#   Pass 4 (Job 1230): L mesh, 3 repeats, 128 vs 176 cores:
#     176 l3cache+ZCOPY: 1898-1904s (mean 1902), 128 l3cache+ZCOPY: 2028-2034s
#     l3cache advantage 4.1% on L mesh (vs <1% on M mesh)
#   Pass 5 (Job 1232): UCX deep-dive at 176/l3cache on L mesh (17/33 tests):
#     All UCX variants within 1893-1912s (1% spread). ZCOPY=16384 confirmed optimal.
#   Best single-node: 1893s solver, 1997s wall (176 cores)
#
# --- Multi-node (Pass 6+7, L & XL mesh, 2000 iterations) ---
#   2-node / 352 cores (31 tests, all completed):
#     l3cache+ZCOPY=16384 (baseline): best 808s, mean 820s  <-- BEST (within noise)
#     l3cache+dc transport:           best 804s (within noise of baseline)
#     l3cache+btl disabled:           best 803s (within noise of baseline)
#     node mapping:                   best 816s
#     Scaling: 1893s -> 808s = 2.34x on 2x cores (117% efficiency)
#   4-node / 704 cores (210 tests, L + XL mesh):
#     L mesh best configs (avg solver time):
#       l3cache+ZCOPY+IB_NUM_PATHS=2: 397.0s (stdev 7.3)   <-- BEST L
#       l3cache+btl ^vader:           403.5s (stdev 15.0)
#       slot (no flags):              404.1s (stdev 9.5)
#       l3cache+ZCOPY=16384:          428.1s (stdev 36.0)
#     XL mesh best configs (avg solver time):
#       node+ZCOPY=16384:             2450.5s (stdev 22.6)  <-- BEST XL
#       l3cache+ZCOPY=16384:          2460.4s (stdev 32.6)
#       slot+ZCOPY=16384:             2467.6s (stdev 45.1)
#     Scaling L:  1893s -> 397s = 4.77x on 4x cores (119% efficiency)
#     Scaling XL: 4-node XL best 2421s
#   6-node and 8-node: failed (DNS resolution issue with .ccw.hpc.local FQDN)
#
# MPI flags are selected based on mesh size and node count:
#   Single-node (all meshes): l3cache + UCX_ZCOPY_THRESH=16384
#   Multi-node L mesh:        l3cache + UCX_ZCOPY_THRESH=16384 + UCX_IB_NUM_PATHS=2
#   Multi-node XL mesh:       node    + UCX_ZCOPY_THRESH=16384
#   Multi-node S/M mesh:      l3cache + UCX_ZCOPY_THRESH=16384 (same as single-node)

if [[ "${SLURM_JOB_NUM_NODES:-1}" -eq 1 ]]; then
    # Single-node: l3cache mapping is optimal for all mesh sizes
    export FOAM_MPIRUN_FLAGS="--bind-to core --map-by l3cache --mca pml ucx -x UCX_ZCOPY_THRESH=16384"
else
    # Multi-node: select flags based on mesh size
    case "$MESH_SIZE" in
        L)
            # l3cache + IB_NUM_PATHS=2: best avg 397s, lowest variance (stdev 7.3)
            export FOAM_MPIRUN_FLAGS="--bind-to core --map-by l3cache --mca pml ucx -x UCX_ZCOPY_THRESH=16384 -x UCX_IB_NUM_PATHS=2"
            ;;
        XL)
            # node mapping: best avg 2450s on 4-node XL (stdev 22.6)
            export FOAM_MPIRUN_FLAGS="--bind-to core --map-by node --mca pml ucx -x UCX_ZCOPY_THRESH=16384"
            ;;
        *)
            # S/M: use single-node baseline (no multi-node data for these sizes)
            export FOAM_MPIRUN_FLAGS="--bind-to core --map-by l3cache --mca pml ucx -x UCX_ZCOPY_THRESH=16384"
            ;;
    esac
fi
export UCX_LOG_LEVEL=error

# ---- Case Setup ----
# Set the case directory (override with: sbatch --export=CASE_DIR=/path/to/case submit_openfoam.sh)
CASE_DIR="${CASE_DIR:-$FOAM_TUTORIALS/incompressibleFluid/drivaerFastback}"

# drivaerFastback Allrun options: -c <cores> -m <S|M|L|XL>
ALLRUN_ARGS="${ALLRUN_ARGS:--c $SLURM_NTASKS -m $MESH_SIZE}"

log "INFO" "============================================="
log "INFO" "Job ID       : $SLURM_JOB_ID"
log "INFO" "Job Name     : $SLURM_JOB_NAME"
log "INFO" "Nodes        : ${SLURM_JOB_NUM_NODES} ($SLURM_JOB_NODELIST)"
log "INFO" "Tasks        : $SLURM_NTASKS"
log "INFO" "Tasks/Node   : $SLURM_NTASKS_PER_NODE"
log "INFO" "Mesh size    : $MESH_SIZE"
log "INFO" "MPI flags    : $FOAM_MPIRUN_FLAGS"
log "INFO" "Case Dir     : $CASE_DIR"
log "INFO" "============================================="

if [ ! -d "$CASE_DIR" ]; then
    log "ERROR" "Case directory does not exist: $CASE_DIR"
    exit 1
fi

# Copy tutorial case to a writable working directory if it lives on a read-only filesystem
if [ ! -w "$CASE_DIR" ]; then
    WORK_DIR="$SLURM_SUBMIT_DIR/run_$(basename $CASE_DIR)_$SLURM_JOB_ID"
    log "INFO" "Case directory is read-only. Copying to $WORK_DIR"
    cp -r "$CASE_DIR" "$WORK_DIR"
    chmod -R u+w "$WORK_DIR"
    cd "$WORK_DIR" || { log "ERROR" "Failed to cd to $WORK_DIR"; exit 1; }
else
    cd "$CASE_DIR" || { log "ERROR" "Failed to cd to $CASE_DIR"; exit 1; }
fi

log "INFO" "Working directory: $(pwd)"

# ---- Run the case ----
if [ -f ./Allrun ]; then
    chmod +x ./Allrun
    log "INFO" "Running: ./Allrun $ALLRUN_ARGS"
    ./Allrun $ALLRUN_ARGS
else
    log "ERROR" "No Allrun script found in $(pwd)"
    exit 1
fi

# ---- Reconstruct the single partition after the solver has run ----
if ls -d processor[0-9]* >/dev/null 2>&1; then
    log "INFO" "Reconstructing parallel case..."
    reconstructPar -latestTime
    log "INFO" "Reconstruction completed"
else
    log "INFO" "No processor directories found — skipping reconstruction"
fi

# ---- Create ParaView loader file ----
touch case.foam
log "INFO" "Created case.foam for ParaView post-processing"

log "INFO" "OpenFOAM job completed"
