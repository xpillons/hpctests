---
name: 'bash'
description: 'When writing bash scripts'
applyTo: '**/*.sh' # when provided, instructions will be attached to files matching this pattern
---

Create log function to print messages with timestamp and log level (INFO, ERROR, etc.):

```bash
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message"
}
```

always fail on errors
```bash
set -euo pipefail
```

**Exception:** Do NOT use `set -euo pipefail` in scripts that source EESSI (`/cvmfs/software.eessi.io/.../init/bash`) or OpenFOAM (`$FOAM_BASH`). These environments use unbound variables and shell constructs that are incompatible with strict mode:
- `set -u` → `EESSI_VERSION_OVERRIDE: unbound variable`
- `set -e` → `pop_var_context: head of shell_variables not a function context` from `source $FOAM_BASH`

In such scripts, use `source $FOAM_BASH || true` and handle errors manually with explicit return code checks.
