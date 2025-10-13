#!/bin/bash
#SBATCH --job-name drivaer
##SBATCH --ntasks-per-node=96
#SBATCH --exclusive

# Logging function with timestamp
log_with_timestamp() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_with_timestamp "Job started on $(hostname) with SLURM_JOB_ID=$SLURM_JOB_ID"

# Number of tasks per node, default to all cores on the node
np=${SLURM_NTASKS:-$SLURM_CPUS_ON_NODE}
n=$SLURM_NNODES
ppn=$SLURM_CPUS_ON_NODE

log_with_timestamp "Configuration: ${n} nodes, ${ppn} cores per node, ${np} total tasks"

# setup openfoam environment (from eessi)
log_with_timestamp "Setting up OpenFOAM environment from EESSI"
source /cvmfs/software.eessi.io/versions/2023.06/init/bash
ml OpenFOAM
source $FOAM_BASH
log_with_timestamp "OpenFOAM environment loaded successfully"

# select the tutorial to run (and give any args required for allrun)
tutorial_path=incompressibleFluid/drivaerFastback
allrun_args="-c $np -m M" # -m M for Medium or L for large model

# the location to run the copy of the tutorial
local_path=$HOME/openfoam_tutorial_runs
log_with_timestamp "Creating local tutorial directory: $local_path"
mkdir -pv $local_path

# create the case name - add size and date
casedir=$local_path/$(basename $tutorial_path)_${n}x${ppn}_$(date +%Y%m%d_%H%M%S)
log_with_timestamp "Setting up case directory: $casedir"

log_with_timestamp "Copying tutorial from $FOAM_TUTORIALS/$tutorial_path"
cp -r $FOAM_TUTORIALS/$tutorial_path $casedir

# the files are only rx, so make them writable on the copy
log_with_timestamp "Making files writable and entering case directory"
chmod +w -R $casedir
pushd $casedir
# allow flags to be added to the mpirun command through FOAM_MPIRUN_FLAGS environment variable
log_with_timestamp "Configuring Allrun script for SLURM environment"
sed -i '/RunFunctions/a source <(declare -f runParallel | sed "s/mpirun/SLURM_EXPORT_ENV=ALL mpirun \\\$FOAM_MPIRUN_FLAGS/g")' Allrun
# change the script to bash (as we are using bash features not necessarily available for just a sh session)
sed -i 's#/bin/sh#/bin/bash\nset -e#g' Allrun

export FOAM_MPIRUN_FLAGS="-mca pml ucx $(env |grep 'WM_\|FOAM_' | cut -d'=' -f1 | sed 's/^/-x /g' | tr '\n' ' ') -x MPI_BUFFER_SIZE -x UCX_IB_MLX5_DEVX=n -x UCX_POSIX_USE_PROC_LINK=n -x PATH -x LD_LIBRARY_PATH"
log_with_timestamp "MPI flags configured: $FOAM_MPIRUN_FLAGS"

# Decompress the geometry
log_with_timestamp "Preparing geometry files"
gunzip constant/geometry/*
mv constant/geometry constant/triSurface
# Reconstruct the single partition after the solver has run
sed -i 's/# runApplication reconstructPar/runApplication reconstructPar/g' Allrun
log_with_timestamp "Geometry preparation completed"

log_with_timestamp "Starting OpenFOAM simulation with args: $allrun_args"
start_time=$(date +%s)
./Allrun $allrun_args || { 
    log_with_timestamp "ERROR: Job failed, please check log.* files"; 
    exit 1; 
}
end_time=$(date +%s)
runtime=$((end_time - start_time))
log_with_timestamp "OpenFOAM simulation completed successfully in ${runtime} seconds"

log_with_timestamp "Extracting execution time summary:"
grep "ExecutionTime" $casedir/log.foamRun | tail -n 1

# Create a file to load the model in Paraview
log_with_timestamp "Creating Paraview case file"
touch case.foam

log_with_timestamp "Job completed successfully. Results available in: $casedir"
