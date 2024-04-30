#!/bin/bash
#SBATCH -J Wait
#SBATCH --export=NONE
#SBATCH --exclusive

echo "Running on nodes"
scontrol show hostnames
sleep 3600s
echo "Finished"
