#!/bin/bash
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
NODEDEF=$(grep "Nodename=ccw-gpu-" /sched/ccw/azure.conf | xargs)
CORES=$(echo $NODEDEF | cut -d' ' -f4 | cut -d '=' -f2)
THREADS_PER_CORE=$(echo $NODEDEF | cut -d' ' -f5 | cut -d '=' -f2)
GPUS=$(echo $NODEDEF | cut -d' ' -f7 | cut -d '=' -f2 | cut -d':' -f2)
CORES_PER_GPUS=$(( CORES/GPUS/THREADS_PER_CORE ))

echo "Running on $CORES cores, $THREADS_PER_CORE threads per core, $GPUS GPUs, $CORES_PER_GPUS cores per GPU."

# --gres-flags=enforce-binding --tres-bind=gres/gpu:closest
sbatch -N1 -p gpu --gpus-per-node=$GPUS --cpus-per-gpu=$CORES_PER_GPUS --mem=0 $script_dir/text2image_lora.slurm
