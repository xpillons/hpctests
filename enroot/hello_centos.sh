#!/bin/bash
# sbatch -N 1 -p hpc hello_centos.sh
#SBATCH --job-name=hello_centos
#SBATCH -o %x_%j.log
#SBATCH --container-image centos

grep PRETTY /etc/os-release
