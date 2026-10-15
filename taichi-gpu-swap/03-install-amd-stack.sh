#!/usr/bin/env bash
# Phase 2 — install the AMD stack ALONGSIDE the NVIDIA one (nothing removed) and build
# llama.cpp twice (Vulkan, ROCm) in ~/gpu-swap/llama.cpp without touching the existing CUDA build.
# Records everything to ~/gpu-swap/amd-stack.md. Re-runnable.
set -uo pipefail
GPU_SWAP_DIR="${GPU_SWAP_DIR:-$HOME/gpu-swap}"; mkdir -p "$GPU_SWAP_DIR"
OUT="$GPU_SWAP_DIR/amd-stack.md"
LLAMA_DIR="${LLAMA_DIR:-$GPU_SWAP_DIR/llama.cpp}"
LLAMA_REF="${LLAMA_REF:-master}"          # upstream HEAD by default; pin a tag/commit with LLAMA_REF=b1234
GPU_TARGET="${GPU_TARGET:-gfx1201}"
JOBS="${JOBS:-$(nproc)}"
sec() { printf '\n## %s\n\n' "$1" | tee -a "$OUT"; }
rec() { printf '```\n$ %s\n' "$*" >> "$OUT"; { eval "$@" 2>&1 || true; } | tee -a "$OUT"; printf '```\n' >> "$OUT"; }
printf '# AMD stack install log — %s\n' "$(date -Is)" > "$OUT"

sec "2.1 Kernel / firmware (RDNA4 Navi 48 = gfx1201)"
echo "  amdgpu gained Navi 48 (gfx12) support in kernel 6.11; the RX 9070 launch guidance was >= 6.13/6.14 for a clean"
echo "  experience, and navi48 firmware shipped in linux-firmware 20250211. Arch has split the firmware into"
echo "  linux-firmware-amdgpu since 2025, so check that package too."
# Full sync+upgrade (never -Sy alone: a partial upgrade on Arch can break the kernel/module match).
# Omarchy's pacman hook refuses a direct `pacman -Syu` (00-omarchy-update-guard.hook); its own updater does the
# snapshot, keyring, upgrade, migrations and boot-file verification, and with -y never reboots by itself.
if [ -x /usr/share/omarchy/bin/omarchy-update ] && command -v omarchy >/dev/null 2>&1; then
  echo "  Omarchy box: running 'omarchy update -y' instead of a direct pacman -Syu (log: $GPU_SWAP_DIR/omarchy-update.log)"
  omarchy update -y >"$GPU_SWAP_DIR/omarchy-update.log" 2>&1 || echo "  WARNING: omarchy update exited $? — read $GPU_SWAP_DIR/omarchy-update.log" | tee -a "$OUT"
  tail -n 5 "$GPU_SWAP_DIR/omarchy-update.log"
else
  sudo pacman -Syu --needed --noconfirm 2>&1 | tail -n 3
fi
sudo pacman -S --needed --noconfirm linux-firmware 2>&1 | tail -n 1
pacman -Si linux-firmware-amdgpu >/dev/null 2>&1 && sudo pacman -S --needed --noconfirm linux-firmware-amdgpu 2>&1 | tail -n 1
rec 'pacman -Q linux linux-firmware linux-firmware-amdgpu 2>/dev/null; uname -r'
rec 'ls /usr/lib/firmware/amdgpu/ | grep -E "gc_12_0_1|psp_14_0_3|sdma_7_0_1|dcn_4|vcn_5_0|smu_14_0_3" | head -n 20; ls /usr/lib/firmware/amdgpu/*.zst 2>/dev/null | grep -cE "gc_12_0_1|navi48"'
kv="$(uname -r | cut -d. -f1-2)"; if [ "$(printf '%s\n6.13\n' "$kv" | sort -V | head -n1)" = "6.13" ]; then echo "  kernel $kv >= 6.13: OK" | tee -a "$OUT"; else echo "  WARNING: running kernel $kv < 6.13 — update before the swap" | tee -a "$OUT"; fi

