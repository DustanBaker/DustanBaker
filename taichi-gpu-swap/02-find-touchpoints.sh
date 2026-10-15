#!/usr/bin/env bash
# Phase 1 — find everything NVIDIA-specific that Omarchy or the user added.
# Writes ~/gpu-swap/nvidia-touchpoints.md (every hit, file:line) and
#        ~/gpu-swap/gpu-profile.conf (exact values gpu-profile will restore for `nvidia`).
# Search, don't assume: this greps the real files.
set -uo pipefail
GPU_SWAP_DIR="${GPU_SWAP_DIR:-$HOME/gpu-swap}"; mkdir -p "$GPU_SWAP_DIR"
OUT="$GPU_SWAP_DIR/nvidia-touchpoints.md"
CONF="$GPU_SWAP_DIR/gpu-profile.conf"
RE='nvidia|NVD_BACKEND|GBM_BACKEND|__GLX_VENDOR_LIBRARY_NAME|__GL_|no_hardware_cursors|WLR_NO_HARDWARE_CURSORS|AQ_DRM_DEVICES|WLR_DRM_DEVICES|LIBVA_DRIVER_NAME|cuda'

printf '# NVIDIA touchpoints on %s\n\nGenerated: %s. Pattern: `%s` (case-insensitive).\n' "$(hostname)" "$(date -Is)" "$RE" > "$OUT"
hits_total=0
scan() {  # scan "<title>" path...
  local title="$1"; shift
  printf '\n## %s\n\n' "$title" >> "$OUT"
  local any=0 p
  for p in "$@"; do
    [ -e "$p" ] || continue
    # shellcheck disable=SC2086
    sudo grep -rinE --with-filename "$RE" $p 2>/dev/null | grep -vE '\.(png|jpg|svg|gz|zst|img|efi|o|so(\.[0-9]+)*)$' | head -n 400 | while IFS= read -r line; do
      printf -- '- `%s`\n' "$line" >> "$OUT"; any=1
    done
    [ "$(sudo grep -rilE "$RE" $p 2>/dev/null | wc -l)" -gt 0 ] && any=1
  done
  [ $any = 0 ] && printf -- '- (no hits)\n' >> "$OUT"
}

scan "initramfs: /etc/mkinitcpio.conf, /etc/mkinitcpio.conf.d, presets" /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d /etc/mkinitcpio.d
scan "modprobe / modules-load" /etc/modprobe.d /etc/modules-load.d /usr/lib/modprobe.d /usr/lib/modules-load.d
scan "bootloader and kernel cmdline" /etc/default/limine /etc/kernel/cmdline /etc/default/grub /boot/limine.conf /boot/limine/limine.conf /boot/EFI/limine/limine.conf /boot/loader/entries /etc/limine-entry-tool.conf /etc/limine-snapper-sync.conf
printf '\n`/proc/cmdline` now: `%s`\n' "$(cat /proc/cmdline)" >> "$OUT"
scan "udev rules" /etc/udev/rules.d /usr/lib/udev/rules.d/60-nvidia.rules /usr/lib/udev/rules.d/70-nvidia.rules /usr/lib/udev/rules.d/71-nvidia.rules
scan "system environment" /etc/environment /etc/environment.d /etc/profile.d
scan "Hyprland config (~/.config/hypr)" "$HOME/.config/hypr"
scan "uwsm / session launch" "$HOME/.config/uwsm" "$HOME/.config/hypr/hyprland.conf" /usr/share/wayland-sessions /usr/local/share/wayland-sessions
scan "shell rc / environment.d" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zprofile" "$HOME/.config/environment.d" "$HOME/.config/fish/config.fish"
scan "systemd units (system)" /etc/systemd/system /etc/systemd/system.conf.d /usr/lib/systemd/system/nvidia-persistenced.service /usr/lib/systemd/system/nvidia-powerd.service /usr/lib/systemd/system/nvidia-suspend.service /usr/lib/systemd/system/nvidia-hibernate.service /usr/lib/systemd/system/nvidia-resume.service
scan "systemd units (user)" "$HOME/.config/systemd/user"
scan "Omarchy scripts (~/.local/share/omarchy)" "$HOME/.local/share/omarchy"
scan "Omarchy scripts (/usr/share/omarchy, /usr/local/share/omarchy)" /usr/share/omarchy /usr/local/share/omarchy
scan "pacman hooks" /etc/pacman.d/hooks /usr/share/libalpm/hooks
scan "Xorg / misc" /etc/X11 /etc/sddm.conf.d /etc/greetd

