# Handoff prompt for Claude Code running locally on Taichi Station

You are running on "Taichi Station": ASRock B650E Taichi Lite, Ryzen 7 7800X3D (has a Raphael iGPU), Omarchy (Arch + Hyprland, Limine bootloader, Snapper snapshots). The RTX 5090 has already been physically removed and two Radeon AI PRO R9700s (RDNA4, gfx1201, 32 GB each) are installed. The OS is still configured for NVIDIA. Your job is to finish the switch to AMD using the toolkit that is already written, verify the desktop and both llama.cpp backends, and report.

## What already exists

Branch `claude/taichi-gpu-swap-prep-w7p7lz` of github.com/DustanBaker/DustanBaker contains `taichi-gpu-swap/`:
- `README.md`, `RUNBOOK.md` (read both first; RUNBOOK section 0a is the exact order for "cards already installed")
- `install.sh` copies everything to `~/gpu-swap/`
- `00-snapshot.sh` snapper "pre-gpu-swap" + file backup to /root/gpu-swap-backup/
- `01-inventory.sh` -> ~/gpu-swap/inventory-nvidia.md
- `02-find-touchpoints.sh` -> ~/gpu-swap/nvidia-touchpoints.md and ~/gpu-swap/gpu-profile.conf (greps every NVIDIA-specific thing Omarchy or the user added)
- `03-install-amd-stack.sh` Mesa/RADV/Vulkan, ROCm from Arch repos, amdgpu_top (AUR), and two llama.cpp builds from upstream HEAD in ~/gpu-swap/llama.cpp: build-vulkan and build-rocm (gfx1201). Removes nothing, does not touch the existing CUDA build or venvs.
- `04-download-models.sh` AtomicChat/Qwen3.8-Flash-Next-GGUF AD-4.27bpw-Q4_K_M-M64 (all shards, ~93 GB) + mmproj-Qwen3.8-Flash-Next-F16.gguf into ~/models, SHA256-verified against the HF API
- `gpu-profile {amd|nvidia|status} [--dry-run] [--yes]` the reversible switch: mkinitcpio MODULES, kernel cmdline via /etc/default/limine + limine-update (or UKI/sd-boot/GRUB if that is what is found), comments out NVIDIA env lines in ~/.config/hypr/*.conf, uwsm, /etc/environment, modules-load.d, adds a commented AQ_DRM_DEVICES block, optional llama-server unit drop-in. Backs up every file to /root/gpu-swap-backup/<ts>-<profile>/ and asks before mkinitcpio -P / limine-update.
- `verify-inverse.sh` proves on a sandbox copy of the real files that nvidia(amd(x)) == x byte for byte, then prints both real --dry-runs
- `test-flash-next.sh` first-boot test: Vulkan first then ROCm, llama-bench + llama-server (single card, then both cards layer-split) with -ngl 99 --jinja -fa on -fit off, mmap on, a ~30K-token prompt, vision via llama-mtmd-cli; greps for the ggml-backend-meta assertion; retries with -fit on if the 93 GB model does not fit in 64 GB VRAM. Report in ~/gpu-swap/test-results-<ts>.md.

## Do this, in order

1. `git clone -b claude/taichi-gpu-swap-prep-w7p7lz https://github.com/DustanBaker/DustanBaker ~/DustanBaker && ~/DustanBaker/taichi-gpu-swap/install.sh`
2. Sanity check the hardware before changing anything and show me the output: `lspci -k -d ::0300`, `ls -l /dev/dri/by-path/`, `journalctl -b -k | grep -iE "amdgpu|firmware" | tail -n 30`, `cat /proc/cmdline`, `ls /usr/lib/firmware/amdgpu/ | grep -c gc_12_0_1`. Tell me whether both R9700s are bound to amdgpu, whether the iGPU is visible, and what the desktop is currently running on (`hyprctl monitors`, and `grep -nE "nvidia|NVD_|GBM_BACKEND|no_hardware_cursors" ~/.config/hypr/*.conf`).
3. Run `~/gpu-swap/00-snapshot.sh`, `~/gpu-swap/01-inventory.sh`, `~/gpu-swap/02-find-touchpoints.sh`. Read `~/gpu-swap/nvidia-touchpoints.md` and `~/gpu-swap/gpu-profile.conf`. If the touchpoint search missed an NVIDIA setting you can see in those files (it greps, but Omarchy versions differ), add the file to TOGGLE_FILES or the token to NVIDIA_CMDLINE_PARAMS in gpu-profile.conf. If LLAMA_UNIT was auto-filled, check LLAMA_EXEC_AMD keeps the same --host/--port/-m and only swaps the binary; blank LLAMA_UNIT if there is no llama-server service.
4. Start `~/gpu-swap/04-download-models.sh` in the background (check free space first; it does too). It needs ~100 GB on the NVMe.
5. Run `~/gpu-swap/03-install-amd-stack.sh`. It does a full `pacman -Syu`. Record: kernel and linux-firmware versions, ROCm version, whether /opt/rocm/lib/rocblas/library has gfx1201 files, the llama.cpp commit, and whether `src/llama-arch.cpp` contains qwen4 (needed for this model). If the ROCm build fails, keep the Vulkan build and report the error; do not fight it for more than two attempts.
6. Run `~/gpu-swap/verify-inverse.sh` and show me the result and both dry-run diffs.
7. Run `~/gpu-swap/gpu-profile amd`. It asks before `mkinitcpio -P` and `limine-update`; answer yes only after the dry-run diff looked right. Confirm afterwards: `grep MODULES= /etc/mkinitcpio.conf`, `grep KERNEL_CMDLINE /etc/default/limine`, `sudo grep -i cmdline /boot/limine.conf` (or wherever Limine's config is), and that `~/.config/hypr/envs.conf` has the NVIDIA lines prefixed with `# gpu-profile:nvidia-disabled` and the AQ_DRM_DEVICES block at the end.
8. Stop and ask me before rebooting. After I say yes and the machine is back: run the first-boot checks from RUNBOOK section 2 (`lspci -k`, `vulkaninfo --summary`, `rocminfo | grep gfx`, `amdgpu_top -d`, `hyprctl monitors`, `~/gpu-swap/gpu-profile status`). If Hyprland came up on the iGPU, uncomment the AQ_DRM_DEVICES line in envs.conf pointing at the top card and relaunch Hyprland.
9. Once the model download has finished and verified, run `~/gpu-swap/test-flash-next.sh` and give me the table from ~/gpu-swap/test-results-<ts>.md: generation tok/s, prompt-processing tok/s on the 30K prompt, time to first token, single vs dual card, Vulkan vs ROCm, whether the dual-card split hit the ggml-backend-meta assertion, and whether vision worked.
10. If there is a production llama-server unit, restart it and confirm the same endpoint the Hermes Agent profiles and Qwen Code use still answers: `curl -s http://127.0.0.1:<port>/v1/models`.

## Rules

- Do not uninstall any NVIDIA package. Do not run `gpu-profile nvidia`. Do not reboot without asking.
- Ask before anything that touches the bootloader or initramfs outside of what gpu-profile does with my confirmation.
- Every file gpu-profile changes is backed up under /root/gpu-swap-backup/; if something goes wrong, restore from there or from the "pre-gpu-swap" snapshot in the Limine menu.
- If a script fails, read its output, fix the script in ~/DustanBaker/taichi-gpu-swap, re-run, and commit the fix to the branch with a clear message.
- End with a summary: what was done, what the numbers were, what could not be verified, and anything I need to decide (for example Vulkan vs ROCm for the production service).