sec "2.2 Mesa / RADV / Vulkan + llama.cpp Vulkan build deps"
PKGS=(mesa vulkan-radeon vulkan-icd-loader vulkan-tools vulkan-headers glslang shaderc libva-mesa-driver mesa-utils libva-utils cmake ninja git curl)
if grep -Eq '^\[multilib\]' /etc/pacman.conf; then PKGS+=(lib32-mesa lib32-vulkan-radeon lib32-vulkan-icd-loader); echo "  multilib enabled: adding lib32 variants"; fi
sudo pacman -S --needed --noconfirm "${PKGS[@]}" 2>&1 | tail -n 5
rec "pacman -Q ${PKGS[*]}"
rec 'ls /usr/share/vulkan/icd.d/'

sec "2.3 ROCm from the Arch repos (+ rocminfo, rocm-smi-lib, amdgpu_top)"
# rocm-hip-sdk pulls hip runtime, hipcc (in rocm-llvm/hip-runtime-amd), rocblas, hipblas, rocsolver etc.
sudo pacman -S --needed --noconfirm rocm-hip-sdk rocm-hip-runtime rocminfo rocm-smi-lib rocm-device-libs hipblas rocblas hipblaslt 2>&1 | tail -n 5
# rocwmma enables -DGGML_HIP_ROCWMMA_FATTN; optional
sudo pacman -S --needed --noconfirm rocwmma 2>/dev/null | tail -n 1 || true
rec 'pacman -Q rocm-hip-sdk rocm-hip-runtime rocm-core rocminfo rocm-smi-lib rocblas hipblas hipblaslt rocwmma rocm-llvm 2>/dev/null; cat /opt/rocm/.info/version 2>/dev/null'
rec 'echo "rocBLAS tensile libraries for $GPU_TARGET:"; ls /opt/rocm/lib/rocblas/library 2>/dev/null | grep -c gfx1201; ls /opt/rocm/lib/rocblas/library 2>/dev/null | grep gfx1201 | head -n 5'
if ls /opt/rocm/lib/rocblas/library 2>/dev/null | grep -q gfx1201; then echo "  rocBLAS has gfx1201 kernels: OK" | tee -a "$OUT"; else echo "  WARNING: no gfx1201 rocBLAS libraries — the ROCm build will fall back to generic/slow paths or fail at runtime. Vulkan is the safe backend." | tee -a "$OUT"; fi
rec 'ls /opt/rocm/lib/hipblaslt/library 2>/dev/null | grep -c gfx1201'
rec 'id -nG | tr " " "\n" | grep -E "^(render|video)$"'
if ! id -nG | grep -qw render; then echo "  adding $USER to render,video (needed for /dev/kfd and /dev/dri/renderD*; takes effect at next login)"; sudo usermod -aG render,video "$USER"; fi
# AUR helper for amdgpu_top
AUR=""; for h in yay paru; do command -v $h >/dev/null 2>&1 && { AUR=$h; break; }; done
if [ -n "$AUR" ]; then $AUR -S --needed --noconfirm amdgpu_top 2>&1 | tail -n 3; else echo "  no yay/paru found: install amdgpu_top from the AUR by hand (or: cargo install amdgpu_top)" | tee -a "$OUT"; fi
rec 'pacman -Q amdgpu_top 2>/dev/null; amdgpu_top --version 2>/dev/null'

sec "2.4 llama.cpp: Vulkan and ROCm builds (separate tree, does not touch the CUDA build)"
if [ -d "$LLAMA_DIR/.git" ]; then git -C "$LLAMA_DIR" fetch --depth 1 origin "$LLAMA_REF" 2>&1 | tail -n 1; git -C "$LLAMA_DIR" checkout -q FETCH_HEAD 2>/dev/null || git -C "$LLAMA_DIR" pull --ff-only 2>&1 | tail -n 1
else git clone --depth 1 --branch "$LLAMA_REF" https://github.com/ggml-org/llama.cpp "$LLAMA_DIR" 2>&1 | tail -n 2 || git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"; fi
COMMIT="$(git -C "$LLAMA_DIR" rev-parse HEAD)"
rec "git -C '$LLAMA_DIR' log -1 --format='%H %cd %s'"
rec "grep -rlE 'qwen4' '$LLAMA_DIR/src/llama-arch.cpp' '$LLAMA_DIR/src/models' 2>/dev/null | head -n 5; grep -oE 'LLM_ARCH_QWEN4[A-Z_]*' '$LLAMA_DIR/src/llama-arch.h' 2>/dev/null | sort -u"
if grep -qiE 'qwen4' "$LLAMA_DIR/src/llama-arch.cpp" 2>/dev/null; then echo "  Qwen3.8-Flash-Next (qwen4exp arch) support present in this commit: OK" | tee -a "$OUT"; else echo "  WARNING: no qwen4* arch in llama-arch.cpp — the model will not load with this commit (support merged in v0.4.0, PR ggml-org/llama.cpp#27742)" | tee -a "$OUT"; fi

