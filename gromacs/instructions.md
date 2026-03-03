# Benchmarking GROMACS

## Resources
Documentation can be found at https://manual.gromacs.org/current/index.html
Some performance benchmarking results and cookbooks can be found at:
- https://hpc.fau.de/2024/08/13/gromacs-2024-1-on-brand-new-gpgpus/
- https://docs.bioexcel.eu/gromacs_bpg/en/master/cookbook/cookbook.html
- https://developer.nvidia.com/blog/massively-improved-multi-node-nvidia-gpu-scalability-with-gromacs/
- https://blog.salad.com/gromacs-benchmark/
- https://hpc.fau.de/files/2024/07/2024-07-09_NHR@FAU_HPC-Cafe_Gromacs-Benchmarks.pdf
- https://www.mpinat.mpg.de/grubmueller/bench

## Setup

Download and extract the benchmark input files:
```bash
cd hpctests/gromacs
wget https://www.mpinat.mpg.de/benchPEP-h
unzip benchPEP-h
```
This produces `benchPEP-h.tpr` (the simulation input file, ~300 MB).

GROMACS is loaded from EESSI:
```bash
source /cvmfs/software.eessi.io/versions/2023.06/init/bash
ml load GROMACS/2024.4-foss-2023b-CUDA-12.4.0
```

## Benchmark Suite

The suite consists of three scripts:

| Script | Purpose |
|--------|---------|
| `gromacs_bench.slurm` | Slurm job script — runs a single GROMACS benchmark, driven by `BENCH_*` environment variables |
| `run_benchmarks.sh` | Orchestrator — submits multiple jobs sweeping parameter combinations |
| `analyze_results.sh` | Analyzer — parses CSV results, ranks configurations, generates a report |

### Parameters Explored

| Parameter | Values tested | Description |
|-----------|--------------|-------------|
| MPI ranks (`np`) | 1, 2, 4, 6, 8, 10, 12 | Number of MPI processes (must be multiple of 2 GPUs) |
| OpenMP threads (`ntomp`) | auto (80/np) + targeted | Threads per rank |
| PME ranks (`npme`) | 0 (auto→1), 1 | Dedicated PME ranks (max 1; npme=2 requires cuFFTMp) |
| GPU direct comm | yes, no | `-bonded gpu -update gpu` + `GMX_ENABLE_DIRECT_GPU_COMM` |
| GPU PME decomposition | yes, no | `-pmefft gpu` + `GMX_GPU_PME_DECOMPOSITION` |
| Neighbor list interval (`nstlist`) | 0 (default), 150, 175, 200, 250, 300 | Frequency of neighbor list updates |
| PME tuning (`tunepme`) | yes, no | Enable/disable PME auto-tuning |
| Dynamic load balancing (`dlb`) | auto, yes | Load balancing mode |

### MPI Transport: UCX

Multi-rank runs use UCX instead of Open MPI's default smcuda BTL to avoid
`cuMemGetAddressRange failed` CUDA errors. This is configured automatically
in the slurm script for np≥2:

```bash
export OMPI_MCA_pml=ucx
export OMPI_MCA_btl=^smcuda,ofi
export OMPI_MCA_osc=ucx
export UCX_TLS=rc,sm,cuda_copy,cuda_ipc,gdr_copy
export UCX_RNDV_SCHEME=put_zcopy
```

**Impact**: UCX eliminated all CUDA errors and provided a ~2x speedup for
multi-rank GPU-aware MPI configs (e.g., np=8 went from 3.3 to 6.7 ns/day).

### Target Hardware
- **Partition:** `gpu`
- **Node:** H100 NVL (2 GPUs, 80 cores, ~608 GB RAM)
- **Local storage:** `/nvme/tmp/` (used automatically when available)

## Recommended Workflow

1. **Quick screening** (5000 steps, ~4 min/job):
   ```bash
   ./run_benchmarks.sh --quick
   ```
