#!/usr/bin/env bash
# Fixture test for gpu-profile: builds a fake Omarchy/NVIDIA root, applies amd then nvidia,
# and checks (a) nvidia(amd(x)) == x byte-for-byte, (b) amd and nvidia are idempotent,
# (c) amd(nvidia(amd(x))) == amd(x). Runs without root and touches nothing outside a temp dir.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GP="$HERE/../gpu-profile"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/root"; export GPU_PROFILE_HOME=/home/dusty GPU_PROFILE_USER=dusty GPU_SWAP_DIR=/home/dusty/gpu-swap GPU_SWAP_BACKUP_ROOT=/root/gpu-swap-backup

mk_fixture() {  # mk_fixture <variant: limine|uki|sdboot>
  rm -rf "$ROOT"; mkdir -p "$ROOT/etc/mkinitcpio.conf.d" "$ROOT/etc/default" "$ROOT/etc/kernel" "$ROOT/etc/modules-load.d" "$ROOT/home/dusty/.config/hypr" "$ROOT/home/dusty/gpu-swap" "$ROOT/boot/loader/entries" "$ROOT/etc/systemd/system"
  cat > "$ROOT/etc/mkinitcpio.conf" <<'F'
# vim:set ft=sh
MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
BINARIES=()
FILES=()
HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)
F
  case "$1" in
    limine)
      cat > "$ROOT/etc/default/limine" <<'F'
# Omarchy limine defaults
TARGET_OS_NAME="Omarchy"
KERNEL_CMDLINE[default]="quiet splash rootflags=subvol=@ rd.luks.name=abcd=root root=/dev/mapper/root nvidia_drm.modeset=1 nvidia-drm.fbdev=1 zswap.enabled=0"
ENABLE_LIMINE_FALLBACK=yes
F
      ;;
    uki)
      printf 'quiet splash nvidia_drm.modeset=1 root=/dev/nvme0n1p2 rw\n' > "$ROOT/etc/kernel/cmdline" 2>/dev/null || { mkdir -p "$ROOT/etc/kernel"; printf 'quiet splash nvidia_drm.modeset=1 root=/dev/nvme0n1p2 rw\n' > "$ROOT/etc/kernel/cmdline"; }
      ;;
    sdboot)
      cat > "$ROOT/boot/loader/entries/omarchy.conf" <<'F'
title   Omarchy
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=/dev/nvme0n1p2 rw quiet nvidia_drm.modeset=1 nvidia.NVreg_PreserveVideoMemoryAllocations=1
F
      ;;
  esac
  cat > "$ROOT/home/dusty/.config/hypr/envs.conf" <<'F'
# Extra env variables
# Note: You must relaunch Hyprland after changing envs (use Super+Esc, then Relaunch)

# Force apps to use Wayland
env = GDK_BACKEND,wayland
env = QT_QPA_PLATFORM,wayland
env = ELECTRON_OZONE_PLATFORM_HINT,wayland

# NVIDIA (added by Omarchy nvidia setup)
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = NVD_BACKEND,direct
# env = GBM_BACKEND,nvidia-drm   (already commented by the user)
F
  cat > "$ROOT/home/dusty/.config/hypr/hyprland.conf" <<'F'
source = ~/.local/share/omarchy/default/hypr/*.conf
cursor {
    no_hardware_cursors = true
}
F
  printf 'nvidia\nnvidia_uvm\n' > "$ROOT/etc/modules-load.d/nvidia.conf"
  printf 'LLAMA_UNIT=llama-server.service\nLLAMA_UNIT_SCOPE=system\nLLAMA_EXEC_AMD="/home/dusty/gpu-swap/llama.cpp/build-vulkan/bin/llama-server --host 127.0.0.1 --port 8080 -m /home/dusty/models/x.gguf -ngl 99"\n' > "$ROOT/home/dusty/gpu-swap/gpu-profile.conf"
}
snap() { (cd "$ROOT" && find . -type f ! -path './root/*' ! -name gpu-profile.state | sort | while read -r f; do printf '== %s\n' "$f"; cat "$f"; done); }

fail=0
for variant in limine uki sdboot; do
  mk_fixture "$variant"
  ORIG="$(snap)"
  "$GP" amd    --root "$ROOT" >"$T/amd1.log" 2>&1 || { echo "amd failed ($variant)"; cat "$T/amd1.log"; exit 1; }
  AMD1="$(snap)"
  "$GP" amd    --root "$ROOT" >"$T/amd2.log" 2>&1; AMD2="$(snap)"
  [ "$AMD1" = "$AMD2" ] && echo "[$variant] amd idempotent: OK" || { echo "[$variant] amd NOT idempotent"; diff <(echo "$AMD1") <(echo "$AMD2"); fail=1; }
  grep -q "no file changes needed" "$T/amd2.log" && echo "[$variant] amd second run reports no changes: OK" || { echo "[$variant] amd second run still reports changes"; fail=1; }
  "$GP" nvidia --root "$ROOT" >"$T/nv1.log" 2>&1; NV1="$(snap)"
  [ "$ORIG" = "$NV1" ] && echo "[$variant] nvidia(amd(x)) == x byte-for-byte: OK" || { echo "[$variant] round trip differs:"; diff <(echo "$ORIG") <(echo "$NV1"); fail=1; }
  "$GP" nvidia --root "$ROOT" >"$T/nv2.log" 2>&1; grep -q "no file changes needed" "$T/nv2.log" && echo "[$variant] nvidia idempotent on original: OK" || { echo "[$variant] nvidia not idempotent"; fail=1; }
  "$GP" amd    --root "$ROOT" >/dev/null 2>&1; AMD3="$(snap)"
  [ "$AMD1" = "$AMD3" ] && echo "[$variant] amd(nvidia(amd(x))) == amd(x): OK" || { echo "[$variant] amd re-apply differs"; fail=1; }
  "$GP" nvidia --root "$ROOT" --dry-run >"$T/dry.log" 2>&1; AFTER="$(snap)"
  [ "$AMD3" = "$AFTER" ] && echo "[$variant] --dry-run writes nothing: OK" || { echo "[$variant] dry-run WROTE files"; fail=1; }
  [ ! -e "$ROOT/root/gpu-swap-backup" ] || ls "$ROOT/root/gpu-swap-backup" | grep -q . && echo "[$variant] backups created: $(ls "$ROOT/root/gpu-swap-backup" | wc -l) dirs"
done
if [ "${SHOW:-0}" = 1 ]; then mk_fixture limine; "$GP" amd --root "$ROOT" --dry-run; fi
[ $fail = 0 ] && echo "ALL TESTS PASSED" || { echo "TESTS FAILED"; exit 1; }
