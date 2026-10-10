#!/usr/bin/env bash
# Phase 0.2 — record the current (NVIDIA) state to ~/gpu-swap/inventory-nvidia.md
set -uo pipefail
GPU_SWAP_DIR="${GPU_SWAP_DIR:-$HOME/gpu-swap}"; mkdir -p "$GPU_SWAP_DIR"
OUT="$GPU_SWAP_DIR/inventory-nvidia.md"
sec() { printf '\n## %s\n\n' "$1" >> "$OUT"; }
run() { printf '```\n$ %s\n' "$*" >> "$OUT"; { eval "$@" 2>&1 || true; } | head -n "${LINES_MAX:-200}" >> "$OUT"; printf '```\n' >> "$OUT"; }
printf '# Taichi Station — inventory before the GPU swap (NVIDIA profile)\n\nGenerated: %s on %s\n' "$(date -Is)" "$(hostname)" > "$OUT"

sec "Kernel, boot and initramfs tooling"
run uname -a
run pacman -Q linux linux-lts linux-zen linux-cachyos linux-firmware linux-firmware-amdgpu linux-firmware-nvidia 2>/dev/null
run cat /proc/cmdline
run 'ls -l /boot /boot/limine* /boot/EFI 2>/dev/null; sudo ls -l /boot/limine* /boot/EFI/limine 2>/dev/null'
run 'for f in /etc/default/limine /etc/kernel/cmdline /etc/default/grub; do [ -f "$f" ] && { echo "--- $f"; cat "$f"; }; done; sudo sh -c "for f in /boot/limine.conf /boot/limine/limine.conf /boot/EFI/limine/limine.conf; do [ -f \$f ] && { echo --- \$f; cat \$f; }; done; ls /boot/loader/entries 2>/dev/null && cat /boot/loader/entries/*.conf"'
run 'pacman -Q limine limine-mkinitcpio-hook limine-snapper-sync snapper systemd-ukify grub 2>/dev/null; command -v limine-update limine-mkinitcpio omarchy-snapshot bootctl'
run 'grep -vE "^\s*(#|$)" /etc/mkinitcpio.conf; ls /etc/mkinitcpio.conf.d 2>/dev/null && cat /etc/mkinitcpio.conf.d/*.conf'
run 'grep -vE "^\s*(#|$)" /etc/mkinitcpio.d/*.preset'

sec "GPUs"
run 'lspci -Dnn -d ::0300; lspci -Dnn -d ::0302'
run 'lspci -k -d ::0300; lspci -k -d ::0302'
run 'ls -l /dev/dri /dev/dri/by-path'
run nvidia-smi
run 'nvidia-smi --query-gpu=name,driver_version,pci.bus_id,memory.total --format=csv'

sec "NVIDIA / CUDA packages installed"
run 'pacman -Qs "nvidia|cuda|cudnn|nvml|nccl|tensorrt" | grep -E "^local/"'
run 'pacman -Qm | grep -iE "nvidia|cuda"   # foreign (AUR) packages'
run 'systemctl list-unit-files | grep -iE "nvidia|llama|ollama|hermes|qwen"'
run 'systemctl --user list-unit-files 2>/dev/null | grep -iE "nvidia|llama|ollama|hermes|qwen"'

sec "Hyprland, Mesa, Vulkan"
run 'Hyprland --version 2>/dev/null | head -n 3; hyprctl version 2>/dev/null | head -n 3'
run 'pacman -Q hyprland aquamarine mesa lib32-mesa vulkan-icd-loader lib32-vulkan-icd-loader vulkan-radeon lib32-vulkan-radeon vulkan-tools vulkan-headers glslang shaderc libva-mesa-driver nvidia-utils lib32-nvidia-utils libva-nvidia-driver egl-wayland 2>/dev/null'
run 'ls /usr/share/vulkan/icd.d/ 2>/dev/null'
run 'vulkaninfo --summary 2>/dev/null | sed -n "/Devices:/,\$p"'
run 'pacman -Q rocm-hip-sdk rocm-hip-runtime rocminfo rocm-smi-lib hipblas rocblas amdgpu_top 2>/dev/null'

sec "llama.cpp / PyTorch / CUDA toolchain currently installed"
run 'command -v llama-server llama-cli llama-bench nvcc hipcc; nvcc --version 2>/dev/null | tail -n 2'
run 'pacman -Q cuda cudnn llama.cpp llama.cpp-cuda ollama ollama-cuda python-pytorch python-pytorch-cuda 2>/dev/null'
run 'find "$HOME" /opt /srv -maxdepth 4 \( -name "llama-server" -o -name "llama.cpp" -o -name "build-cuda" -o -name "build" \) -not -path "*/node_modules/*" -not -path "*/.cache/*" 2>/dev/null | head -n 40'
run 'for d in $(find "$HOME" /opt /srv -maxdepth 4 -name llama.cpp -type d 2>/dev/null); do echo "--- $d"; git -C "$d" rev-parse HEAD 2>/dev/null; git -C "$d" log -1 --format="%h %cd %s" 2>/dev/null; ls "$d" | grep -E "^build" ; done'
run 'find "$HOME" /opt /srv -maxdepth 5 -name "pyvenv.cfg" 2>/dev/null | while read -r v; do d=$(dirname "$v"); echo "--- venv $d ($(grep version "$v"))"; "$d/bin/python" -c "import torch;print(\"torch\",torch.__version__,\"cuda\",torch.version.cuda,\"hip\",getattr(torch.version,\"hip\",None))" 2>/dev/null; "$d/bin/pip" list 2>/dev/null | grep -iE "^(torch|llama|vllm|transformers|huggingface|hf)"; done'
run 'ls -d "$HOME"/.conda/envs/* "$HOME"/miniconda*/envs/* "$HOME"/.local/share/uv/python/* 2>/dev/null'
run 'ps -eo pid,user,etime,args | grep -iE "llama-server|ollama|vllm|hermes|qwen" | grep -v grep'
run 'ss -ltnp 2>/dev/null | grep -iE "llama|ollama|python|node" '

sec "Disk"
run 'df -h / /home /boot "$HOME/models" 2>/dev/null'
run 'ls -la "$HOME/models" 2>/dev/null | head -n 40'

echo "wrote $OUT"