2. **Monitor progress:**
   ```bash
   squeue -u $USER
   ```
3. **Analyze results** (reads from `results/latest/`):
   ```bash
   ./analyze_results.sh
   ```
4. **Full benchmark** (20000 steps) for accurate numbers:
   ```bash
   ./run_benchmarks.sh
   ```
5. **Analyze a specific pass:**
   ```bash
   ./analyze_results.sh results/20260210_182328_quick/
   ```

### Script Options
```
./run_benchmarks.sh [--quick] [--dry-run] [--steps N]

  --quick     5000 steps (fast screening)
  --dry-run   Show what would be submitted without submitting
  --steps N   Custom step count
```

Each pass creates a timestamped directory under `results/` (e.g. `results/20260210_182328_quick/`) with a `latest` symlink pointing to the most recent one.

## Known Issues & Workarounds

1. **EESSI init + `set -u`**: The EESSI init script references unset variables. The slurm script wraps the `source` call with `set +u` / `set -u`.

2. **`-npme` required for multi-rank GPU PME**: GROMACS errors with *"PME tasks were required to run on GPUs with multiple ranks but -npme was not specified"*. The slurm script auto-sets `-npme 1` when `np >= 2`.

3. **PME tuning conflicts with counter resets**: Causes *"PME tuning was still active when attempting to reset counters"*. Fixed by disabling PME tuning with `-notunepme` and using `-resethway` for clean timing.

4. **PSM3 fabric crash with multi-rank runs**: Causes *"psm3_ep_connect returned error PSM could not set up shared memory segment"*. Fixed by setting `export FI_PROVIDER=verbs` for all multi-rank runs.

5. **`srun` doesn't inherit module environment**: `gmx_mpi` not found by srun tasks. Fixed by resolving the full binary path with `which gmx_mpi` and using `srun --export=ALL --mpi=pmix`.

6. **smcuda `cuMemGetAddressRange failed` errors**: Open MPI's built-in CUDA transport (smcuda BTL) produces hundreds of `cuMemGetAddressRange failed` warnings on multi-rank GPU-aware MPI runs, silently degrading performance by ~50%. Fixed by switching to UCX PML (`OMPI_MCA_pml=ucx`, `OMPI_MCA_btl=^smcuda,ofi`) with CUDA-aware transports (`UCX_TLS=rc,sm,cuda_copy,cuda_ipc,gdr_copy`).

7. **np must be a multiple of the number of GPUs**: Odd rank counts like np=3 on 2 GPUs cause *"Inconsistency in user input: There were 3 GPU tasks found but 2 GPUs were available"*. Only use np values that are multiples of 2 (the GPU count).

8. **npme=2 requires cuFFTMp**: Setting npme≥2 causes *"PME tasks were required to run on more than one CUDA-device. To enable this feature, use MPI with CUDA-aware support and build GROMACS with cuFFTMp support."* Stick with npme=0 or npme=1.

## Optimization Results Summary

### Best Configuration (benchPEP-h on 1 node, 2× H100 NVL)

```bash
# Optimal: 6.887 ns/day, 518s wall time (20000-step full pass)
srun --export=ALL --mpi=pmix -n 6 gmx_mpi mdrun \
  -s benchPEP-h.tpr -ntomp 13 -npme 1 \
  -bonded gpu -nb gpu -pme gpu -update gpu \
  -nstlist 175 -notunepme -resethway -noconfout -pin on

# Required environment variables:
export GMX_ENABLE_DIRECT_GPU_COMM=1
export GMX_FORCE_GPU_AWARE_MPI=1
export FI_PROVIDER=verbs
export OMPI_MCA_pml=ucx
export OMPI_MCA_btl=^smcuda,ofi
export OMPI_MCA_osc=ucx
export UCX_TLS=rc,sm,cuda_copy,cuda_ipc,gdr_copy
export UCX_RNDV_SCHEME=put_zcopy
```

### Performance Ranking (full pass, 20000 steps)

