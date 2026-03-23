---
name: oodapp
description: "Use when building, creating, or debugging Open OnDemand (OOD) batch connect applications, sandbox apps, form.yml, submit.yml.erb, or script.sh.erb files"
applyTo: "**/ondemand/dev/**"
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

## Critical: Manifest Must Include `role`

The `manifest.yml` file **must** include `role: batch_connect` for any batch connect application. Without this field, OOD will not display the app in the dashboard. The manifest must contain at minimum: `name`, `role`, and `category`. 

Available global form items (defined in `/etc/ood/config/ondemand.d/global_bc_items.yml`):
- **global_ccw_clusters** — hidden field, value `slurm_ccw`. This field already sets the cluster, so do **not** add a top-level `cluster:` key in `form.yml` when using it.
- **global_ccw_queues** — select widget with partitions: gpu, hpc, hpcsc, htc (includes data attributes for GPU visibility)

## Critical: Do Not Specify `cluster` in `form.yml` When Using `global_ccw_clusters`

The `global_ccw_clusters` global form item already provides the cluster value. 
Set `cluster` in submit.yml.erb.

## Cluster Configuration Reference

Cluster config are located in `/etc/ood/config/clusters.d`

## Critical: File Permissions

The `template/script.sh.erb` file **must have the execute bit set** (`chmod +x template/script.sh.erb`). OOD copies the template to generate `script.sh` preserving permissions, then executes it directly. Without `+x`, the job fails with `Permission denied`.

## Critical: Slurm Task Count in `submit.yml.erb`

If the job script relies on `$SLURM_NTASKS`, you **must** include `--ntasks-per-node=<N>` in the scheduler native args. Without it, Slurm does not set `SLURM_NTASKS` and the variable expands to an empty string, causing argument parsing failures in the job script.

For the **hpc** partition, use `--ntasks-per-node=176`.

## Critical: Passing Custom Form Variables to the Job Script

Custom form attributes (any attribute that is **not** a predefined `bc_*` or `global_*` field) are **not** available as Ruby variables inside `template/script.sh.erb`. The ERB template context for `script.sh.erb` only exposes a limited set of built-in variables.

To make custom attributes available in the job script:

1. **`submit.yml.erb`** — export them via `job_environment`:
   ```yaml
   script:
     job_environment:
       MY_VAR: "<%= my_var %>"
   ```
2. **`template/script.sh.erb`** — reference them as shell environment variables (`$MY_VAR`), **never** as ERB expressions (`<%= my_var %>`).

This applies to **every** custom form field. If the job script accepts N arguments derived from form fields, all N must appear in `job_environment`.

## Critical: `submit.yml.erb` Overwrites Native Array from `bc_num_nodes`

When `submit.yml.erb` defines a `native` array, it **replaces** (not merges with) any native args contributed by smart attributes like `bc_num_nodes`. This means:

- **`bc_num_hours`** — safe, uses scalar `wall_time` key. Do **not** add `--time` to `native`.
- **`bc_num_nodes`** — **must** be re-included as `-N` in `native`, otherwise Slurm defaults to 1 node.

Use the same ERB block pattern as the reference app `bc_vscode`:

```erb
# submit.yml.erb
<%-
scheduler_args = ["-N", bc_num_nodes]
scheduler_args += ["-p", global_ccw_queues]
scheduler_args += ["--ntasks-per-node=176"]
scheduler_args += ["--exclusive"]
-%>

script:
  native:
  <%- scheduler_args.each do |arg| %>
    - "<%= arg %>"
  <%- end %>
```

## Existing Reference Apps
- `/var/www/ood/apps/sys/bc_vscode` — VSCode on compute node (uses `global_ccw_clusters`, `global_ccw_queues`, Slurm submission)
- `/var/www/ood/apps/sys/systemd_vscode` — VSCode on login node (systemd adapter, no Slurm)
