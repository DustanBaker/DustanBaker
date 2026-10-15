#!/usr/bin/env bash
# Phase 4.1 — pre-stage the models into ~/models and verify SHA256 against Hugging Face's LFS metadata.
#   AtomicChat/Qwen3.8-Flash-Next-GGUF : Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64/* (all shards, ~93 GB) + mmproj-Qwen3.8-Flash-Next-F16.gguf
#   optional: WITH_27B=1 adds a Q4 GGUF of Qwen3.8-27B (set QWEN27B_REPO/QWEN27B_GLOB to the exact repo/file you want).
# Resumable; re-run after an interruption. Needs ~100 GB free (checked first).
set -uo pipefail
MODELS="${MODELS:-$HOME/models}"; mkdir -p "$MODELS"
REPO="${REPO:-AtomicChat/Qwen3.8-Flash-Next-GGUF}"
SUBDIR="${SUBDIR:-Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64}"
MMPROJ="${MMPROJ:-mmproj-Qwen3.8-Flash-Next-F16.gguf}"
NEED_GB="${NEED_GB:-100}"
# huggingface_hub >= 1.0 uses hf_xet for fast downloads; hf_transfer is gone, so do not force it on
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-0}"

echo "==> free space on $MODELS"
avail_gb=$(( $(df --output=avail -B1 "$MODELS" | tail -n1) / 1024 / 1024 / 1024 ))
df -h "$MODELS" | sed 's/^/    /'
if [ "$avail_gb" -lt "$NEED_GB" ]; then echo "ERROR: only ${avail_gb} GB free, need ~${NEED_GB} GB. Free space or set MODELS=/other/nvme/path" >&2; exit 1; fi

# ---- tool: hf (huggingface_hub CLI) — install into a throwaway venv if missing (does not touch the CUDA venvs)
HF=""
for c in hf huggingface-cli; do command -v "$c" >/dev/null 2>&1 && { HF="$c"; break; }; done
if [ -z "$HF" ]; then
  V="$HOME/gpu-swap/.venv-hf"
  [ -x "$V/bin/hf" ] || { python3 -m venv "$V" && "$V/bin/pip" -q install -U "huggingface_hub"; }
  HF="$V/bin/hf"
fi
echo "==> using $HF ($($HF version 2>/dev/null | head -n1))"

# ---- expected checksums from the HF API (lfs.oid = sha256)
API="https://huggingface.co/api/models/$REPO/tree/main"
python3 -I - "$API" "$SUBDIR" "$MMPROJ" "$MODELS/SHA256SUMS.$(basename "$SUBDIR")" <<'PY'
import json, sys, urllib.request
api, subdir, mmproj, out = sys.argv[1:5]
def tree(path):
    url = f"{api}/{path}" if path else api
    with urllib.request.urlopen(url, timeout=60) as r: return json.load(r)
rows = []
for e in tree(subdir):
    if e.get("type") == "file" and e["path"].endswith(".gguf"):
        oid = (e.get("lfs") or {}).get("oid"); size = (e.get("lfs") or {}).get("size", e.get("size"))
        rows.append((oid, e["path"], size))
for e in tree(""):
    if e.get("type") == "file" and e["path"] == mmproj:
        rows.append(((e.get("lfs") or {}).get("oid"), e["path"], (e.get("lfs") or {}).get("size", e.get("size"))))
if not rows: sys.exit("no files found via %s — check REPO/SUBDIR" % api)
total = sum((s or 0) for _, _, s in rows)
with open(out, "w") as f:
    for oid, p, s in rows:
        if oid: f.write(f"{oid}  {p}\n")
        else: print(f"WARNING: no LFS sha256 for {p} (not an LFS file?)", file=sys.stderr)
print(f"{len(rows)} files, {total/1e9:.1f} GB total; checksums -> {out}")
for oid, p, s in rows: print(f"   {p}  {(s or 0)/1e9:.2f} GB")
PY
[ $? = 0 ] || exit 1
SUMS="$MODELS/SHA256SUMS.$(basename "$SUBDIR")"

# ---- download (resumable)
echo "==> downloading $REPO/$SUBDIR/* and $MMPROJ -> $MODELS"
"$HF" download "$REPO" --include "$SUBDIR/*" --include "$MMPROJ" --local-dir "$MODELS" 2>&1 | tail -n 5 || { echo "download failed; re-run to resume" >&2; exit 1; }

# ---- verify
echo "==> verifying SHA256 (this reads ~93 GB; takes a few minutes on NVMe)"
( cd "$MODELS" && sha256sum --check --quiet "$SUMS" ) && echo "    all checksums OK" || { echo "CHECKSUM FAILURE — delete the bad file(s) and re-run" >&2; exit 1; }
ls -la "$MODELS/$SUBDIR" "$MODELS/$MMPROJ"

# ---- optional Qwen3.8-27B Q4
if [ "${WITH_27B:-0}" = 1 ]; then
  Q27_REPO="${QWEN27B_REPO:-unsloth/Qwen3.8-27B-GGUF}"; Q27_GLOB="${QWEN27B_GLOB:-*Q4_K_M*.gguf}"
  echo "==> optional: $Q27_REPO ($Q27_GLOB)"
  "$HF" download "$Q27_REPO" --include "$Q27_GLOB" --local-dir "$MODELS/qwen3.8-27b" 2>&1 | tail -n 3
fi
echo "done. First shard: $(ls "$MODELS/$SUBDIR"/*00001-of-*.gguf 2>/dev/null || ls "$MODELS/$SUBDIR"/*.gguf | head -n1)"
