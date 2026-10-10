#!/usr/bin/env bash
# Copy this folder to ~/gpu-swap on Taichi Station (idempotent; keeps any generated files already there).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"; DST="${GPU_SWAP_DIR:-$HOME/gpu-swap}"
mkdir -p "$DST"
cp -a "$SRC"/{00-snapshot.sh,01-inventory.sh,02-find-touchpoints.sh,03-install-amd-stack.sh,04-download-models.sh,gpu-profile,verify-inverse.sh,test-flash-next.sh,RUNBOOK.md,README.md,gpu-profile.conf.example} "$DST/"
cp -a "$SRC/tests" "$DST/"
chmod +x "$DST"/*.sh "$DST/gpu-profile" "$DST/tests/run.sh"
echo "installed to $DST — next: $DST/00-snapshot.sh (see $DST/RUNBOOK.md)"
