#!/bin/bash
# sbatch -N 1 -p gpu --wait hello_pytorch.sh
#SBATCH --job-name=hello_pytorch
#SBATCH -o %x_%j.log
#SBATCH --container-image nvcr.io\#nvidia/pytorch:24.03-py3
#SBATCH --gres=gpu:1

python -c 'import torch ; print(torch.__version__)'
