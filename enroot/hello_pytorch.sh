#!/bin/bash
# sbatch -N 1 -p hpc --wait hello_pytorch.sh
#SBATCH --job-name=hello_pytorch
#SBATCH -o %x_%j.log
#SBATCH --container-image nvcr.io\#nvidia/pytorch:21.12-py3

python -c 'import torch ; print(torch.__version__)'
