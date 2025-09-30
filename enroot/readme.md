# Container tests
Containers will be pulled by the enroot integration with Slurm
Batch scripts to test container functionality on the cluster. 

```bash
sbatch -N 1 -p htc hello_ubuntu.sh
sbatch -N 1 -p hpc hello_ubuntu.sh
sbatch -N 1 -p gpu hello_pytorch.sh
```

Interactive container tests

```bash
srun -N1 -p hpc --container-image=ubuntu grep PRETTY /etc/os-release
srun -N1 -p gpu --gres=gpu:1 --container-image nvcr.io#nvidia/pytorch:24.03-py3 python -c 'import torch ; print(torch.__version__)'
srun -N1 -p gpu --gpus-per-node=8 --mem=0 --container-image nvcr.io#nvidia/pytorch:24.03-py3 --pty bash
``` 

## Orcaflex in a container
Orcaflex container is setup to use `wine` to run the Windows version of Orcaflex in an Ubuntu container.

Create a local copy of the container image in a squashfs file
From a compute node with enroot installed run:
```bash
# Pull the container from DockerHub and create a local copy
enroot import docker://orcina/orcaflex:ofx114e-py311
# Create a squashfs file from the container
enroot create --name orcaflex114e-py311 ./orcina+orcaflex+ofx114e-py311.sqsh
# Move the squashfs file to a shared location
sudo mkdir -p /shared/containers
sudo mv ./orcina+orcaflex+ofx114e-py311.sqsh /shared/containers/
```

For this particular container, the Azure HPC Images can't be used. As a workaround you have to use this image for the HTC partition: `microsoft-dsvm:ubuntu-2204:2204-gen2:latest`.

```bash
sbatch -N 1 -p htc hello_orcaflex.sh
```
