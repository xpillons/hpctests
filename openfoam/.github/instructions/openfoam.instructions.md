---
name: 'openfoam'
description: 'How to load and run OpenFOAM'
---
# OpenFOAM Instructions
To load and run OpenFOAM, follow these steps:
```bash
source /cvmfs/software.eessi.io/versions/2023.06/init/bash
ml OpenFOAM
source $FOAM_BASH
```

Open FOAM documentation reference https://www.openfoam.com/

Tutorials root path is $FOAM_TUTORIALS

running a case will be done by going to the case directory and running:
```bash
./Allrun
```

This will execute the Allrun script which is a common way to run OpenFOAM cases. Make sure to check the Allrun script for any specific instructions or commands that need to be executed for your particular case.
For more detailed instructions on how to set up and run OpenFOAM cases, refer to the OpenFOAM documentation and tutorials provided in the $FOAM_TUTORIALS directory.

When using MPI, configure the environment variable $FOAM_MPIRUN_FLAGS, for example:
```bash
export FOAM_MPIRUN_FLAGS="--bind-to core --map-by slot"
```

## MPI Performance Tuning (Benchmark Results)

Benchmark results on HPC partition (Standard_HB176rs_v4, AMD EPYC 9V33X, 2×88 cores, 4 NUMA nodes) with drivaerFastback tutorial. Four passes were run; Passes 3–4 used 3 repeats per config for statistical confidence.

Recommended MPI flags:
```bash
export FOAM_MPIRUN_FLAGS="--bind-to core --map-by l3cache --mca pml ucx -x UCX_ZCOPY_THRESH=16384"
```

### Pass 4 Results — L mesh (~22.5M cells, 2000 iterations, Job 1230):

| Cores | Mapping | Extra | Best (s) | Mean (s) | Worst (s) | Wall Best (s) |
|-------|---------|-------|---------|---------|----------|---------------|
| 176 | l3cache | ZCOPY=16384 | **1898** | **1902** | 1904 | **2005** |
| 176 | slot | ZCOPY=16384 | 1959 | 1980 | 1994 | 2064 |
| 176 | slot | — | 1976 | 1983 | 1994 | 2091 |
| 128 | l3cache | ZCOPY=16384 | 2028 | 2032 | 2034 | 2102 |
| 128 | slot | ZCOPY=16384 | 2040 | 2043 | 2046 | 2111 |
| 128 | slot | — | 2042 | 2044 | 2045 | 2113 |

### Pass 3 Results — M mesh (~3M cells, 1000 iterations, Job 1228):

| Cores | Mapping | Extra | Best (s) | Mean (s) | Worst (s) | Wall Best (s) |
|-------|---------|-------|---------|---------|----------|---------------|
| 176 | l3cache | ZCOPY=16384 | **81.0** | 82.8 | 83.9 | **100** |
| 176 | slot | ZCOPY=16384 | 81.7 | 82.7 | 83.2 | 100 |
| 176 | slot | — | 83.1 | 84.5 | 85.7 | 102 |
| 128 | l3cache | ZCOPY=16384 | 89.0 | 90.1 | 91.1 | 103 |
| 128 | slot | — | 90.1 | 90.8 | 91.7 | 104 |

### Pass 5 Results — UCX Deep-Dive (L mesh, 176 cores, Job 1232, 17/33 tests completed):

All variants tested at 176 cores with `--map-by l3cache`. Only `UCX_ZCOPY_THRESH` value matters; other UCX parameters are noise.

| UCX Option | Best (s) | Mean (s) | Notes |
|------------|---------|---------|-------|
| ZCOPY=16384 (baseline, 3 runs) | 1895 | 1896 | Current recommended config |
| ZCOPY=8192 (2 runs) | 1896 | 1900 | Equivalent to baseline |
| ZCOPY=32768 (2 runs) | 1935 | 1936 | **~2% worse** — avoid |
| RNDV_THRESH=8192 (2 runs) | 1900 | 1902 | No improvement |
| RNDV_THRESH=16384 (2 runs) | 1898 | 1900 | No improvement |
| RNDV_THRESH=65536 (2 runs) | 1903 | 1908 | No improvement |
| TLS=self,sm,rc (2 runs) | 1903 | 1904 | No improvement |
| TLS=self,sm,rc + mlx5_ib0:1 (2 runs) | 1893 | 1902 | Within variance |

