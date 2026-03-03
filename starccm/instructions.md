# Benchmarking StarCCM+

## Variables

```bash
INSTALL_DIR=/shared/apps/starccm
MEDIA_DIR=/mntstarccm/software
```

## Installation Instructions

- StarCCM+ binaries should be installed in the `$INSTALL_DIR` folder
- Installation media are located in `$MEDIA_DIR/`
- Target system is Linux x86_64

### Installed Version

- **Version**: Simcenter STAR-CCM+ 2406.0001 Build 19.04.009 (linux-x86_64-2.28/clang17.0-r8 Double Precision)
- **Install path**: `$INSTALL_DIR/19.04.009-R8/`
- **Executable**: `$INSTALL_DIR/19.04.009-R8/STAR-CCM+19.04.009-R8/star/bin/starccm+`

### How to install

Run the silent installer from the media location:

```bash
sudo "$MEDIA_DIR/STAR-CCM+19.04.009_01_linux-x86_64-2.28_clang17.0-r8/STAR-CCM+19.04.009_01_linux-x86_64-2.28_clang17.0-r8.sh" \
  -i silent \
  -DINSTALLDIR=$INSTALL_DIR \
  -DNODOC=true \
  -DINSTALLFLEX=false
```

### Verify the installation

```bash
$INSTALL_DIR/19.04.009-R8/STAR-CCM+19.04.009-R8/star/bin/starccm+ -version
```

Expected output:

```
Simcenter STAR-CCM+ 2406.0001 Build 19.04.009 (linux-x86_64-2.28/clang17.0-r8 Double Precision)
```

### Available media

| Directory / File | Description |
|---|---|
| `starccm+_19.04.009/` | 19.04.009 gnu11.4-r8 (extracted installer) |
| `STAR-CCM+19.04.009_01_linux-x86_64-2.28_clang17.0-r8/` | 19.04.009 clang17.0-r8 (extracted installer, **installed**) |
| `2402_19.02.13/` | 19.02.013 tar.gz archives |
| `2506/` | 2506 tar.gz archives (mixed & double) |
| `2602 EAP/` | 2602 EAP tar.gz archive |

## Model files

- Model files source: `$MEDIA_DIR/models`
- Model files destination: `$INSTALL_DIR/models` (copied)

### Available models

| File | Size | Status |
|---|---|---|
| `acoustic_wave.sim` | 111 MB | Copied, **working** |
| `AeroSUV_Steady_Coupled_57M_V17_04_005.sim.txz` | 4.6 GB | Copied, **CORRUPT** |
| `AeroSUV_Steady_Coupled_322M_V17_04_005.sim.txz` | 22 GB | Copied, **CORRUPT** |
| `AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim.txz` | 4.4 GB | Copied, **CORRUPT** |
| `AeroSUV_Steady_Segregated_322M_V17_04_007_v2.sim.txz` | 21 GB | Copied, **CORRUPT** |

> **⚠️ AeroSUV model corruption:** All four `.txz` archives are corrupt **at the Azure Files source** (`$MEDIA_DIR/models/`). MD5 checksums of local copies match the source, confirming the corruption existed before copy. XZ decompression starts correctly but fails ~580 MB into the data. These archives need to be re-uploaded to the Azure Files share from the original Siemens source.

### How to copy model files

Use `parallel` and `rsync` for concurrent, resumable copies:

```bash
sudo mkdir -p $INSTALL_DIR/models
ls $MEDIA_DIR/models/*.txz | parallel -j4 sudo rsync -ah --progress {} $INSTALL_DIR/models/
```

> **Note:** If the transfer is interrupted, re-run the same command — `rsync` will resume where it left off.

### Monitor copy progress

Check active rsync processes and file sizes:

```bash
# Check how many rsync processes are still running
ps aux | grep "rsync.*models" | grep -v grep | wc -l

# Check file sizes (including hidden temp files from rsync)
ls -lah $INSTALL_DIR/models/

# Watch progress in a loop (checks every 30 seconds)
while ps aux | grep "rsync.*models" | grep -v grep > /dev/null; do
  echo "=== $(date) ==="
  ls -lah $INSTALL_DIR/models/
  sleep 30
done
echo "All copies complete!"
```

> When rsync is in progress, temp files appear as `.filename.XXXXXX`. Once a file finishes, the temp file is renamed to the final filename.

## Environment Module

An environment module file is provided in `modulefiles/starccm/19.04.009-R8` to set up `PATH`, `LD_LIBRARY_PATH`, `STARCCM_DIR`, and `CDLMD_LICENSE_FILE` for the installed version.

### Install the module

Copy the module files to a shared location on the cluster (e.g. `/shared/apps/modulefiles`):

```bash
sudo mkdir -p /shared/apps/modulefiles/starccm
sudo cp modulefiles/starccm/19.04.009-R8 /shared/apps/modulefiles/starccm/
sudo cp modulefiles/starccm/.version      /shared/apps/modulefiles/starccm/
```

Then register the path so the module system can find it:

```bash
module use /shared/apps/modulefiles
```

> **Tip:** To make this permanent for all users, add the `module use` line to `/etc/profile.d/starccm.sh` or append the path to `$MODULEPATH` in the system module configuration.

### Load the module

```bash
module load starccm
```

### Verify the module

```bash
module list              # should show starccm/19.04.009-R8
which starccm+           # should point to $INSTALL_DIR/19.04.009-R8/STAR-CCM+19.04.009-R8/star/bin/starccm+
starccm+ -version        # should print the version string
```

