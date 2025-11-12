---
mode: agent
model: Claude Sonnet 4.5 (copilot)
tools: ['edit', 'search', 'runCommands']
description: 'Generate a bash script to execute the Open FOAM tutorial drivaerFastback using Slurm'
---

- Create a Bash script to be submitted using sbatch which will run OpenFOAM
- Ask for the script name
- The script should not hardcode the partition and the number of nodes, instead use Slurm environment variables
- Output and Errors should be in separate files.
- There is no walltime.
- The job is exclusive on nodes.
- If the number of tasks per node is not specified, use the number of cores available on the node
- Create a time stamp logging functions to log all messages and errors
- Open FOAM documentation reference https://www.openfoam.com/
- Load and initialize OpenFOAM using the EESSI and CVMFS modules as below

```bash
source /cvmfs/software.eessi.io/versions/2023.06/init/bash
ml OpenFOAM
source $FOAM_BASH
```
- Print Open FOAM version used
- Print Module loaded, OpenFOAM and Slurm environment variables used
- Create a working folder using only the case name with a writable copy of the drivaerFastback tutorial files
- Cleanup leftover files from previous jobs by using the AllClean script provided with OpenFOAM
- Process the case on multiple cores in parallel using the AllRun script provided with OpenFOAM
- At the end of the script, print a summary of the job including the job ID, node list used, start time, end time, and total elapsed time