Key findings:
- **Best config**: 176 cores, `--bind-to core --map-by l3cache` with `UCX_ZCOPY_THRESH=16384`. Confirmed across both M and L mesh sizes, validated by UCX deep-dive, **and confirmed for multi-node scaling** (2-node and 4-node).
- **UCX tuning beyond ZCOPY_THRESH=16384 is noise**: Pass 5 tested RNDV_THRESH, TLS, NET_DEVICES, and RNDV_SCHEME — all 17 variants clustered within 1893–1912s (1% spread). Only ZCOPY_THRESH=32768 is clearly worse (+2%).
- **l3cache mapping advantage grows with mesh size**: ~0.5–1s on M mesh (within noise) but **4.1% faster** on L mesh (1902s vs 1980s). With more cells per rank, L3 cache locality becomes significant.
- **176 cores beats 128 cores** by ~6.8% solver time on L mesh (1902s vs 2032s) and ~9% on M mesh (81s vs 89s).
- **UCX_ZCOPY_THRESH=16384** gives ~2% gain at 176 cores on M mesh. On L mesh the effect is absorbed into the l3cache+ZCOPY combo.
- **176+l3cache+ZCOPY has tightest variance**: 6s spread on L mesh (0.3%) vs 30–80s for slot configs.
- **ob1 transport is consistently slower** (~86s at 176 on M mesh). Stick with UCX.
- **ppr placement doesn't help** — `ppr:44:numa` is worse than plain l3cache.
- Scaling is monotonic: more cores = faster solver, but diminishing returns past ~144 cores on M mesh.

### Pass 6 Results — Multi-Node Scaling (L mesh, Job 1233/1265):

Same recommended config works across node counts. All 31 MPI variants tested per node count; top configs all within noise of baseline.

| Nodes | Cores | Mapping | Extra | Best Solver (s) | Speedup vs 1-node | Efficiency |
|-------|-------|---------|-------|-----------------|-------------------|------------|
| 1 | 176 | l3cache | ZCOPY=16384 | **1893** | 1.00× | — |
| 2 | 352 | l3cache | ZCOPY=16384 | **808** | 2.34× | 117% |
| 4 | 704 | l3cache | ZCOPY=16384 | **503** | 3.76× | 94% |

2-node details (31 tests completed):
- Baseline (l3cache+ZCOPY=16384, 3 runs): best 808s, mean 820s, spread ~20s
- dc transport / btl-disabled variants: 803–804s (within noise of baseline)
- node mapping: 816s, slot: 826s, numa: 823s — all slightly worse
- CMA / rc+IB pin / multi-rail: 886–964s — worse, avoid for multi-node

4-node details (18/31 tests completed):
- Baseline (l3cache+ZCOPY=16384): best 503s (high cross-node variance: 503–641s)
- node mapping: 498s, slot: 506s — within noise
- ZCOPY=8192: 517s — slightly worse

Multi-node key findings:
- **Same config works at all scales**: `--bind-to core --map-by l3cache --mca pml ucx -x UCX_ZCOPY_THRESH=16384` is optimal or within noise for 1, 2, and 4 nodes.
- **Super-linear scaling at 2 nodes** (117% efficiency) — likely due to more L3 cache and memory bandwidth per cell.
- **Near-linear scaling at 4 nodes** (94% efficiency) — inter-node communication overhead starts to appear.
- **Multi-node variance is higher**: ~2.5% at 2 nodes, ~27% at 4 nodes (vs 0.3% single-node). Cross-node scheduling noise dominates.
- **No inter-node transport variant helps**: dc, rc, CMA, IB pinning, multi-rail — all within noise or worse than default UCX auto-selection.

### Mesh Optimization: Reconstruct/Re-decompose Does NOT Work

Attempting to mesh with fewer cores (for faster meshing) and then reconstruct + re-decompose to more cores for the solver **fails**. Tested in Job 1229 with `redistributePar -reconstruct` followed by `decomposePar` to 176 cores — all tests (8, 16, 32 mesh cores) failed with:

> `GAMG: No coarse levels created, either matrix too small for GAMG or nCellsInCoarsestLevel too large`

The GAMG algebraic multigrid solver requires a minimum cells-per-subdomain ratio that isn't met when re-partitioning a mesh originally decomposed for fewer cores. **Always mesh and solve with the same core count.** Use `Allrun -c N -m M` which handles both phases consistently.