### What the module sets

| Variable | Value |
|---|---|
| `PATH` | Prepends `$INSTALL_DIR/19.04.009-R8/STAR-CCM+19.04.009-R8/star/bin` |
| `LD_LIBRARY_PATH` | Prepends `$INSTALL_DIR/19.04.009-R8/STAR-CCM+19.04.009-R8/star/lib` |
| `STARCCM_DIR` | `$INSTALL_DIR/19.04.009-R8/STAR-CCM+19.04.009-R8` |
| `CDLMD_LICENSE_FILE` | `28000@10.18.0.11` |

## License Server

- **Host**: `10.18.0.11` (Windows, FlexLM)
- **Port**: `28000` (lmgrd master daemon), `28002` (vendor daemon)
- **Feature**: `ccmppower`

### Install lmutil (optional)

`lmutil` (FlexLM utility) is used to query the license server status, list features, and check active checkouts. **It is not bundled with the StarCCM+ client installation** (the `-DINSTALLFLEX=true` installer option deploys the FlexLM license *server* daemon, which is only relevant for the license server host, not compute nodes).

To obtain `lmutil`, use one of these methods:

1. **Request from your license administrator** — they should have the FlexNet Publisher Licensing Toolkit.
2. **Download from Flexera** — requires a Flexera account:
   - https://www.flexera.com/products/software-monetization/flexnet-publisher.html
3. **Copy from another FlexLM-based application** (e.g. MATLAB, Ansys) — `lmutil` is a generic FlexLM tool and is interchangeable.

Once you have the binary, install it:

```bash
sudo install -m 755 /path/to/lmutil /usr/local/bin/lmutil
```

### Query the license server

```bash
# Check license server status
lmutil lmstat -a -c 28000@10.18.0.11

# List available features
lmutil lmstat -c 28000@10.18.0.11 -f ccmppower

# Check all current checkouts
lmutil lmstat -c 28000@10.18.0.11 -a | grep "Users of"
```

### Verify license with StarCCM+

A quick way to confirm the license works without `lmutil`:

```bash
module load starccm
starccm+ -batch -new -power 2>&1 | grep -E "checked out|License|expires"
```

Expected output:

```
1 copy of ccmppower checked out from 28000@10.18.0.11
Feature ccmppower expires in <N> days
```

## Running starccm+

### Single-node benchmark

A Slurm script is provided in `starccm_bench.slurm` to run automated performance benchmarks on a single `hpc` node using all 176 cores. It uses StarCCM+'s native `-benchmark` client mode, which collects performance data and generates XML + HTML reports automatically.

#### Environment variables

| Variable | Default | Description |
|---|---|---|
| `MODEL` | *(required)* | Path to `.sim` or `.sim.txz` file |
| `NITS` | `20` | Number of timed iterations |
| `PREITS` | `10` | Number of warm-up iterations before timing starts |
| `NPS` | `176` (all cores) | Comma-separated core counts for a scaling study (e.g. `44,88,176`). Defaults to all node cores to avoid a slow serial sweep. |
| `MPI` | `openmpi` | MPI driver: `openmpi`, `intel`, `hpe`, `openmpi40`, `openmpi41`, `crayxt` |
| `FABRIC` | *(auto)* | Network fabric: `ibv` (InfiniBand), `ucx`, `ofi`, `tcp`, etc. If unset, MPI auto-detects. |
| `TAG` | *(unset)* | Tag string appended to output filenames |
| `PROFILE` | *(unset)* | Enable event-log profiling (value = iterations to profile, e.g. `10`) |
| `MEMPROFILE` | *(unset)* | Enable memory profiling (value = iterations to profile, e.g. `10`) |
| `MPITESTS` | *(unset)* | Set to `1` to run MPI stress tests |
| `HOSTINFO` | *(unset)* | Set to `1` to report system info only (no iterations) |
| `STARCCM_HPCX` | *(unset)* | Set to `1` to load system HPCX module (uses `openmpi` driver with HPCX mpirun) |
| `CPUBIND` | `bandwidth` | CPU binding mode: `bandwidth`, `latency`, `off` |
| `MPPFLAGS` | *(unset)* | Extra MPI flags passed via `-mppflags` (e.g. `--map-by ppr:88:socket --bind-to core`) |
| `XSYSTEMUCX` | *(unset)* | Set to `1` to pass `-xsystemucx` (use system UCX instead of bundled) |
| `UCX_ENVS` | *(unset)* | Space-separated `KEY=VALUE` UCX overrides (e.g. `UCX_RNDV_THRESH=65536 UCX_RNDV_SCHEME=put_zcopy`) |
| `BENCH_EXTRA` | *(unset)* | Any additional `-benchmark` sub-options (passed verbatim) |
| `UCX_NET_DEVICES` | `mlx5_ib0:1` | IB device for UCX transports (default excludes `mlx5_an0` AccelNet NIC to avoid UAR errors) |

> **⚠️ Performance note:** Without `-nps`, StarCCM+'s benchmark mode defaults to a full scaling sweep starting from 1 core (serial → 2 → 4 → 8 → ... → 176), which is extremely slow for large models (e.g. ~143 s/iter serial on 57M cells). The script defaults `NPS` to all node cores to avoid this. Set `NPS` explicitly for scaling studies.

The script also enables `-cpubind bandwidth` for NUMA-aware MPI rank placement, which improves memory bandwidth utilization on multi-socket nodes.