printf '\n## Enabled NVIDIA services\n\n```\n' >> "$OUT"
{ systemctl list-unit-files 2>/dev/null | grep -iE 'nvidia'; systemctl --user list-unit-files 2>/dev/null | grep -iE 'nvidia'; } >> "$OUT"
printf '```\n\n## Services that run llama-server / inference (candidates for LLAMA_UNIT)\n\n```\n' >> "$OUT"
{ systemctl list-units --all --type=service --no-legend 2>/dev/null | grep -iE 'llama|ollama|hermes|qwen|vllm|lmstudio|inference';
  systemctl --user list-units --all --type=service --no-legend 2>/dev/null | grep -iE 'llama|ollama|hermes|qwen|vllm|inference'; } >> "$OUT"
printf '```\n' >> "$OUT"
for u in $(systemctl list-units --all --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -iE 'llama|ollama' ) ; do
  printf '\n`systemctl cat %s`:\n\n```\n' "$u" >> "$OUT"; systemctl cat "$u" 2>/dev/null >> "$OUT"; printf '```\n' >> "$OUT"
done
for u in $(systemctl --user list-units --all --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -iE 'llama|ollama' ) ; do
  printf '\n`systemctl --user cat %s`:\n\n```\n' "$u" >> "$OUT"; systemctl --user cat "$u" 2>/dev/null >> "$OUT"; printf '```\n' >> "$OUT"
done

