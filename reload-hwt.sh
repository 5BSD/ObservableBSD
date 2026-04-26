#!/bin/sh
# Rebuild and reload patched hwt.ko and pt.ko kernel modules.
# Must be run as root (or via doas).

set -e

echo "Building hwt.ko..."
cd /usr/src/sys/modules/hwt && make clean && make

echo "Building pt.ko..."
cd /usr/src/sys/modules/pt && make clean && make

echo "Installing to /boot/GENERIC-HWT/..."
cp /usr/obj/usr/src/amd64.amd64/sys/modules/hwt/hwt.ko /boot/GENERIC-HWT/hwt.ko
cp /usr/obj/usr/src/amd64.amd64/sys/modules/pt/pt.ko /boot/GENERIC-HWT/pt.ko

echo "Unloading old modules (pt first, then hwt)..."
kldunload intel_pt 2>/dev/null || true
kldunload hwt 2>/dev/null || true

echo "Loading patched modules (hwt first, then pt)..."
kldload /boot/GENERIC-HWT/hwt.ko
kldload /boot/GENERIC-HWT/pt.ko

echo "Done. Loaded modules:"
kldstat | grep -E 'hwt\.ko|pt\.ko'