#### Submit a benchmark job

```bash
cd /shared/home/xpillons/hpctests/starccm

# Standard benchmark (10 warm-up + 20 timed iterations at 176 cores)
MODEL=/shared/apps/starccm/models/acoustic_wave.sim sbatch starccm_bench.slurm

# Use a different model
MODEL=/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim sbatch starccm_bench.slurm

# Use a .txz archive (will be extracted into the per-job working dir)
MODEL=/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim.txz sbatch starccm_bench.slurm
```

#### Customize iteration counts

```bash
# 10 warm-up + 50 timed iterations
NITS=50 PREITS=10 MODEL=/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim sbatch starccm_bench.slurm
```

#### Scaling study

Test performance at multiple core counts in a single job:

```bash
# Run at 44, 88, and 176 cores
NPS=44,88,176 MODEL=/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim sbatch starccm_bench.slurm
```

#### MPI driver selection

StarCCM+ bundles multiple MPI implementations. Use the `MPI` variable to switch:

```bash
# Use Intel MPI
MPI=intel MODEL=/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim sbatch starccm_bench.slurm

# Use HPE MPI
MPI=hpe MODEL=/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim sbatch starccm_bench.slurm

# Use Open MPI (default)
MPI=openmpi MODEL=/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim sbatch starccm_bench.slurm

# Specify a network fabric explicitly (e.g. UCX for InfiniBand)
MPI=intel FABRIC=ucx MODEL=/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim sbatch starccm_bench.slurm
```

Available MPI drivers: `openmpi` (default), `openmpi40`, `openmpi41`, `intel`, `hpe`, `crayxt`

Available fabrics: `ibv` (InfiniBand Verbs), `ucx` (Unified Communication X), `ofi` (OpenFabrics), `tcp` (Ethernet), `psm2` (Intel OPA), `opa`, `mxm` (Mellanox)

#### Profiling and diagnostics

```bash
# Enable event-log and memory profiling (10 iterations each), tagged output
PROFILE=10 MEMPROFILE=10 TAG=hpc2_176c MODEL=/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim sbatch starccm_bench.slurm

# System/hardware info only (no simulation iterations)
HOSTINFO=1 MODEL=/shared/apps/starccm/models/acoustic_wave.sim sbatch starccm_bench.slurm

# Include MPI stress tests
MPITESTS=1 MODEL=/shared/apps/starccm/models/acoustic_wave.sim sbatch starccm_bench.slurm
```

#### What the script does

1. Creates a per-job working directory under `runs/<JOBID>/`
2. Extracts the `.sim` file from the `.txz` archive (if `.txz` model)
3. Runs StarCCM+ in `-benchmark` mode with `-power` license and `-cpubind bandwidth` for NUMA-aware placement
4. The benchmark client runs 1 initialization iteration, `PREITS` warm-up iterations (not timed), `NITS` timed iterations, and 1 final memory-collection iteration
5. Writes XML + HTML performance reports to the working directory

#### Monitor the job

```bash
squeue -u $USER
tail -f starccm-bench_<JOBID>.out
```

#### View benchmark reports

After the job completes, reports are in `runs/<JOBID>/`:

```bash
ls runs/<JOBID>/*.html runs/<JOBID>/*.xml
```

Open the HTML file in a browser for a formatted performance summary.

#### HPCX support

The script supports using the system HPCX module (NVIDIA-optimized Open MPI) instead of StarCCM+'s bundled Open MPI. Set `STARCCM_HPCX=1`:

```bash
STARCCM_HPCX=1 MODEL=/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim sbatch starccm_bench.slurm

# HPCX with a specific fabric
STARCCM_HPCX=1 FABRIC=ucx MODEL=/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim sbatch starccm_bench.slurm
```

When enabled, the script loads `mpi/hpcx`, then unsets `PMIX_INSTALL_PREFIX` and `OPAL_PREFIX` to avoid conflicts with StarCCM+'s bundled Open MPI internals.

### Benchmark suite

A convenience script `run_bench_suite.sh` submits a matrix of benchmark jobs varying MPI implementations, network fabrics, NUMA mapping, and UCX tuning:

```bash
./run_bench_suite.sh [MODEL_PATH]
```

If no model is specified, defaults to the AeroSUV Segregated 57M model. The combination format uses `|`-separated fields:

```
MPI_DRIVER|FABRIC|CPUBIND|LABEL|UCX_TLS|MPPFLAGS|UCX_ENVS
```

Labels containing `-sysucx` automatically enable `-xsystemucx`, and labels starting with `hpcx-` automatically enable HPCX.

Each combination runs at 176 cores with 10 warm-up + 20 timed iterations. Jobs are constrained to XPMEM-enabled nodes (`ccw-hpc-[1-4]`).

### Analyse results

A script `analyse_results.sh` parses XML benchmark reports and produces a sorted summary table, CSV, and Markdown report:

```bash
./analyse_results.sh                         # auto-detects most recent timestamped run
./analyse_results.sh runs/20260218_150355     # explicit run directory
```

The report includes: rank, job ID, tag, core count, average/std iteration time, cell-iterations/worker-second, **wall time** (from Slurm start/end timestamps), fabric, CPU binding, hostname, and memory usage.

Outputs:
- `benchmark_results.csv` — full data for spreadsheet import
- `benchmark_report.md` — formatted Markdown with summary statistics

### Java macros

