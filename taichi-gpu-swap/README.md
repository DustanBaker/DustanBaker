# taichi-gpu-swap — reversible RTX 5090 ⇄ 2× Radeon AI PRO R9700 on Omarchy

Toolkit for the Taichi Station GPU swap. Everything here was written and tested off-box (no GPU, no Arch),
so the inventory/install/download phases are **scripts for you to run on the machine**, not results.
Start with `RUNBOOK.md`.

```
./install.sh                     # copies everything to ~/gpu-swap
~/gpu-swap/00-snapshot.sh        # Phase 0: snapper "pre-gpu-swap" + /root/gpu-swap-backup/<ts>/
~/gpu-swap/01-inventory.sh       # Phase 0: ~/gpu-swap/inventory-nvidia.md
~/gpu-swap/02-find-touchpoints.sh# Phase 1: ~/gpu-swap/nvidia-touchpoints.md + gpu-profile.conf
~/gpu-swap/03-install-amd-stack.sh # Phase 2: Mesa/RADV/ROCm/amdgpu_top + llama.cpp build-vulkan & build-rocm (nothing removed)
~/gpu-swap/04-download-models.sh # Phase 4: ~93 GB Qwen3.8-Flash-Next Q4_K_M + mmproj, SHA256-verified
~/gpu-swap/verify-inverse.sh     # Phase 3: proves amd/nvidia are exact inverses on a sandbox copy + prints both --dry-runs
~/gpu-swap/gpu-profile amd --dry-run      # Phase 3: the switch (apply it only right before the shutdown)
~/gpu-swap/test-flash-next.sh    # Phase 4: first boot on AMD — llama-bench / llama-server / vision, both backends
```

## gpu-profile

`gpu-profile {amd|nvidia|status} [--dry-run] [--yes]`. Idempotent; each profile is the exact inverse of the other
(`tests/run.sh` checks this byte-for-byte on Limine, UKI and systemd-boot fixtures; `verify-inverse.sh` checks it on
your real files in a sandbox). Per profile it:

1. sets `MODULES=()` in `/etc/mkinitcpio.conf` (or the last `mkinitcpio.conf.d` file that defines it);
2. removes/re-inserts the `nvidia*` kernel cmdline tokens through whatever Omarchy uses
   (`/etc/default/limine` + `limine-update`, `/etc/kernel/cmdline` + UKI, systemd-boot entries, or GRUB);
3. comments out (`# gpu-profile:nvidia-disabled ` prefix) the NVIDIA lines in `~/.config/hypr/envs.conf`,
   `hyprland.conf`, uwsm env, `/etc/environment`, `modules-load.d`, and restores them for nvidia;
4. for amd appends a commented `AQ_DRM_DEVICES` block to `envs.conf` naming the discrete card's
   `/dev/dri/by-path` node (Hyprland is on aquamarine, so it is `AQ_`, not `WLR_DRM_DEVICES`);
5. optionally repoints a llama-server unit at the Vulkan build via a systemd drop-in (same endpoint, new binary);
6. backs every file up to `/root/gpu-swap-backup/<ts>-<profile>/` (with a `MANIFEST`) before writing, and asks
   before running `mkinitcpio -P` / `limine-update`.

Everything it auto-detects can be pinned in `~/gpu-swap/gpu-profile.conf` (see `gpu-profile.conf.example`).
`gpu-profile amd` also records what it removed in `gpu-profile.state` so `nvidia` restores it in the same position.

## Not verified here

- Package names and the current ROCm/kernel versions on your mirror (script records them; Arch is on ROCm 7.2.x).
- Whether Arch's rocBLAS ships gfx1201 tensile kernels (`03-install-amd-stack.sh` prints the count and warns).
- The exact Hugging Face shard filenames (download script reads the tree from the HF API and verifies LFS SHA256).
- GPU behaviour of either llama.cpp build, dual-card split, vision — needs the cards.