# ------------------------------------------------------------------ build gpu-profile.conf
mk_file=/etc/mkinitcpio.conf
for f in /etc/mkinitcpio.conf.d/*.conf; do [ -f "$f" ] && grep -Eq '^\s*MODULES=' "$f" && mk_file="$f"; done
modules="$(grep -E '^\s*MODULES=' "$mk_file" | tail -n1 | sed -E 's/^\s*MODULES=\((.*)\).*$/\1/; s/"//g' | xargs)"
cmd_kind=""; cmd_file=""; cmd_src=""
if [ -f /etc/default/limine ] && grep -Eq '^\s*KERNEL_CMDLINE\[' /etc/default/limine; then cmd_kind=limine-default; cmd_file=/etc/default/limine; cmd_src="$(grep -E '^\s*KERNEL_CMDLINE\[' /etc/default/limine | sed -E 's/^[^=]*=//; s/^["'"'"']//; s/["'"'"']$//' | tr '\n' ' ')"
elif [ -f /etc/kernel/cmdline ]; then cmd_kind=kernel-cmdline; cmd_file=/etc/kernel/cmdline; cmd_src="$(cat /etc/kernel/cmdline)"
elif sudo ls /boot/loader/entries/*.conf >/dev/null 2>&1; then cmd_kind=sd-boot; cmd_file=/boot/loader/entries; cmd_src="$(sudo grep -hE '^\s*options' /boot/loader/entries/*.conf | head -n1 | sed -E 's/^\s*options\s+//')"
elif [ -f /etc/default/grub ]; then cmd_kind=grub; cmd_file=/etc/default/grub; cmd_src="$(grep -E '^\s*GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | sed -E 's/^[^=]*=//; s/"//g')"
else for lc in /boot/limine.conf /boot/limine/limine.conf /boot/EFI/limine/limine.conf; do sudo test -f "$lc" && sudo grep -Eqi '^\s*cmdline:' "$lc" && { cmd_kind=limine-conf; cmd_file="$lc"; cmd_src="$(sudo grep -hEi '^\s*cmdline:' "$lc" | head -n1 | sed -E 's/^\s*cmdline:\s*//I')"; break; }; done; fi
[ -z "$cmd_src" ] && cmd_src="$(cat /proc/cmdline)"
nv_params=(); anchor=""; prev=""
for t in $cmd_src; do if [[ "$t" =~ ^nvidia[._-] ]]; then [ ${#nv_params[@]} -eq 0 ] && anchor="$prev"; nv_params+=("$t"); fi; prev="$t"; done
toggle=()
for f in "$HOME/.config/hypr/envs.conf" "$HOME/.config/hypr/hyprland.conf" "$HOME"/.config/hypr/*.conf "$HOME/.config/uwsm/env" "$HOME/.config/uwsm/env-hyprland" /etc/environment /etc/modules-load.d/*.conf "$HOME"/.config/environment.d/*.conf; do
  [ -f "$f" ] || continue
  grep -Eq '^\s*[^#].*(nvidia|NVD_BACKEND|GBM_BACKEND|__GLX_VENDOR_LIBRARY_NAME|__GL_GSYNC_ALLOWED|__GL_VRR_ALLOWED|__NV_PRIME_RENDER_OFFLOAD|__VK_LAYER_NV_optimus|WLR_NO_HARDWARE_CURSORS|no_hardware_cursors)' "$f" || continue
  case " ${toggle[*]:-} " in *" $f "*) ;; *) toggle+=("$f") ;; esac
done
dgpu=""; igpu=""
while read -r line; do addr="${line%% *}"; id="$(printf '%s' "$line" | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' | tail -n1 | tr -d '[]')"
  case "$id" in 10de:*) [ -z "$dgpu" ] && dgpu="$addr";; 1002:164e|1002:13c0|1002:1900) [ -z "$igpu" ] && igpu="$addr";; 1002:*) [ -z "$dgpu" ] && dgpu="$addr";; esac
done < <(lspci -Dnn -d ::0300 2>/dev/null; lspci -Dnn -d ::0302 2>/dev/null)
llama_unit="$(systemctl list-units --all --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -iE '^llama' | head -n1)"
llama_scope=system
[ -z "$llama_unit" ] && { llama_unit="$(systemctl --user list-units --all --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -iE '^llama' | head -n1)"; [ -n "$llama_unit" ] && llama_scope=user; }
llama_exec=""
if [ -n "$llama_unit" ]; then
  if [ "$llama_scope" = user ]; then llama_exec="$(systemctl --user show -p ExecStart --value "$llama_unit" 2>/dev/null | sed -E 's/^\{ path=[^;]*; argv\[\]=//; s/ ; ignore_errors.*$//')"
  else llama_exec="$(systemctl show -p ExecStart --value "$llama_unit" 2>/dev/null | sed -E 's/^\{ path=[^;]*; argv\[\]=//; s/ ; ignore_errors.*$//')"; fi
fi
amd_exec=""
if [ -n "$llama_exec" ]; then amd_exec="$(printf '%s' "$llama_exec" | sed -E "s#^[^ ]*llama-server#$HOME/gpu-swap/llama.cpp/build-vulkan/bin/llama-server#")"; fi

[ -f "$CONF" ] && cp -a "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)"
cat > "$CONF" <<C
# gpu-profile.conf — generated by 02-find-touchpoints.sh on $(date -Is). Edit freely; sourced by gpu-profile.
# Exact MODULES=() line of the NVIDIA profile (what is in $mk_file today):
NVIDIA_MKINITCPIO_MODULES=($modules)
# The AMD profile uses the same list minus nvidia* plus amdgpu (leave empty for auto):
AMD_MKINITCPIO_MODULES=()
# Kernel cmdline: where it lives, the nvidia tokens to remove/restore, and the token they follow.
CMDLINE_KIND="$cmd_kind"
CMDLINE_FILE="$cmd_file"
NVIDIA_CMDLINE_PARAMS=(${nv_params[*]:-})
NVIDIA_CMDLINE_ANCHOR="$anchor"
AMD_CMDLINE_PARAMS=()
# Files whose NVIDIA lines are commented out (marker prefix) for amd and restored for nvidia:
TOGGLE_FILES=(${toggle[*]:-})
# File that receives the commented AQ_DRM_DEVICES block for amd:
HYPR_ENV_FILE="$HOME/.config/hypr/envs.conf"
# PCI addresses (dGPU slot keeps its address after the swap; iGPU = Raphael 1002:164e):
DGPU_PCI_ADDR="$dgpu"
IGPU_PCI_ADDR="$igpu"
# Optional: llama-server unit to repoint at the Vulkan build (same host/port/model, only the binary changes).
# Leave LLAMA_UNIT empty to skip. Check LLAMA_EXEC_AMD before applying!
LLAMA_UNIT="$llama_unit"
LLAMA_UNIT_SCOPE="$llama_scope"
LLAMA_EXEC_NVIDIA="$llama_exec"
LLAMA_EXEC_AMD="$amd_exec"
C
printf '\n## gpu-profile.conf written\n\n```\n%s\n```\n' "$(cat "$CONF")" >> "$OUT"
echo "wrote $OUT and $CONF"
echo "nvidia cmdline tokens: ${nv_params[*]:-(none found)}  | toggle files: ${toggle[*]:-(none)} | dGPU $dgpu iGPU ${igpu:-not visible (BIOS may hide it while a dGPU is primary)}"
