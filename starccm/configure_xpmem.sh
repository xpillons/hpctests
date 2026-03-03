#!/bin/bash

# 1. Load the kernel module
modprobe xpmem

# 2. Install the userspace library (from DOCA packages already on disk)
dpkg -i /usr/share/doca-host-*/repo/pool/libxpmem0_*.deb \
             /usr/share/doca-host-*/repo/pool/libxpmem-dev_*.deb

# 3. Set device permissions for non-root users
chmod 666 /dev/xpmem


# 4. Register HPCX UCX as system default (required for -xsystemucx to find xpmem)
#    The OS UCX was built --without-xpmem; HPCX UCX has xpmem support.
#    Both are v1.20.0 (same ABI), so this is safe.
echo '/opt/hpcx-v2.25.1-gcc-doca_ofed-ubuntu24.04-cuda13-x86_64/ucx/lib' | tee /etc/ld.so.conf.d/hpcx-ucx.conf
echo '/opt/hpcx-v2.25.1-gcc-doca_ofed-ubuntu24.04-cuda13-x86_64/ucx/lib/ucx' | tee -a /etc/ld.so.conf.d/hpcx-ucx.conf
ldconfig


# 5. The libxpmem0 package is already installed (dpkg persists across reboots)
#    — but if nodes are reimaged, add to the image build or cloud-init
echo "xpmem" | tee /etc/modules-load.d/xpmem.conf

# 6. Persistent device permissions via udev rule
echo 'KERNEL=="xpmem", MODE="0666"' | tee /etc/udev/rules.d/90-xpmem.rules
udevadm control --reload-rules
udevadm trigger