#!/usr/bin/env bash
# Phase 3 check — prove on THIS machine that `gpu-profile amd` and `gpu-profile nvidia` are exact inverses,
# without touching the real system: copies the real config files into a temp root, applies amd then nvidia
# there, and diffs. Also prints both real --dry-run diffs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${GPU_PROFILE_HOME:-$HOME}"
T="$(mktemp -d)"; trap 'sudo rm -rf "$T"' EXIT
ROOT="$T/root"
copy() { for f in "$@"; do sudo test -e "$f" || continue; sudo mkdir -p "$ROOT$(dirname "$f")"; sudo cp -a "$f" "$ROOT$f"; done; }
copy /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d /etc/default/limine /etc/kernel/cmdline /etc/default/grub \
     /boot/loader/entries /boot/limine.conf /boot/limine/limine.conf /boot/EFI/limine/limine.conf \
     /etc/environment /etc/modules-load.d "$HOME_DIR/.config/hypr" "$HOME_DIR/.config/uwsm" "$HOME_DIR/.config/environment.d" \
     "$HOME_DIR/gpu-swap/gpu-profile.conf" /etc/systemd/system "$HOME_DIR/.config/systemd/user"
sudo chown -R "$(id -u):$(id -g)" "$T"
snap() { (cd "$ROOT" && find . -type f ! -path './root/*' ! -name gpu-profile.state | sort | while read -r f; do printf '== %s\n' "$f"; cat "$f"; done); }
export GPU_PROFILE_HOME="$HOME_DIR" GPU_PROFILE_USER="$(id -un)" GPU_SWAP_DIR="$HOME_DIR/gpu-swap" GPU_SWAP_BACKUP_ROOT=/root/gpu-swap-backup
ORIG="$(snap)"
echo "################ gpu-profile amd (sandbox copy of the real files)"
"$HERE/gpu-profile" amd --root "$ROOT"
AMD="$(snap)"
echo; echo "################ gpu-profile nvidia (sandbox)"
"$HERE/gpu-profile" nvidia --root "$ROOT"
NV="$(snap)"
echo
if [ "$ORIG" = "$NV" ]; then echo "RESULT: nvidia(amd(current)) == current, byte for byte — the profiles are exact inverses"; else echo "RESULT: MISMATCH after round trip:"; diff <(echo "$ORIG") <(echo "$NV") || true; exit 1; fi
"$HERE/gpu-profile" amd --root "$ROOT" >/dev/null; AMD2="$(snap)"
[ "$AMD" = "$AMD2" ] && echo "RESULT: amd is idempotent and amd(nvidia(amd(x))) == amd(x)" || { echo "RESULT: amd re-apply differs"; exit 1; }
echo; echo "################ real --dry-run (reads live files, writes nothing)"
"$HERE/gpu-profile" amd --dry-run
echo; "$HERE/gpu-profile" nvidia --dry-run
