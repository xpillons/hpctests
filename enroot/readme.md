# container tests
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