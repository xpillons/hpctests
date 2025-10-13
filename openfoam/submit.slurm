#!/bin/bash
#SBATCH --job-name drivaer
##SBATCH --ntasks-per-node=96
#SBATCH --exclusive

# Number of tasks per node, default to all cores on the node
np=${SLURM_NTASKS:-$SLURM_CPUS_ON_NODE}
n=$SLURM_NNODES
ppn=$SLURM_CPUS_ON_NODE

# setup openfoam environment (from eessi)
source /cvmfs/software.eessi.io/versions/2023.06/init/bash
ml OpenFOAM
source $FOAM_BASH

# select the tutorial to run (and give any args required for allrun)
tutorial_path=incompressibleFluid/drivaerFastback
allrun_args="-c $np -m M" # -m M for Medium or L for large model

# the location to run the copy of the tutorial
local_path=$HOME/openfoam_tutorial_runs
mkdir -pv $local_path

# create the case name - add size and date
casedir=$local_path/$(basename $tutorial_path)_${n}x${ppn}_$(date +%Y%m%d_%H%M%S)

cp -r $FOAM_TUTORIALS/$tutorial_path $casedir

# the files are only rx, so make them writable on the copy
chmod +w -R $casedir
pushd $casedir
# allow flags to be added to the mpirun command through FOAM_MPIRUN_FLAGS environment variable
sed -i '/RunFunctions/a source <(declare -f runParallel | sed "s/mpirun/SLURM_EXPORT_ENV=ALL mpirun \\\$FOAM_MPIRUN_FLAGS/g")' Allrun
# change the script to bash (as we are using bash features not necessarily available for just a sh session)
sed -i 's#/bin/sh#/bin/bash\nset -e#g' Allrun

export FOAM_MPIRUN_FLAGS="-mca pml ucx $(env |grep 'WM_\|FOAM_' | cut -d'=' -f1 | sed 's/^/-x /g' | tr '\n' ' ') -x MPI_BUFFER_SIZE -x UCX_IB_MLX5_DEVX=n -x UCX_POSIX_USE_PROC_LINK=n -x PATH -x LD_LIBRARY_PATH"

# Decompress the geometry
gunzip constant/geometry/*
mv constant/geometry constant/triSurface
# Reconstruct the single partition after the solver has run
sed -i 's/# runApplication reconstructPar/runApplication reconstructPar/g' Allrun

./Allrun $allrun_args || echo "Job failed, please checks log.* files"; exit 1

grep "ExecutionTime" $casedir/log.foamRun | tail -n 1

# Create a file to load the model in Paraview
touch case.foam
