#!/bin/bash
# sbatch -N 1 -p htc hello_orcaflex.sh
#SBATCH --job-name=hello_orcaflex
#SBATCH -o %x_%j.log
#SBATCH --container-image /shared/containers/orcina+orcaflex+ofx114e-py311.sqsh
#SBATCH --container-writable
#SBATCH --container-env=FLEXNET_ADDRESS=licserver.contoso.com
#SBATCH --export=MELLANOX_VISIBLE_DEVICES=none

python --version
python3 --version