A Java macro is available in `macros/run_iterations.java` for running iterations outside of benchmark mode (e.g. manual convergence studies). It reads the number of iterations from `iterations.txt` in the current directory:

```bash
echo 100 > iterations.txt
starccm+ -power -np 176 -batch macros/run_iterations.java /path/to/model.sim
```

The macro disables auto-save and calls `step(N)` to run exactly N iterations regardless of model stopping criteria.

## Intel MPI Troubleshooting

StarCCM+ 19.04.009 bundles Intel MPI 2021.7.1, which has two issues on this system:

### Issue 1: hydra_bstrap_proxy crash (exit code 65280)

**Symptom:** Jobs fail immediately with:
```
[mpiexec@ccw-hpc-X] Cannot launch hydra_bstrap_proxy or it crashed on one of the hosts.
error waiting for event
```

**Root cause:** The bundled `hydra_bstrap_proxy` binary is incompatible with this system. The system Intel MPI module (`mpi/impi-2021`) sets `I_MPI_HYDRA_BOOTSTRAP=slurm`, which still uses the broken bundled proxy.

**Fix:** Force fork bootstrap (bypasses the proxy entirely, single-node only):
```bash
export I_MPI_HYDRA_BOOTSTRAP=fork
unset I_MPI_HYDRA_BOOTSTRAP_EXEC
unset I_MPI_HYDRA_BOOTSTRAP_EXEC_EXTRA_ARGS
```

### Issue 2: bundled libfabric 1.13 SIGSEGV

**Symptom:** After fixing the bootstrap, jobs crash with:
```
error: SIGSEGV: memory access exception
libStarNeo.so: SignalHandler::signalHandlerFunction
```

**Root cause:** StarCCM+'s bundled Intel MPI includes libfabric 1.13, whose OFI providers (`libverbs-fi.so`) segfault on the current OFED stack. The bundled providers are too old for the kernel/OFED combination.

**Fix:** Disable the bundled libfabric and use the system Intel MPI 2021.16 libfabric 2.1.0:
```bash
SYSTEM_IMPI_LIBFABRIC=/opt/intel/oneapi/mpi/2021.16/opt/mpi/libfabric
export I_MPI_OFI_LIBRARY_INTERNAL=0
export FI_PROVIDER_PATH="${SYSTEM_IMPI_LIBFABRIC}/lib/prov"
export LD_LIBRARY_PATH="${SYSTEM_IMPI_LIBFABRIC}/lib:${LD_LIBRARY_PATH}"
```

Both fixes are applied automatically in `starccm_bench.slurm` when `MPI=intel`.

### Failure timeline

| Jobs | MPI | Issue | Result |
|---|---|---|---|
| 910–911, 916–917, 922–923, 926–929 | Intel MPI | `hydra_bstrap_proxy` crash | Failed (exit code 65280) |
| 930–931 | Intel MPI + fork | `-benchmark` option quoting bug | Failed (Unknown option) |
| 932–933 | Intel MPI + fork | Bundled libfabric SIGSEGV | Failed (SIGSEGV) |
| 934–935 | Intel MPI + fork + system libfabric | All fixes applied | **Success** |

## Benchmark Results

### System

- **CPU**: AMD EPYC 9V33X 96-Core Processor (2 sockets, 176 cores total)
- **RAM**: ~756 GB
- **OS**: Ubuntu 24.04 (kernel 6.8.0-1044-azure)
- **InfiniBand**: OFED with HPCX v2.25.1

### AeroSUV Steady Segregated 57M — Single Node

Model: `AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim` (57M cells, segregated coupled flow + k-ω turbulence)

#### Scaling study (10 pre + 20 timed iterations)

| Configuration | 44 cores (s/iter) | 88 cores (s/iter) | 176 cores (s/iter) |
|---|---|---|---|
| OpenMPI + UCX (job 920) | 8.254 | 4.133 | 2.601 |
| OpenMPI + OFI (job 921) | 8.174 | 4.146 | 2.625 |
| HPCX + UCX (job 924) | 8.307 | 4.156 | 2.892 |
| HPCX + OFI (job 925) | 8.318 | 4.170 | 2.745 |
| Intel MPI + UCX (job 934) | — | — | 2.616 |
| Intel MPI + OFI (job 935) | — | — | 2.618 |

> **Summary:** At 176 cores (full node), all MPI stacks deliver ~2.6 s/iter, with OpenMPI + UCX slightly ahead. Scaling from 44 → 88 → 176 cores is near-linear (3.16× speedup over 4× cores). HPCX shows marginally higher variance at 176 cores.

#### Repeat runs (176 cores only)

| Configuration | Run 1 (s/iter) | Run 2 (s/iter) |
|---|---|---|
| OpenMPI + UCX | 2.597 (job 914) | 2.601 (job 920) |
| OpenMPI + OFI | 2.623 (job 915) | 2.625 (job 921) |
| HPCX + UCX | 2.621 (job 918) | 2.892 (job 924) |
| HPCX + OFI | 2.649 (job 919) | 2.745 (job 925) |

> Run-to-run variance is <1% for OpenMPI, but up to 10% for HPCX (possibly due to HPCX-specific NUMA/memory optimizations interacting with the -cpubind bandwidth setting).

### Performance Tuning — Single Node

After exhaustive benchmarking across MPI stacks, fabrics, CPU binding modes, NUMA mapping, system UCX (`-xsystemucx`), and UCX environment variable tuning, the following results and recommendations emerged.

#### Tuning progression

