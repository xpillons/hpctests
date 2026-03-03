#!/bin/bash
#SBATCH --job-name=ofbench-mesh
#SBATCH --partition=hpc
#SBATCH --ntasks-per-node=176
#SBATCH --exclusive
#SBATCH --time=02:00:00

# Multi-node OpenFOAM benchmark — Mesh phase
# Submitted by benchmark_multinode.sh orchestrator.
# Environment variables expected:
#   PASS_DIR     — shared pass directory for all jobs
#   TOTAL_CORES  — total MPI ranks (nodes × 176)
#   MESH_SIZE    — S, M, L, or XL
#   NNODES       — number of nodes

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

# ---- MPI Sanity Check ----
# SCRIPT_DIR is passed via --export from the orchestrator
source "${SCRIPT_DIR}/mpi_sanity_check.sh"
if ! run_mpi_sanity_check "$TOTAL_CORES" "$PASS_DIR"; then
    log "ERROR" "MPI sanity check failed — aborting mesh job"
    exit 1
fi

CASE_DIR="$FOAM_TUTORIALS/incompressibleFluid/drivaerFastback"

log "INFO" "============================================="
log "INFO" "OpenFOAM Mesh Phase — Pass 6"
log "INFO" "Job ID       : $SLURM_JOB_ID"
log "INFO" "Nodes        : $NNODES ($SLURM_JOB_NODELIST)"
log "INFO" "Total cores  : $TOTAL_CORES"
log "INFO" "Mesh size    : $MESH_SIZE"
log "INFO" "Pass dir     : $PASS_DIR"
log "INFO" "============================================="

# Must mesh and solve with the same core count (reconstruct/re-decompose
# fails with GAMG — confirmed in Job 1229).

ncores=$TOTAL_CORES
base_dir="${PASS_DIR}/base_c${ncores}_${MESH_SIZE}"
log "INFO" "Preparing meshed base case for $ncores cores ($MESH_SIZE mesh) -> $base_dir"

rm -rf "$base_dir"
cp -r "$CASE_DIR" "$base_dir"
chmod -R u+w "$base_dir"

cd "$base_dir"
. "$WM_PROJECT_DIR/bin/tools/RunFunctions"

# Restore .orig files to their proper names (OpenFOAM tutorial convention)
for orig_file in system/*.orig; do
    [ -f "$orig_file" ] && cp "$orig_file" "${orig_file%.orig}"
done

# Set numberOfSubdomains for total core count
foamDictionary -entry numberOfSubdomains -set "$ncores" system/decomposeParDict

# Use the best mapping for meshing
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
MESH_TIME=$((mesh_end - mesh_start))

# Write mesh time to a file so test jobs can read it
echo "$MESH_TIME" > "${PASS_DIR}/mesh_time_${MESH_SIZE}.txt"

log "INFO" "Meshing for $ncores cores ($MESH_SIZE mesh) completed in ${MESH_TIME}s"
