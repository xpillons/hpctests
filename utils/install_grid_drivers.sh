#!/usr/bin/env bash
# Install Azure-redistributed NVIDIA GRID (vGPU) driver on NVads A10 v5 (Ubuntu 22.04 DSVM)
# Tested on Ubuntu 22.04 image microsoft-dsvm:ubuntu-hpc:2204:22.04.2024091701; uses the official Azure fwlink for the latest GRID driver.
# Docs: NVads A10 v5 requires GRID (14.1+); SB/vTPM must be disabled. Known issue with Azure 6.11 kernel. 
# Refs: https://learn.microsoft.com/azure/virtual-machines/linux/n-series-driver-setup
#       https://github.com/Azure/azhpc-extensions/blob/master/NvidiaGPU/resources.json

set -euo pipefail

### --- Config ---
DRIVER_FWLINK="https://go.microsoft.com/fwlink/?linkid=874272"  # Azure fwlink → latest GRID Linux .run (vGPU/R550)
WORKDIR="/tmp/azure-grid-driver"
LOGFILE="/var/log/azure-grid-driver-install.log"

### --- Helpers ---
log() { echo -e "[GRID] $*"; echo -e "[GRID] $*" >> "$LOGFILE"; }
die() { echo -e "[GRID][ERROR] $*" >&2; echo -e "[GRID][ERROR] $*" >> "$LOGFILE"; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "Run as root (sudo)."; }

### --- Start ---
need_root
mkdir -p "$WORKDIR"
touch "$LOGFILE"

log "Starting NVIDIA GRID (vGPU) driver install for Azure NVads A10 v5 on Ubuntu 22.04..."

# Basic environment info
KVER="$(uname -r)"
log "Kernel: $KVER"
UBU="$(. /etc/os-release && echo "$NAME $VERSION")"
log "OS: $UBU"

# Warn if Secure Boot enabled (cannot be changed from inside the VM)
if command -v mokutil >/dev/null 2>&1; then
  SB_STATE="$(mokutil --sb-state 2>/dev/null || true)"
  if echo "$SB_STATE" | grep -qi "enabled"; then
    die "Secure Boot is ENABLED. Disable Trusted Launch/Secure Boot on this VM and reboot, then rerun. (Required for GRID on Linux)"
  else
    log "Secure Boot state: ${SB_STATE:-unknown/unsupported}"
  fi
else
  log "mokutil not found; skipping Secure Boot check."
fi

# Blocker: known GRID + Azure kernel 6.11 issue
if echo "$KVER" | grep -qE '^6\.11\.'; then
  die "Detected Azure kernel 6.11.* which has known GRID install issues. Downgrade to Azure kernel 6.8 (e.g., linux-azure 6.8.x), reboot, and rerun."
fi

# Confirm we are on NVads A10 v5 hardware (best-effort)
if command -v lspci >/dev/null 2>&1; then
  if ! lspci | grep -qi 'nvidia'; then
    log "WARNING: No NVIDIA device detected by lspci. If this VM isn't an NVads A10 v5 size, the driver won't bind."
  else
    log "NVIDIA device present."
  fi
else
  apt-get update -y
  apt-get install -y pciutils
  if ! lspci | grep -qi 'nvidia'; then
    log "WARNING: No NVIDIA device detected by lspci (after installing pciutils)."
  fi
fi

# Prereqs and headers
log "Installing build prerequisites..."
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential dkms gcc make curl wget ca-certificates \
  linux-headers-$(uname -r)

# Blacklist Nouveau (open-source driver) and rebuild initramfs
if [ ! -f /etc/modprobe.d/blacklist-nouveau.conf ] || ! grep -q "blacklist nouveau" /etc/modprobe.d/blacklist-nouveau.conf; then
  log "Blacklisting Nouveau driver..."
  cat >/etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
  update-initramfs -u || true
  log "Nouveau driver blacklisted and initramfs updated."
else
  log "Nouveau driver already blacklisted, skipping..."
fi

# Fetch the latest Azure-redistributed GRID driver (vGPU) .run via fwlink
log "Downloading GRID driver from Azure fwlink..."
cd "$WORKDIR"
DRIVER_RUN="NVIDIA-Linux-x86_64-grid-azure.run"
# Follow redirects to get the actual file name
curl -fL "$DRIVER_FWLINK" -o "$DRIVER_RUN"

# Make executable
chmod +x "$DRIVER_RUN"

# Stop any display manager if running (rare on DSVM headless; safe no-op otherwise)
for svc in gdm3 lightdm sddm; do
  if systemctl is-active --quiet "$svc"; then
    log "Stopping display manager: $svc"
    systemctl stop "$svc" || true
  fi
done

# Remove any stale NVIDIA bits to avoid conflicts (safe if none)
log "Removing any existing NVIDIA packages to avoid conflicts..."
DEBIAN_FRONTEND=noninteractive apt-get purge -y 'nvidia-*' || true
#DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true

# Install the driver silently with DKMS
log "Running NVIDIA GRID installer (this can take several minutes)..."
# Notes:
#  --dkms: register kernel module with DKMS (default in recent installers)
#  --silent: noninteractive
#  --no-cc-version-check: avoid minor GCC mismatch failures
sh "./$DRIVER_RUN" --silent --dkms --no-cc-version-check || die "NVIDIA installer failed."

# Ensure persistence daemon is enabled (optional, but handy)
if systemctl list-unit-files | grep -q nvidia-persistenced.service; then
  systemctl enable nvidia-persistenced.service || true
  systemctl start nvidia-persistenced.service || true
fi

# Enable GRID service if provided (varies by version)
if systemctl list-unit-files | grep -q nvidia-gridd.service; then
  systemctl enable nvidia-gridd.service || true
  systemctl start nvidia-gridd.service || true
fi

log "Installation complete. A reboot is recommended to load the new kernel modules."
#log "Rebooting in 5 seconds... (Ctrl+C to cancel)"
#sleep 5
#reboot