echo "--- Vulkan build -> $LLAMA_DIR/build-vulkan" | tee -a "$OUT"
cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-vulkan" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON -DGGML_NATIVE=ON -DLLAMA_CURL=ON -DLLAMA_BUILD_TESTS=OFF 2>&1 | tail -n 3
cmake --build "$LLAMA_DIR/build-vulkan" --config Release -j "$JOBS" --target llama-server llama-bench llama-cli llama-mtmd-cli 2>&1 | tail -n 3
rec "ls -l '$LLAMA_DIR'/build-vulkan/bin/llama-{server,bench,cli,mtmd-cli} 2>&1"

echo "--- ROCm/HIP build -> $LLAMA_DIR/build-rocm (GPU_TARGETS=$GPU_TARGET)" | tee -a "$OUT"
export PATH="/opt/rocm/bin:$PATH" ROCM_PATH=/opt/rocm HIP_PATH=/opt/rocm
HIPCXX_BIN="$(hipconfig -l 2>/dev/null)/clang++"; [ -x "$HIPCXX_BIN" ] || HIPCXX_BIN=/opt/rocm/lib/llvm/bin/clang++
EXTRA=(); pacman -Q rocwmma >/dev/null 2>&1 && EXTRA+=(-DGGML_HIP_ROCWMMA_FATTN=ON)
HIPCXX="$HIPCXX_BIN" HIP_PATH=/opt/rocm cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-rocm" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DGGML_HIP=ON -DGPU_TARGETS="$GPU_TARGET" -DAMDGPU_TARGETS="$GPU_TARGET" -DGGML_NATIVE=ON -DLLAMA_CURL=ON -DLLAMA_BUILD_TESTS=OFF \
  -DCMAKE_HIP_COMPILER="$HIPCXX_BIN" "${EXTRA[@]}" 2>&1 | tail -n 3
cmake --build "$LLAMA_DIR/build-rocm" --config Release -j "$JOBS" --target llama-server llama-bench llama-cli llama-mtmd-cli 2>&1 | tail -n 3
rec "ls -l '$LLAMA_DIR'/build-rocm/bin/llama-{server,bench,cli,mtmd-cli} 2>&1"
rec "'$LLAMA_DIR/build-vulkan/bin/llama-cli' --version 2>&1 | head -n 2; '$LLAMA_DIR/build-rocm/bin/llama-cli' --version 2>&1 | head -n 2"
printf '\nllama.cpp commit: `%s`\n' "$COMMIT" | tee -a "$OUT"
echo "$COMMIT" > "$GPU_SWAP_DIR/llama.cpp-commit.txt"

sec "2.5 PyTorch on ROCm — NOT installed on the host"
cat <<'T' | tee -a "$OUT"
The CUDA venvs are untouched. If a ROCm PyTorch is wanted later, keep it off the host and use a toolbox/distrobox
with the official gfx1201-capable image instead:
    sudo pacman -S --needed distrobox podman   # or toolbox
    distrobox create --name rocm-torch --image docker.io/rocm/pytorch:latest --additional-flags "--device /dev/kfd --device /dev/dri --group-add video --group-add render"
    distrobox enter rocm-torch   # python -c 'import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))'
(Alternatively a venv with the ROCm wheel index: pip install --index-url https://download.pytorch.org/whl/rocm7.0 torch — only after confirming gfx1201 is in the wheel's target list.)
T
echo; echo "wrote $OUT"
