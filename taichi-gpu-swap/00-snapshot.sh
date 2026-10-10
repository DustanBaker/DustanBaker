#!/usr/bin/env bash
# Phase 0.1 — take a "pre-gpu-swap" snapshot (snapper via Omarchy) or, failing that,
# create /root/gpu-swap-backup/<timestamp>/ and copy every file the later phases may touch.
set -euo pipefail
TS="$(date +%Y%m%d-%H%M%S)"
HOME_DIR="${GPU_PROFILE_HOME:-$HOME}"
echo "==> Phase 0.1: snapshot"
if command -v omarchy-snapshot >/dev/null 2>&1; then
  echo "    Omarchy snapshot tooling found; creating snapshot 'pre-gpu-swap'"
  sudo omarchy-snapshot create "pre-gpu-swap" 2>&1 | sed 's/^/    /' || sudo omarchy-snapshot create 2>&1 | sed 's/^/    /'
  sudo snapper -c root list 2>/dev/null | tail -n 5 | sed 's/^/    /' || true
elif command -v snapper >/dev/null 2>&1 && sudo snapper list-configs 2>/dev/null | grep -q root; then
  echo "    snapper found; creating snapshot 'pre-gpu-swap' on config root"
  sudo snapper -c root create --description "pre-gpu-swap" --cleanup-algorithm number
  sudo snapper -c root list | tail -n 5 | sed 's/^/    /'
else
  echo "    no snapper/btrfs snapshots; falling back to a file backup"
fi

# Always also take the plain file backup: it is cheap and covers /home, which snapper's root config does not.
B="/root/gpu-swap-backup/$TS-pre-gpu-swap"
echo "==> file backup -> $B"
sudo mkdir -p "$B"
backup() { for f in "$@"; do [ -e "$f" ] || continue; sudo mkdir -p "$B$(dirname "$f")"; sudo cp -a "$f" "$B$f"; echo "    $f"; done; }
backup /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d /etc/mkinitcpio.d /etc/default/limine /etc/kernel/cmdline \
       /etc/default/grub /etc/modprobe.d /etc/modules-load.d /etc/environment /etc/udev/rules.d \
       /etc/systemd/system "$HOME_DIR/.config/hypr" "$HOME_DIR/.config/uwsm" "$HOME_DIR/.config/environment.d" \
       "$HOME_DIR/.config/systemd/user" "$HOME_DIR/.bashrc" "$HOME_DIR/.zshrc" "$HOME_DIR/.profile" "$HOME_DIR/.bash_profile"
for lc in /boot/limine.conf /boot/limine/limine.conf /boot/EFI/limine/limine.conf /boot/loader; do sudo test -e "$lc" && backup "$lc"; done
sudo sh -c "cat /proc/cmdline > '$B/proc-cmdline.txt'; pacman -Q > '$B/pacman-Q.txt'"
echo "    done. Restore any file with: sudo cp -a $B/<path> /<path>"
