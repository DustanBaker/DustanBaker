# Taichi Station — GPU swap runbook (RTX 5090 ⇄ 2× Radeon AI PRO R9700)

Box: ASRock B650E Taichi Lite, Ryzen 7 7800X3D (Raphael iGPU), Omarchy (Arch + Hyprland, Limine + Snapper).
Everything below lives in `~/gpu-swap/` (installed from the `taichi-gpu-swap/` folder of this repo with `./install.sh`).

## 0. Before the swap (software only, 5090 still in)

Run in this order, all while the NVIDIA desktop is working:

| step | command | writes |
|---|---|---|
| snapshot | `~/gpu-swap/00-snapshot.sh` | snapper snapshot "pre-gpu-swap" + `/root/gpu-swap-backup/<ts>-pre-gpu-swap/` |
| inventory | `~/gpu-swap/01-inventory.sh` | `~/gpu-swap/inventory-nvidia.md` |
| touchpoints | `~/gpu-swap/02-find-touchpoints.sh` | `~/gpu-swap/nvidia-touchpoints.md`, `~/gpu-swap/gpu-profile.conf` |
| AMD stack + builds | `~/gpu-swap/03-install-amd-stack.sh` | packages (nothing removed), `~/gpu-swap/llama.cpp/build-{vulkan,rocm}`, `~/gpu-swap/amd-stack.md` |
| models | `~/gpu-swap/04-download-models.sh` | `~/models/AD-4.27bpw-Q4_K_M-M64/*`, `~/models/mmproj-Qwen3.8-Flash-Next-F16.gguf`, `SHA256SUMS.*` |
| prove the switch | `~/gpu-swap/verify-inverse.sh` | nothing (sandbox copy + two real `--dry-run`s) |

Read `gpu-profile.conf` once after step 3: it is the exact list of what `gpu-profile` will remove for `amd`
and put back for `nvidia`. If `LLAMA_UNIT` was auto-filled, check `LLAMA_EXEC_AMD` is the command you want
(same `--host/--port/-m`, binary swapped to `build-vulkan/bin/llama-server`). Blank it to leave the service alone.

## 1. Physical checklist

- **Power.** Each R9700 is 300 W through one 16-pin (12V-2x6) connector. You need **two** 16-pin connectors
  (native, or two separate 3×8-pin → 16-pin adapters on separate PSU rails). Don't daisy-chain one cable.
  ~600 W GPU + ~120 W CPU: a 1000 W unit is comfortable, 850 W is the floor.
- **Slots.** Top PCIe 5.0 x16 slot (CPU lanes) = card 1 = **monitor goes here**. Second x16-length slot is
  **x4 from the B650E chipset**: fine for layer-split inference (only small activations cross between cards),
  slow for tensor-split/row-split and for model loading on that card. Make sure the second card's backplate
  clears the top card's fans; both are dual-slot blower cards.