The UCX transport layer may emit `unknown link speed 0x80` warnings on Azure HB-series VMs. These are cosmetic and do not affect correctness. To suppress them:
```bash
export UCX_LOG_LEVEL=error
```

## HPCX MPI Compatibility

The node image provides HPCX MPI (`mpi/hpcx`) at `/opt/hpcx-v2.25.1-gcc-doca_ofed-ubuntu24.04-cuda13-x86_64/`. However, **HPCX cannot be used with EESSI OpenFOAM** due to:

1. **GLIBC mismatch**: HPCX's `libmpi.so` requires `GLIBC_2.38` but EESSI's compat layer provides an older glibc, so `LD_PRELOAD` fails.
2. **RPATH lock-in**: EESSI OpenFOAM binaries have hardcoded RPATH pointing to EESSI's OpenMPI 4.1.5, preventing `LD_LIBRARY_PATH` override.
3. **ORTE wire protocol mismatch**: Using HPCX's `mpirun` (4.1.9a1) to launch EESSI binaries linked against OpenMPI 4.1.5 causes `ORTE_ERROR_LOG` and `MPI_Init_thread` failures.
4. **Missing host_injections**: The EESSI `rpath_overrides/OpenMPI/system/` directory (designed for host MPI injection) does not exist on these nodes.

Use the EESSI-bundled OpenMPI with `UCX_LOG_LEVEL=error` to suppress cosmetic warnings.

When running on the cluster, tutorial cases located under $FOAM_TUTORIALS are on a read-only filesystem (CVMFS). Copy the case to a writable directory before running it, and fix permissions with `chmod -R u+w` since `cp -r` preserves the read-only CVMFS permissions.

Note: The EESSI software stack is architecture-aware. The `$FOAM_TUTORIALS` path will resolve differently depending on the CPU architecture (e.g. `x86_64/intel/skylake_avx512` on login nodes vs `x86_64/amd/zen4` on compute nodes). Always let `$FOAM_TUTORIALS` resolve at runtime on the compute node rather than hardcoding paths from the login node.

Not all tutorial cases include an `Allrun` script. The `drivaerFastback` case under `$FOAM_TUTORIALS/incompressibleFluid/drivaerFastback` is the recommended default tutorial. It is a parallel MPI case that supports options:
- `-c <nCores>` — number of MPI ranks (must be >= 2, default 8)
- `-m <S|M|L|XL>` — mesh size (S: 440k, M: 3M default, L: 22.5M, XL: ~200M cells)

Example: `./Allrun -c 176 -m M`

## Tutorial `.orig` Files and `numberOfSubdomains`

Some tutorials (including `drivaerFastback`) ship configuration files as `.orig` suffixed copies (e.g. `system/decomposeParDict.orig`, `system/controlDict.orig`, `system/snappyHexMeshDict.orig`). The `Allrun` script normally restores these and sets `numberOfSubdomains` via the `-c` flag.

When running meshing and solver steps manually (outside `Allrun`), you must:
1. **Restore `.orig` files** before any OpenFOAM command:
   ```bash
   cd "$case_dir"
   for f in system/*.orig; do [ -f "$f" ] && cp "$f" "${f%.orig}"; done
   ```
2. **Set `numberOfSubdomains`** to match your target core count:
   ```bash
   foamDictionary -entry numberOfSubdomains -set "$ncores" system/decomposeParDict
   ```
3. **Use relative paths** with `foamDictionary` — it prepends the current working directory to absolute paths, producing broken double-paths.

If `numberOfSubdomains` is not updated, `runParallel` (which calls `getNumberOfProcessors()` internally) will use the tutorial default of 8, regardless of your Slurm allocation.

## Bash Strict Mode Incompatibility

**Do NOT use `set -euo pipefail`** in scripts that source EESSI or OpenFOAM:
- `set -u` causes `EESSI_VERSION_OVERRIDE: unbound variable` during EESSI init
- `set -e` causes `pop_var_context: head of shell_variables not a function context` when sourcing `$FOAM_BASH`

Use `source $FOAM_BASH || true` to absorb the non-zero exit code from `$FOAM_BASH` sourcing. Apply error checking manually where needed rather than relying on `set -e`.