| Pass | What was tested | Best result | Improvement |
|---|---|---|---|
| 1 | MPI stacks × fabrics × cpubind | 2.600 s/iter (HPCX + UCX, nobind) | Baseline |
| 2 | NUMA mapping, `-xsystemucx`, cpubind auto | 2.594 s/iter (HPCX + UCX + NUMA) | −0.2% |
| 3 | UCX env tuning (RNDV_THRESH, RNDV_SCHEME) | 2.593 s/iter (HPCX + UCX + NUMA + UCX tuned) | −0.3% |
| 4 | XPMEM + system UCX tuning (A/B: hpc-1 vs hpc-2) | 2.602 s/iter (baseline, both nodes) | 0% |
| 5 | **Final convergence** — all 12 configs head-to-head | 2.596 s/iter (best), 2.599 s/iter (simplest) | confirmed |
| 6 | **HPCX + sysucx + XPMEM** — 8 configs, RNDV tuning | 2.597 s/iter (XPMEM + RNDV 8K) | −0.1% |

> The total spread across all 12 configurations in the final pass was only **2.2%** (2.596 – 2.652 s/iter). The top 3 are within 0.2% — statistically indistinguishable. Pass 6 with dedicated XPMEM + RNDV tuning later achieved 2.597 s/iter (see XPMEM results below).

#### Recommended production configuration

```bash
STARCCM_HPCX=1 \
FABRIC=ucx \
MODEL=/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim \
sbatch starccm_bench.slurm
```

This achieves **~2.60 s/iter** (~126,500 cell-iterations/wall-second) at **155 GB** memory on 176 cores. NUMA mapping and UCX tuning provide no statistically significant benefit and are not needed.

#### Final convergence results (Pass 5 — 12 configurations, 176 cores)

| Rank | Configuration | s/iter | Std (s) | Mem (GB) | MPI | Fabric | Binding |
|---|---|---|---|---|---|---|---|
| 1 | hpcx-ucx-numa-sysucx | 2.596 | 0.017 | 171 | HPCX | UCX | off+NUMA |
| 2 | **hpcx-ucx-bw** | **2.599** | 0.040 | **155** | HPCX | UCX | bandwidth |
| 3 | hpcx-ucx-numa-ucxtuned | 2.601 | 0.028 | 160 | HPCX | UCX | off+NUMA+tuned |
| 4 | ompi-ucx-bw | 2.608 | 0.032 | 155 | Bundled OMPI | UCX | bandwidth |
| 5 | hpcx-ucx-nobind | 2.612 | 0.043 | 155 | HPCX | UCX | off |
| 6 | hpcx-ofi-bw | 2.612 | 0.018 | 219 | HPCX | OFI | bandwidth |
| 7 | hpcx-ucx-numa | 2.618 | 0.055 | 158 | HPCX | UCX | off+NUMA |
| 8 | hpcx-numa-sysucx-tuned | 2.626 | 0.038 | 166 | HPCX | UCX+sysucx | off+NUMA+tuned |
| 9 | ompi-ofi-bw | 2.628 | 0.034 | 219 | Bundled OMPI | OFI | bandwidth |
| 10 | impi-ucx | 2.630 | 0.043 | 221 | Intel MPI | UCX | bandwidth |
| 11 | ompi-ucx-nobind | 2.642 | 0.103 | 154 | Bundled OMPI | UCX | off |
| 12 | impi-ofi | 2.652 | 0.145 | 221 | Intel MPI | OFI | bandwidth |

> **Bold** row = recommended configuration (simplest, near-optimal, lowest memory).

#### Key findings

- **MPI stack**: HPCX (system Open MPI, mean 2.61 s/iter) and bundled Open MPI (mean 2.63 s/iter) perform near-identically. Intel MPI is slowest (mean 2.64 s/iter) and uses 43% more memory (221 GB vs 155 GB).
- **Fabric**: UCX is consistently faster than OFI (mean 2.615 vs 2.631 s/iter). OFI uses ~40% more memory (219 GB vs 155 GB).
- **CPU binding**: `bandwidth` and `off` are statistically equivalent (mean 2.622 vs 2.616 s/iter). StarCCM+ 19.04 does **not** support `-cpubind auto`.
- **NUMA mapping**: `--map-by ppr:88:socket --bind-to core` provides no statistically significant benefit in the final convergence test (within noise).
- **UCX tuning**: `UCX_RNDV_THRESH=65536` and `UCX_RNDV_SCHEME=put_zcopy` provide no statistically significant benefit. UCX auto-tuning defaults are well-calibrated for this hardware.
- **System UCX** (`-xsystemucx`): Uses HPCX UCX 1.20.0 instead of bundled ~1.14. Performance is equivalent but memory usage is ~16 GB higher (171 vs 155 GB).
- **XPMEM**: Initial A/B test (Pass 4) showed no improvement. Dedicated XPMEM run (Pass 6) with `UCX_TLS=all` + RNDV tuning showed a modest **1.1% improvement** (2.612 vs 2.640 s/iter) and much lower run-to-run variance (stdev 0.056 vs 0.158). The RNDV threshold (~8K) appears to be the primary lever, with XPMEM reducing variance.
- **System UCX tuning variables** (`UCX_POSIX_FIFO_SIZE`, `UCX_UNIFIED_MODE`, `UCX_ZCOPY_THRESH`, etc.): All slightly **hurt** performance vs baseline defaults.
- **Convergence**: The top 3 configurations are within 0.2% of each other. The simplest config (`STARCCM_HPCX=1 FABRIC=ucx`) ties with all tuned variants while using the least memory.