- **BIOS (press Del at POST):**
  - Advanced → PCI Subsystem: **Above 4G Decoding = Enabled**, **Re-Size BAR Support = Auto/Enabled** (ROCm wants large BAR).
  - Advanced → AMD CBS / Onboard Devices: **Primary Video / Initial Display Output = PCIe (PEG)**, not IGD/Auto.
  - **iGPU**: leave on for the first boot (it is the TTY fallback if the discrete cards don't light up), then
    consider **Disabled** once everything works so Hyprland and Vulkan never see a third GPU.
  - CSM off, Secure Boot as it was (Omarchy/Limine assumes it is off).
- **Cabling.** DisplayPort into card 1. Keep an HDMI cable handy for the motherboard port (iGPU) as a fallback.

## 2. The swap — exact order

```
~/gpu-swap/gpu-profile amd --dry-run      # read the diff one last time
~/gpu-swap/gpu-profile amd                # backs up to /root/gpu-swap-backup/<ts>-amd, writes files, asks before mkinitcpio -P + limine-update
sudo poweroff
```
Unplug, swap cards, cable the monitor into the top card, boot, enter BIOS, set the items above, save, boot.

First boot checks (in a terminal in Hyprland, or on the TTY if not):
```
lspci -k -d ::0300                      # both cards bound to "amdgpu"
ls -l /dev/dri/by-path/                 # three cards if the iGPU is on
journalctl -b -k | grep -iE "amdgpu|drm" | tail -n 40
vulkaninfo --summary | grep -E "deviceName|driverName"    # radv on both R9700s
rocminfo | grep -E "Name:\s+gfx"        # gfx1201 twice
amdgpu_top                              # live view of both cards
hyprctl monitors                        # desktop is on the discrete card output
~/gpu-swap/gpu-profile status
```
Then the inference test:
```
~/gpu-swap/test-flash-next.sh            # Vulkan first, then ROCm; report in ~/gpu-swap/test-results-<ts>.md
```
If the production llama-server unit was repointed (`LLAMA_UNIT` in gpu-profile.conf), start it and hit the
same endpoint the Hermes Agent profiles and Qwen Code already use: `systemctl status <unit>`, then
`curl -s http://127.0.0.1:<port>/v1/models`. Nothing changes on the client side.

## 3. Swap-back

```
~/gpu-swap/gpu-profile nvidia            # restores MODULES, cmdline tokens in their original position, env lines; removes the drop-in
sudo poweroff
```
Swap the 5090 back in, monitor into the 5090, BIOS primary display = PCIe (unchanged), boot.
`gpu-profile nvidia` is a no-op if the nvidia profile is already active, and `verify-inverse.sh` has shown
on this exact config that `nvidia(amd(x)) == x` byte for byte.

## 4. Known risks and what to check if the desktop doesn't come up

| symptom | what it is | do this |
|---|---|---|
| Black screen after Limine, no TTY on the card output | amdgpu not in initramfs / firmware missing / card not initialised | Plug HDMI into the motherboard (iGPU). `Ctrl+Alt+F3` for a TTY. `journalctl -b -k \| grep -iE "amdgpu\|firmware"`. Check `ls /usr/lib/firmware/amdgpu/gc_12_0_1*`. Re-run `sudo mkinitcpio -P && sudo limine-update`. |
| TTY works, Hyprland fails / exits immediately | Hyprland picked the iGPU, or a stale NVIDIA env var | `cat ~/.local/share/hyprland/hyprland.log` (or `~/.cache/hyprland/`), `journalctl --user -b -u 'uwsm*' -u 'hyprland*'`. Uncomment the `AQ_DRM_DEVICES` line gpu-profile added at the end of `~/.config/hypr/envs.conf`, point it at `/dev/dri/by-path/pci-<top-card>-card`, relaunch. Confirm no `env = *,nvidia` line is still active: `grep -nE "nvidia\|NVD_\|GBM_BACKEND" ~/.config/hypr/*.conf`. |
| Desktop is up but on the wrong GPU (laggy, `hyprctl monitors` shows the iGPU output) | aquamarine chose the first DRM node | same `AQ_DRM_DEVICES` fix, or disable the iGPU in BIOS. |
| Cursor invisible / flickering | leftover `no_hardware_cursors`/`WLR_NO_HARDWARE_CURSORS` | these are NVIDIA workarounds; gpu-profile commented them out — check they stayed commented after an Omarchy update. |
| Boots into the old kernel cmdline / nvidia_drm.modeset still in `/proc/cmdline` | limine.conf not regenerated | `sudo limine-update` (Omarchy) or `sudo limine-mkinitcpio`; compare `/etc/default/limine` with `/boot/limine.conf`. |
| `rocminfo` shows nothing / `HSA_STATUS_ERROR` | user not in `render`/`video`, or no large BAR | `id -nG`, `sudo usermod -aG render,video $USER` + relogin; BIOS Above 4G Decoding + ReBAR. |
| Only one R9700 visible | second slot not enumerating / power | `lspci -d ::0300` shows one device → reseat, check the second 16-pin, BIOS PCIe slot set to Gen4/x4 (not "Auto" if it mis-trains). |
| llama.cpp: `unknown model architecture: 'qwen4_exp'` | build predates Qwen3.8-Flash-Next support | the builds come from upstream HEAD (support landed in v0.4.0, PR #27742). Rebuild with `LLAMA_REF=master ~/gpu-swap/03-install-amd-stack.sh`. |
| Dual-card run aborts with a `ggml-backend-meta` assertion | known multi-GPU MoE issue on R9700 | test-flash-next.sh records it per backend. Workarounds to try: `-sm layer` on the other backend, `--n-cpu-moe N`, or run one card per llama-server. |
| Out of memory with `-ngl 99 -fit off` | ~93 GB of weights vs 64 GB VRAM | expected; the test script retries with `-fit on`. For production use `-fit on` or `--n-cpu-moe N` and 64 GB+ of system RAM. |
| Everything broken, want the old system back | | Reboot → Limine menu → Snapshots → "pre-gpu-swap" (root only; `/home` and the gpu-swap backups are untouched). Or restore files: `/root/gpu-swap-backup/<ts>-amd/MANIFEST` lists them. |

Snapshots restore `/` but not `/home`: `~/.config/hypr/envs.conf` and `hyprland.conf` are restored by
`gpu-profile nvidia` or from `/root/gpu-swap-backup/<ts>-amd/home/...`.

## 5. What was NOT done in advance (and why)

- Nothing was rebooted, no package was removed, no profile was applied. `gpu-profile amd` is yours to run.
- The GPU paths of the Vulkan/ROCm builds, the dual-card split and vision could not be tested without the cards.
- The second card's PCI address (and so its `/dev/dri/by-path` name) is only knowable after the swap;
  the AQ_DRM_DEVICES block has a `<second-card>` placeholder for it.
