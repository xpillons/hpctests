---
name: 'slurm'
description: 'Typical Slurm commands and usage for job scheduling and management.'
---

# Slurm Instructions
You can use the following Slurm commands to manage your jobs:
- To submit a job: 
```bash
sbatch job_script.sh
```
- To check the status of your jobs:
```bash
squeue -u your_username
```
- To cancel a job:
```bash
scancel job_id
```
- To view job details:
```bash
scontrol show job job_id
```

- To retrieve partitions:
```bash
sinfo
```

## Cluster Partitions and Resources
The following partitions are available on this cluster:
| Partition | Nodes | Cores per Node | Notes |
|-----------|-------|----------------|-------|
| hpc (default) | 16 (ccw-hpc-[1-16]) | 176 | General-purpose HPC nodes |
| hpcsc | 16 (ccw-hpcsc-[1-16]) | — | HPC scale-out nodes |
| htc | 16 (ccw-htc-[1-16]) | — | High-throughput computing |
| gpu | 3 (ccw-gpu-[1-3]) | — | GPU-enabled nodes |

When setting `--ntasks-per-node`, use 176 for the **hpc** partition to fully utilise all cores on each node.

For OpenFOAM drivaerFastback, **176 cores per node** with `--bind-to core --map-by l3cache` and `UCX_ZCOPY_THRESH=16384` gives the best solver and wall time at any node count. Confirmed on both M mesh (81s solver, 100s wall) and L mesh (1898s solver, 2005s wall) at single-node, and validated for multi-node scaling (2-node: 808s, 4-node: 503s on L mesh). The same MPI config is optimal across 1–4 nodes. See the openfoam instructions for detailed benchmark results across 6 passes.

Multi-node submission example:
```bash
sbatch --nodes=4 submit_openfoam.sh
```

This is a cloud-based cluster with auto-scaling. Nodes may be in `idle~` (powered off) state and take a few minutes to provision when a job is submitted (job will show `CONFIGURING` state during this time).

Job accounting may not be available, so you may not be able to see detailed resource usage or job history. Always check with your system administrator for specific Slurm configurations and available features on your cluster.