#### Tunings that failed

| Tuning | Reason |
|---|---|
| `UCX_TLS=sm,self` / `self,sm,tcp` | StarCCM+'s bundled Open MPI PML depends on full UCX transport stack; restricting TLS breaks PML initialization |
| `-cpubind auto` | Not a valid value in StarCCM+ 19.04 (only `bandwidth`, `latency`, `off`) |
| `UCX_IB_REG_METHODS=none` | Not recognized by bundled UCX; works only with system UCX (`-xsystemucx`) |
| `UCX_SHM_POSIX_SEG_SIZE` | Not recognized by either bundled or system UCX version |
| `UCX_RNDV_THRESH=intra:65536` | Scoped `intra:` prefix not supported by UCX 1.20; use plain `UCX_RNDV_THRESH=65536` |
| `UCX_UNIFIED_MODE=y UCX_MAX_RNDV_RAILS=1` | Reduced performance by 1.4% vs simpler RNDV-only tuning; limiting RNDV rails starves 176-rank intra-node comms |

### XPMEM — Next-level shared memory optimization

**XPMEM** (Cross-Process Memory) enables zero-copy cross-process memory access, bypassing the copy-based shared memory transports (`posix`, `sysv`, `cma`).

#### Benchmark results (Pass 4 — A/B comparison)

XPMEM was enabled on ccw-hpc-1 and benchmarked A/B against ccw-hpc-2 (no XPMEM, uses `cma` fallback). Same 4 configurations on each node:

| Configuration | ccw-hpc-1 — XPMEM (s/iter) | ccw-hpc-2 — no XPMEM (s/iter) | Difference |
|---|---|---|---|
| hpcx-ucx-nobind-numa (baseline) | 2.604 | 2.602 | +0.1% |
| sysucx-fifo | 2.623 | 2.621 | +0.1% |
| sysucx-zcopy | 2.631 | 2.624 | +0.3% |
| sysucx-intra | 2.608 | 2.602 | +0.2% |

> **Result (Pass 4):** XPMEM alone provides **no measurable benefit** for the AeroSUV 57M model at 176 cores. The `cma` fallback transport is already efficient for this workload's message pattern (~324K cells/rank).

#### Benchmark results (Pass 6 — HPCX + sysucx + XPMEM focused, 8 configs)

Dedicated XPMEM run after fixing UCX device errors. All configs use HPCX + `-xsystemucx` + NUMA mapping (ppr:88:socket). Run `20260218_150355` on ccw-hpc-[1-4]:

| Rank | Configuration | Avg (s/iter) | Std (s) | CellIter/ws | Wall (s) | Node |
|---:|---|---:|---:|---:|---:|---|
| 1 | **hpcx-sysucx-numa-xpmem-rndv8k** | **2.597** | 0.035 | 126,618 | 137 | ccw-hpc-2 |
| 2 | hpcx-sysucx-numa-xpmem-rndv | 2.598 | 0.031 | 126,545 | 138 | ccw-hpc-3 |
| 3 | hpcx-sysucx-numa-xpmem-rndv4k | 2.599 | 0.044 | 126,492 | 139 | ccw-hpc-1 |
| 4 | hpcx-sysucx-bw-xpmem | 2.609 | 0.046 | 126,029 | 142 | ccw-hpc-3 |
| 5 | hpcx-sysucx-numa-xpmem | 2.612 | 0.056 | 125,884 | 139 | ccw-hpc-2 |
| 6 | hpcx-sysucx-auto-bw | 2.619 | 0.031 | 125,566 | 139 | ccw-hpc-4 |
| 7 | hpcx-sysucx-numa-xpmem-tuned | 2.633 | 0.026 | 124,878 | 148 | ccw-hpc-4 |
| 8 | hpcx-sysucx-numa (baseline, no XPMEM) | 2.640 | 0.158 | 124,552 | 140 | ccw-hpc-1 |

