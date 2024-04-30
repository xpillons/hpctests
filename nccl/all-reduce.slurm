#!/bin/bash
#SBATCH -t 00:20:00
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=12
#SBATCH --gpus-per-node=8
#SBATCH --mem=0
#SBATCH --exclusive

BASE_DIR=/opt
NCCL_TESTS_EXE=all_reduce_perf

export CUDA_DEVICE_ORDER=PCI_BUS_ID
export NCCL_IB_PCI_RELAXED_ORDERING=1
export NCCL_SOCKET_IFNAME=eth0
export NCCL_TOPO_FILE=/opt/microsoft/ndv4-topo.xml
export OMPI_MCA_coll_hcoll_enable=0
export UCX_IB_PCI_RELAXED_ORDERING=on
export UCX_NET_DEVICES=eth0
export UCX_TLS=tcp
export NCCL_DEBUG=INFO
export LD_LIBRARY_PATH=/usr/local/nccl-rdma-sharp-plugins/lib:$LD_LIBRARY_PATH

source /etc/profile.d/modules.sh
module load mpi/hpcx

PIN_MASK='ffffff000000,ffffff000000,ffffff,ffffff,ffffff000000000000000000,ffffff000000000000000000,ffffff000000000000,ffffff000000000000'

srun -vv --mpi=pmix \
    --cpu-bind=mask_cpu:$PIN_MASK \
    --gpus-per-node=8 \
    --ntasks-per-node=8 \
    ${BASE_DIR}/nccl-tests/build/$NCCL_TESTS_EXE -b 8 -f 2 -g 1 -e 8G -c 1
