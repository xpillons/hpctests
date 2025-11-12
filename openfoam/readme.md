# A simple OpenFOAM example. OpenFOAM is loaded from CVFMS and EESSI builds.

Use a number of nodes `n` to run the simulation in parallel.
Use 4 nodes or more.

```bash
sbatch -p hpc -N <n> submit.slurm
```


# Copilot Agent driven to build the Slurm submission script
This section describes how a Slurm submission script can be built using the Copilot Agent.

copy the prompt file under .github/prompts
open the prompt then "Run Prompt in New Chat"

## Build a first draft
### Prompt
`Follow instructions in #file:openfoam.prompt.md`

### Actions
 - `run_openfoam.slurm`
 - Keep

```bash
sbatch --partition=hpc --nodes=1 run_openfoam.slurm
squeue
```

- Check logs

## Fix error not finding the tutorial case
### Prompt
Add error/output files in context

`Fix this`

### Action
- Allow running commands
- Keep

```bash
sudo rm -rf drivaerFastback/
sbatch --partition=hpc --nodes=1 run_openfoam.slurm
squeue
```
- Check logs

## Use job cores and not 8 cores
### Prompt
`OpenFOAM is currently using only 8 cores, but I want it to utilise all the cores allocated to the Slurm job`

### Action
- Allow running commands
- Keep

```bash
sbatch --partition=hpc --nodes=1 run_openfoam.slurm
squeue
```

- Check logs

## reconstruct latest time and run on multiple nodes
### Prompt
`I noticed that reconstructPar is commented out in the Allrun script. Could you uncomment it before executing Allrun?`

### Action
- Allow running commands
- Keep

```bash
sbatch --partition=hpc --nodes=2 run_openfoam.slurm
squeue
```

- Check logs
