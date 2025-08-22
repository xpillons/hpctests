# A simple OpenFOAM example. OpenFOAM is loaded from CVFMS and EESSI builds.

Use a number of nodes `n` to run the simulation in parallel.
Use 4 nodes or more.

```bash
sbatch -p hpc -N <n> submit.slurm
```