> **Key findings (Pass 6):**
> - **RNDV threshold tuning is the main lever:** The top 3 configs all use `UCX_RNDV_SCHEME=put_zcopy` with varying thresholds (8K/64K/4K) — within 0.09% of each other.
> - **XPMEM + UCX_TLS=all helps modestly:** Config #5 (xpmem, no RNDV tuning) vs #8 (baseline) = **2.612 vs 2.640 = 1.1% improvement**, and much lower variance (stdev 0.056 vs 0.158).
> - **Over-tuning hurts:** `UCX_UNIFIED_MODE=y UCX_MAX_RNDV_RAILS=1` (#7) performed worst among XPMEM configs (+1.4% vs best).
> - **Total spread:** Only 1.7% across all 8 configs.
> - **All runs clean** with `UCX_NET_DEVICES=mlx5_ib0:1` default in `starccm_bench.slurm`.

#### Current status

- **Kernel module**: Installed via DKMS (xpmem v2510.0.16, from DOCA packages) for kernel 6.8.0-1044-azure
- **Userspace library**: `libxpmem0` and `libxpmem-dev` packages available in the DOCA repo at `/usr/share/doca-host-3.2.1-044000-25.10-ubuntu2404/repo/pool/`
- **UCX plugin**: `libuct_xpmem.so` is bundled with HPCX UCX at `/opt/hpcx-v2.25.1-gcc-doca_ofed-ubuntu24.04-cuda13-x86_64/ucx/lib/ucx/`

**Four** components are required for XPMEM to work with StarCCM+:

| Component | Package / path | Default state |
|---|---|---|
| Kernel module | `xpmem-dkms` (DKMS, already installed) | Not loaded |
| Userspace library | `libxpmem0` deb in DOCA repo | Not installed |
| Device permissions | `/dev/xpmem` | Root-only (`crw-------`) |
| HPCX UCX in system ldconfig | `/etc/ld.so.conf.d/hpcx-ucx.conf` | Not configured |

> **Critical:** The OS-installed UCX at `/usr/lib/` (v1.20.0) was built `--without-xpmem` — it has no xpmem module in its compiled-in transport registry. Simply placing or symlinking `libuct_xpmem.so` into `/usr/lib/ucx/` does **not** work because UCX only loads modules it was compiled to know about. The solution is to make the HPCX UCX (also v1.20.0, built `--with-xpmem`) the system default via ldconfig. Both are ABI-compatible.

#### How to enable XPMEM on a compute node

All four steps must be done on **each compute node**. For a single node (e.g. ccw-hpc-1):

```bash
ssh ccw-hpc-1

# 1. Load the kernel module
sudo modprobe xpmem

# 2. Install the userspace library (from DOCA packages already on disk)
sudo dpkg -i /usr/share/doca-host-*/repo/pool/libxpmem0_*.deb \
             /usr/share/doca-host-*/repo/pool/libxpmem-dev_*.deb

# 3. Set device permissions for non-root users
sudo chmod 666 /dev/xpmem

# 4. Register HPCX UCX as system default (required for -xsystemucx to find xpmem)
#    The OS UCX was built --without-xpmem; HPCX UCX has xpmem support.
#    Both are v1.20.0 (same ABI), so this is safe.
echo '/opt/hpcx-v2.25.1-gcc-doca_ofed-ubuntu24.04-cuda13-x86_64/ucx/lib' | sudo tee /etc/ld.so.conf.d/hpcx-ucx.conf
echo '/opt/hpcx-v2.25.1-gcc-doca_ofed-ubuntu24.04-cuda13-x86_64/ucx/lib/ucx' | sudo tee -a /etc/ld.so.conf.d/hpcx-ucx.conf
sudo ldconfig
```

#### How to make XPMEM persistent across reboots

The above steps are lost on reboot. To make them permanent:

```bash
ssh ccw-hpc-1

# 1. Auto-load the kernel module at boot
echo "xpmem" | sudo tee /etc/modules-load.d/xpmem.conf

# 2. The libxpmem0 package is already installed (dpkg persists across reboots)
#    — but if nodes are reimaged, add to the image build or cloud-init

# 3. Persistent device permissions via udev rule
echo 'KERNEL=="xpmem", MODE="0666"' | sudo tee /etc/udev/rules.d/90-xpmem.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

#### Enable XPMEM on all compute nodes at once

Use `clush` or a loop to apply to all HPC nodes:

```bash
# With clush (if available)
clush -w ccw-hpc-[1-N] "sudo modprobe xpmem && \
  sudo dpkg -i /usr/share/doca-host-*/repo/pool/libxpmem0_*.deb \
               /usr/share/doca-host-*/repo/pool/libxpmem-dev_*.deb && \
  sudo chmod 666 /dev/xpmem && \
  echo 'xpmem' | sudo tee /etc/modules-load.d/xpmem.conf && \
  echo 'KERNEL==\"xpmem\", MODE=\"0666\"' | sudo tee /etc/udev/rules.d/90-xpmem.rules && \
  sudo udevadm control --reload-rules && sudo udevadm trigger && \
  echo '/opt/hpcx-v2.25.1-gcc-doca_ofed-ubuntu24.04-cuda13-x86_64/ucx/lib' | sudo tee /etc/ld.so.conf.d/hpcx-ucx.conf && \
  echo '/opt/hpcx-v2.25.1-gcc-doca_ofed-ubuntu24.04-cuda13-x86_64/ucx/lib/ucx' | sudo tee -a /etc/ld.so.conf.d/hpcx-ucx.conf && \
  sudo ldconfig"

# Or with a simple loop
for node in ccw-hpc-{1..4}; do
  echo "=== $node ==="
  ssh "$node" "sudo modprobe xpmem && \
    sudo dpkg -i /usr/share/doca-host-*/repo/pool/libxpmem0_*.deb \
                 /usr/share/doca-host-*/repo/pool/libxpmem-dev_*.deb 2>/dev/null && \
    sudo chmod 666 /dev/xpmem && \
    echo 'xpmem' | sudo tee /etc/modules-load.d/xpmem.conf && \
    echo 'KERNEL==\"xpmem\", MODE=\"0666\"' | sudo tee /etc/udev/rules.d/90-xpmem.rules && \
    sudo udevadm control --reload-rules && sudo udevadm trigger && \
    echo '/opt/hpcx-v2.25.1-gcc-doca_ofed-ubuntu24.04-cuda13-x86_64/ucx/lib' | sudo tee /etc/ld.so.conf.d/hpcx-ucx.conf && \
    echo '/opt/hpcx-v2.25.1-gcc-doca_ofed-ubuntu24.04-cuda13-x86_64/ucx/lib/ucx' | sudo tee -a /etc/ld.so.conf.d/hpcx-ucx.conf && \
    sudo ldconfig && \
    echo 'OK'"
done
```

#### Verify XPMEM is working

```bash
ssh ccw-hpc-1

# Check kernel module is loaded
lsmod | grep xpmem

# Check device permissions
ls -la /dev/xpmem
# Expected: crw-rw-rw- 1 root root 10, 118 ... /dev/xpmem

# Check userspace library is installed
ldconfig -p | grep xpmem
# Expected: libxpmem.so.0 (libc6,x86-64) => /lib/x86_64-linux-gnu/libxpmem.so.0

# Check HPCX UCX is the system default (must show HPCX path first)
ldconfig -p | grep libucp.so.0
# Expected first line: libucp.so.0 => /opt/hpcx-v2.25.1-.../ucx/lib/libucp.so.0

# Check UCX sees the xpmem transport (uses system UCX, which is now HPCX UCX)
ucx_info -d | grep 'Transport:'
# Should include: #      Transport: xpmem
```

#### Run StarCCM+ with XPMEM

No code changes needed. Once XPMEM is enabled and HPCX UCX is registered in ldconfig, UCX auto-discovers and prefers it for intra-node communication:

```bash
STARCCM_HPCX=1 \
XSYSTEMUCX=1 \
FABRIC=ucx \
CPUBIND=off \
MPPFLAGS="--map-by ppr:88:socket --bind-to core" \
MODEL=/shared/apps/starccm/models/AeroSUV_Steady_Segregated_57M_V17_04_007_v2.sim \
sbatch starccm_bench.slurm
```

> **Note:** XPMEM requires the `-xsystemucx` flag (`XSYSTEMUCX=1`) to bypass StarCCM+'s bundled UCX (v1.8.0, no xpmem). With HPCX UCX registered as system default via ldconfig, `-xsystemucx` picks up HPCX's UCX which includes the xpmem transport plugin.
>
> **Important:** The OS-installed UCX (`/usr/lib/libucp.so`, v1.20.0) was built `--without-xpmem`. Its module registry does not include xpmem, so just symlinking `libuct_xpmem.so` into `/usr/lib/ucx/` does **not** work. The HPCX UCX ldconfig override (step 4 above) is mandatory.

#### Verify XPMEM is being used in a job

```bash
# Set UCX_ENVS="UCX_LOG_LEVEL=info" temporarily and look for:
grep "xpmem" starccm-bench_<JOBID>.out
```

#### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ucx_info -d` shows no xpmem transport | `libxpmem.so.0` not installed | `sudo dpkg -i /usr/share/doca-host-*/repo/pool/libxpmem0_*.deb` |
| `ucx_info -d` shows no xpmem but libxpmem is installed | System UCX built `--without-xpmem` (default) | Register HPCX UCX via ldconfig (step 4 above) |
| `modprobe xpmem` fails | Kernel module not built for current kernel | Check `dkms status \| grep xpmem`; rebuild with `sudo dkms install xpmem/2510.0.16` |
| `/dev/xpmem` permission denied | Device is root-only after reboot | Add udev rule (see above) or `sudo chmod 666 /dev/xpmem` |
| XPMEM loaded but UCX still uses `cma` | UCX plugin can't find `libxpmem.so.0` | Run `ldconfig -p \| grep xpmem`; install `libxpmem0` package |
| StarCCM+ warns "transport 'xpmem' is not available" | `-xsystemucx` picks up OS UCX (no xpmem) | Ensure `/etc/ld.so.conf.d/hpcx-ucx.conf` exists and `sudo ldconfig` was run |
| StarCCM+ Python launcher ValueError on `-x VAR` | StarCCM+'s `openmpi.py` requires `-x VAR=value` format | Do not pass bare `-x VAR` in mppflags; use ldconfig instead |
| `ldconfig -p \| grep libucp` shows `/lib/libucp.so.0` first | HPCX UCX ldconfig not applied | Create `/etc/ld.so.conf.d/hpcx-ucx.conf` and run `sudo ldconfig` |
| `mlx5dv_devx_alloc_uar(device=mlx5_an0) Cannot allocate memory` | Azure AccelNet NIC (`mlx5_an0`) exhausts UAR BARs with 176 ranks | Non-fatal warning. Set `UCX_NET_DEVICES=mlx5_ib0:1` to prevent UCX from using AccelNet for transports (default in `starccm_bench.slurm`). Note: `UCX_IB_DEVICES` is **not** a valid UCX variable. |

#### UCX tunings specific to HPCX UCX 1.20 (with XPMEM via ldconfig)

The HPCX UCX 1.20.0 (registered as system default via ldconfig) supports additional tuning parameters not available in the bundled UCX:

| Variable | Recommended value | Description |
|---|---|---|
| `UCX_POSIX_FIFO_SIZE` | `1024` | POSIX shared memory FIFO depth (default 256); increase for 176 ranks contending |
| `UCX_POSIX_FIFO_ELEM_SIZE` | `256` | FIFO element size in bytes (default 128); reduces header overhead |
| `UCX_UNIFIED_MODE` | `y` | Skip capability negotiation — all ranks on same node have identical capabilities |
| `UCX_ZCOPY_THRESH` | `16384` | Lower zero-copy threshold (default auto) to use zcopy for medium messages |
| `UCX_MAX_RNDV_RAILS` | `1` | Default 2; single-node has no IB, second rail is wasted |
| `UCX_RNDV_THRESH` | `65536` | Raise eager-to-rendezvous threshold to 64KB (default ~8KB); reduces protocol overhead for medium messages |

## Slurm jobs