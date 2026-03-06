---
name: oodapp
description: "Use when building, creating, or debugging Open OnDemand (OOD) batch connect applications, sandbox apps, form.yml, submit.yml.erb, or script.sh.erb files"
---

# Open OnDemand Application Development

Documentation: https://osc.github.io/ood-documentation/latest/how-tos/app-development.html

## Access
- SSH to the OOD virtual machine with `ssh ood` (sudo access available)
- System apps are in `/var/www/ood/apps/sys` (use as reference)
- **Always create new apps in the user sandbox**: `$HOME/ondemand/dev/<app_name>/`
- The `$HOME` directory is shared between login nodes and the OOD VM, so apps created on either side are visible to both

## Application Structure

An OOD batch connect app requires these files:

```
<app_name>/
├── manifest.yml           # App metadata (name, category, description, role)
├── form.yml               # Submission form definition (fields, widgets, validation)
├── submit.yml.erb         # Slurm scheduler arguments (ERB template)
└── template/
    └── script.sh.erb      # Job script executed on compute node (ERB template, MUST be chmod +x)
```

Use predefined attributes where possible to leverage built-in OOD features (e.g. `bc_num_hours`, `bc_num_nodes`). 

Available global form items (defined in `/etc/ood/config/ondemand.d/global_bc_items.yml`):
- **global_ccw_clusters** — hidden field, value `slurm_ccw`
- **global_ccw_queues** — select widget with partitions: gpu, hpc, hpcsc, htc (includes data attributes for GPU visibility)

## Cluster Configuration Reference

Cluster config are located in `/etc/ood/config/clusters.d`

## Critical: File Permissions

The `template/script.sh.erb` file **must have the execute bit set** (`chmod +x template/script.sh.erb`). OOD copies the template to generate `script.sh` preserving permissions, then executes it directly. Without `+x`, the job fails with `Permission denied`.

## Critical: Slurm Task Count in `submit.yml.erb`

If the job script relies on `$SLURM_NTASKS` (e.g. to pass a core count to `Allrun -c`), you **must** include `--ntasks-per-node=<N>` in the scheduler native args. Without it, Slurm does not set `SLURM_NTASKS` and the variable expands to an empty string, causing argument parsing failures in the job script.

For the **hpc** partition, use `--ntasks-per-node=176`.

## Existing Reference Apps
- `/var/www/ood/apps/sys/bc_vscode` — VSCode on compute node (uses `global_ccw_clusters`, `global_ccw_queues`, Slurm submission)
- `/var/www/ood/apps/sys/systemd_vscode` — VSCode on login node (systemd adapter, no Slurm)
