#!/bin/bash
# sbatch -N 1 -p htc hello_orcaflex.sh
#SBATCH --job-name=hello_orcaflex
#SBATCH -o %x_%j.log
#SBATCH --container-image /shared/containers/orcina+orcaflex+ofx114e-py311.sqsh
#SBATCH --container-writable
#SBATCH --no-container-entrypoint
#SBATCH --container-remap-root
#SBATCH --container-env=FLEXNET_ADDRESS
#SBATCH --export=MELLANOX_VISIBLE_DEVICES=none,FLEXNET_ADDRESS=foo.com

printenv

echo "running as $(whoami)"
echo "running /usr/local/bin/entrypoint.sh"
/usr/local/bin/entrypoint.sh

python --version
python3 --version
