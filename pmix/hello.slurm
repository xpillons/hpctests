#!/bin/bash
#SBATCH --exclusive
#SBATCH -o %x_%j.log

source /etc/profile.d/modules.sh
module avail
module load mpi/hpcx-pmix

srun -vv --mpi=pmix \
    --ntasks-per-node=2 \
    hostname
