#!/bin/bash
# sbatch -N 1 -p hpc hello_ubuntu.sh
#SBATCH --job-name=hello_ubuntu
#SBATCH -o %x_%j.log
#SBATCH --container-image ubuntu

grep PRETTY /etc/os-release