| Rank | Config | ns/day | Wall(s) | vs np=1 | Notes |
|------|--------|--------|---------|---------|-------|
| 1 | np=6 nt=13 npme=1 nsl175 | **6.887** | **518** | **+68%** | **Champion** |
| 2 | np=6 nt=13 npme=1 nsl200 | 6.877 | 518 | +68% | |
| 3 | np=6 nt=13 npme=1 nsl200+gpd | 6.828 | 522 | +67% | |
| 4 | np=6 nt=13 npme=1 nsl150 | 6.823 | 523 | +67% | |
| 5 | np=6 nt=8 npme=1 nsl200 | 6.783 | 522 | +66% | Fewer threads OK |
| 6 | np=6 nt=10 npme=1 nsl200 | 6.737 | 525 | +65% | |
| 7 | np=8 nt=10 npme=1 nsl200+gpd | 6.711 | 529 | +64% | |
| 8 | np=8 nt=10 npme=1 nsl150 | 6.698 | 530 | +64% | |
| 9 | np=6 nt=13 npme=0 (baseline) | 6.685 | 533 | +63% | |
| 10 | np=6 nt=13 npme=1 (baseline) | 6.655 | 536 | +63% | |
| 11 | np=8 nt=10 npme=1 nsl175 | 6.641 | 535 | +62% | |
| 12 | np=8 nt=10 npme=0 (baseline) | 6.550 | 541 | +60% | |
| 13 | np=12 nt=6 npme=1 nsl200 | 6.191 | 576 | +51% | Too many ranks |
| 14 | np=4 nt=20 npme=1 nsl200 | 6.142 | 575 | +50% | |
| 15 | np=10 nt=8 npme=1 nsl200 | 5.965 | 594 | +46% | |
| 16 | np=4 nt=20 npme=1 (baseline) | 5.919 | 597 | +45% | |
| -- | np=1 nt=80 (baseline) | 4.090 | 854 | -- | Reference |
| -- | np=2 nt=40 gpu_comm=no | 1.977 | 1760 | -52% | Worst |

### Key Findings

1. **UCX transport is essential**: Switching from smcuda BTL to UCX PML doubled multi-rank performance and eliminated all CUDA errors.
2. **np=6 is optimal**: 6 ranks (3 per GPU) with 13 threads each maximizes GPU utilization without excessive MPI overhead.
3. **nstlist=175 is the sweet spot**: Reducing neighbor list update frequency from default (~100) to 175 gives ~3-4% improvement. Going beyond 200 hurts.
4. **GPU direct communication is mandatory** for multi-rank: Without it, performance drops to 2.0-2.9 ns/day (full-pass confirmed).
5. **npme=1 is optimal**: Auto-PME and explicit npme=1 perform identically. npme=2 is unsupported without cuFFTMp.
6. **Thread count is robust for np=6**: 8-13 threads all perform within 3% — the GPU is the bottleneck, not CPU threads.
7. **Wall time scales linearly with ns/day**: The best config (6.887 ns/day) completes 20000 steps in 518s vs 854s for np=1 — a 39% wall time reduction.
8. **Consistency across pass lengths**: Quick (5000 steps) and full (20000 steps) passes produce consistent rankings, confirming quick mode is reliable for screening.

### Optimization Journey

| Pass | Best ns/day | Key change |
|------|-------------|------------|
| 1 (quick) | 4.059 | Initial sweep (smcuda, 8 failures) |
| 2 (quick) | 4.096 | Fixed PME tuning + PSM3 crashes |
| 3 (full) | 4.091 | Added tunepme, nstlist, dlb options |
| 4 (quick) | 4.096 | Added np=3/6, nstlist sweep |
| 5 (quick+UCX) | 6.755 | **UCX transport fix — 2x speedup** |
| 6 (targeted) | 6.837 | Fine-tuned nstlist=175, thread counts |
| 7 (full) | **6.887** | **Confirmed with 20000 steps** |