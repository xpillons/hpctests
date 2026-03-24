# StarCCM+ Open OnDemand Application

This is an Open OnDemand (OOD) batch connect application that provides a web form for submitting Simcenter STAR-CCM+ jobs via Slurm.

## How It Works

1. **`form.yml`** — Defines the web form fields (model file, MPI driver, fabric, CPU binding, etc.)
2. **`submit.yml.erb`** — Generates the Slurm `sbatch` arguments from form inputs (cluster, partition, nodes, tasks per node)
3. **`template/script.sh.erb`** — ERB template rendered into a shell script that sets up the environment, fixes OOD/Slurm conflicts, and calls `starccm.slurm`
4. **`manifest.yml`** — Application metadata (name, category, description)

## What to Customize

The following items are environment-specific and must be adapted for your cluster.

### `form.yml`

| Field | Current Value | What to Change |
|---|---|---|
| `global_ccw_clusters` / `global_ccw_queues` | CCW-specific global selectors | Replace with your cluster/partition selectors or hardcode values |
| `model_path.directory` | `/shared/apps/starccm/models` | Path where your model files are stored |
| `model_path.favorites` | `/shared/apps/starccm/models` | Update to match your model directory |
| `batch_macro.directory` | `/shared/home` | Base directory for browsing macro files |
| `bc_num_nodes.max` | `16` | Adjust to your cluster size |
| MPI driver options | `openmpi`, `intel` | Add or remove drivers available on your system |

### `submit.yml.erb`

| Setting | Current Value | What to Change |
|---|---|---|
| `--ntasks-per-node` | `176` | Number of cores per node on your hardware |
| `--hint=nomultithread` | Enabled | Remove if your nodes do not have SMT |

### `template/script.sh.erb`

| Setting | Current Value | What to Change |
|---|---|---|
| `STARCCM_REPO` | `~/hpctests/starccm` | Path where this repository is cloned |
| `WORKDIR` | `$HOME/starccm` | Working directory for StarCCM+ output |

### `manifest.yml`

Update `name`, `category`, and `description` if needed to match your portal's naming conventions.
