# STAR-CCM+ HPC Benchmarking Suite

Benchmarking and performance tuning toolkit for Simcenter STAR-CCM+ on Azure HBv4 nodes (AMD EPYC 9V33X, 176 cores, InfiniBand).

## Contents

| File | Description |
|---|---|
| `starccm.slurm` | Multi-node Slurm batch script for steady-state CFD simulations |
| `starccm_bench.slurm` | Single-node benchmark script using StarCCM+'s native `-benchmark` mode |
| `run_bench_suite.sh` | Submit a matrix of MPI/fabric/binding benchmark experiments |
| `analyse_results.sh` | Shell wrapper to parse benchmark XML reports |
| `analyse_results.py` | Python script producing sorted performance tables, CSV, and Markdown reports |
| `test_starccm_slurm.sh` | Integration test suite — 9 MPI/fabric/binding configurations |
| `test_starccm_options.sh` | Unit tests for environment variable and option parsing |
| `configure_xpmem.sh` | Enable XPMEM shared memory transport on compute nodes |
| `instructions.md` | Detailed installation, configuration, tuning, and benchmark results |
| `macros/run_iterations.java` | Java macro to run a fixed number of iterations |
| `modulefiles/starccm/` | Environment module for StarCCM+ 19.04.009-R8 |
| `application/` | Open OnDemand (OOD) web portal application |

## Quick Start

### Prerequisites

- StarCCM+ installed at `/shared/apps/starccm/19.04.009-R8/`
- Environment module installed (see [instructions.md](instructions.md#environment-module))
- Model files in `/shared/apps/starccm/models/`
- FlexLM license server reachable at `28000@10.18.0.11`

### Run a single-node benchmark

```bash
MODEL=/shared/apps/starccm/models/acoustic_wave.sim sbatch starccm_bench.slurm
```

### Run a multi-node simulation

```bash
MODEL=/shared/apps/starccm/models/acoustic_wave.sim sbatch starccm.slurm
```

### Run the benchmark suite

```bash
./run_bench_suite.sh /shared/apps/starccm/models/acoustic_wave.sim
```

### Analyse results

```bash
./analyse_results.sh              # auto-detects latest run
./analyse_results.sh runs/<DIR>   # specific run directory
```

## Key Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MODEL` | *(required)* | Path to `.sim` or `.sim.txz` file |
| `MPI` | `openmpi` | MPI driver: `openmpi`, `intel`, `hpe` |
| `FABRIC` | *(auto)* | Network fabric: `ibv`, `ucx`, `ofi`, `tcp` |
| `CPUBIND` | `bandwidth` | CPU binding: `bandwidth`, `off`, `latency` |
| `STARCCM_HPCX` | *(unset)* | Set to `1` to use system HPCX instead of bundled OpenMPI |
| `NITS` | `20` | Timed iterations (benchmark mode) |
| `PREITS` | `10` | Warm-up iterations (benchmark mode) |
| `NPS` | `176` | Core counts for scaling study (comma-separated) |
| `TAG` | *(unset)* | Label appended to output reports |

See [instructions.md](instructions.md) for the full variable reference.

## Recommended Configuration

Based on exhaustive single-node benchmarking (~2.60 s/iter on AeroSUV 57M, 176 cores):

```bash
STARCCM_HPCX=1 FABRIC=ucx MODEL=/path/to/model.sim sbatch starccm_bench.slurm
```

HPCX + UCX delivers near-optimal performance with the lowest memory footprint (155 GB). NUMA mapping and UCX tuning provide no statistically significant benefit for this workload.

## Open OnDemand

The `application/` directory contains an OOD batch connect app for submitting StarCCM+ jobs through a web portal. It provides a form-based interface for selecting models, MPI drivers, fabrics, and binding modes.

### Enable sandbox applications

An admin must enable development mode for each user by creating a `gateway` symlink under `/var/www/ood/apps/dev/`. For example, to enable user `jdoe`:

```bash
sudo mkdir -p /var/www/ood/apps/dev/jdoe
cd /var/www/ood/apps/dev/jdoe
sudo ln -s /home/jdoe/ondemand/dev gateway
```

Once this is done, a **Develop** menu appears in the OOD dashboard navigation bar for that user. See the [OOD documentation](https://osc.github.io/ood-documentation/latest/how-tos/app-development/enabling-development-mode.html) for details.

### Install the application

Clone this repository and create a symlink to register the app as a sandbox application:

```bash
git clone https://github.com/xpillons/hpctests.git ~/hpctests
mkdir -p ~/ondemand/dev
ln -s ~/hpctests/starccm/application ~/ondemand/dev/starccm
```

The application will then appear under **Develop** → **My Sandbox Apps** in the OOD portal.

### Deploy for all users

Once the sandbox application has been tested and validated, deploy it system-wide by copying it into the OOD system apps directory:

```bash
sudo cp -r ~/hpctests/starccm/application /var/www/ood/apps/sys/starccm
```

The application will then appear in the OOD dashboard for all users without requiring development mode.

## Documentation

Full installation instructions, license setup, Intel MPI troubleshooting, XPMEM configuration, and detailed benchmark results are in [instructions.md](instructions.md).
