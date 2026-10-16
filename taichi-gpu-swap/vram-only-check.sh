#!/usr/bin/env bash
# VRAM-only production check: load a model with FULL offload (-ngl 99 -fit off) and a long context on both
# cards, prove weights + KV cache sit in VRAM (sysfs vram/gtt per card, MemAvailable), then time a long
# prompt. Usage: vram-only-check.sh <vulkan|rocm> <model.gguf> <mmproj.gguf|-> <ctx> [devices] [extra args]
#   e.g. vram-only-check.sh vulkan ~/models/qwen3.8-27b/Qwen3.8-27B-Q8_0.gguf ~/models/qwen3.8-27b/mmproj-F16.gguf 131072 Vulkan0,Vulkan1
set -uo pipefail
BE="$1"; MODEL="$2"; MMPROJ="${3:--}"; CTX="${4:-131072}"; DEV="${5:-}"; shift 5 2>/dev/null || shift $#
EXTRA=("$@")
GPU_SWAP_DIR="${GPU_SWAP_DIR:-$HOME/gpu-swap}"; BIN="$GPU_SWAP_DIR/llama.cpp/build-$BE/bin/llama-server"
PORT="${PORT:-8098}"; PROMPT_TOKENS="${PROMPT_TOKENS:-30000}"; TS="$(date +%Y%m%d-%H%M%S)"
LOG="$GPU_SWAP_DIR/vram-only-$BE-$TS.log"; OUT="$GPU_SWAP_DIR/vram-only-$BE-$TS.md"
[ -z "$DEV" ] && { [ "$BE" = vulkan ] && DEV="Vulkan0,Vulkan1" || DEV="ROCm0,ROCm1"; }
vram() { for d in /sys/class/drm/card[0-9]/device; do [ -f "$d/mem_info_vram_used" ] || continue; printf '%s vram=%dM gtt=%dM  ' "$(basename "$(readlink -f "$d")")" $(( $(cat "$d/mem_info_vram_used")/1048576 )) $(( $(cat "$d/mem_info_gtt_used")/1048576 )); done; printf 'MemAvailable=%dM\n' $(( $(awk '/^MemAvailable:/{print $2}' /proc/meminfo)/1024 )); }
sudo -n true 2>/dev/null && { sync; echo 2 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null; }
echo "# VRAM-only check: $BE, $(basename "$MODEL"), ctx=$CTX, devices=$DEV" | tee "$OUT"
echo "before: $(vram)" | tee -a "$OUT"
MM=(); [ "$MMPROJ" != - ] && MM=(--mmproj "$MMPROJ")
"$BIN" -m "$MODEL" "${MM[@]}" -ngl 99 -fit off --no-host --jinja -fa on -c "$CTX" --device "$DEV" -sm layer --host 127.0.0.1 --port "$PORT" "${EXTRA[@]}" >"$LOG" 2>&1 &
PID=$!; trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null' EXIT
for _ in $(seq 1 300); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; kill -0 $PID 2>/dev/null || break; sleep 2; done
if ! curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then echo "FAILED to start: $(grep -m1 -iE 'error|failed|GGML_ASSERT|out of memory' "$LOG" | cut -c1-200)" | tee -a "$OUT"; exit 1; fi
echo "loaded: $(vram)" | tee -a "$OUT"
grep -iE "offloaded|CPU_Mapped|model buffer size|KV buffer size|compute buffer size" "$LOG" | cut -c1-160 | tee -a "$OUT"
PF="$GPU_SWAP_DIR/vram-only-prompt.txt"
python3 -I - "$PF" "$PROMPT_TOKENS" <<'PY'
import sys, random
out, n = sys.argv[1], int(sys.argv[2]); random.seed(7)
words = "the system boots into a working desktop and the inference server answers requests from the agent profiles while the second card sits on the chipset lanes which is fine for layer split decoding because activations crossing between cards are small compared to weights".split()
body = []; est = 0
while est < n: body.append(random.choice(words)); est += 1.3
open(out, "w").write("Read the following log carefully, then answer the question at the end.\n\n" + " ".join(body) + "\n\nQuestion: In one sentence, what is the text about?\n")
PY
python3 -I - "$PORT" "$PF" <<'PY' | tee -a "$OUT"
import sys, json, urllib.request
port, pf = sys.argv[1:3]
body = json.dumps({"prompt": open(pf).read(), "n_predict": 128, "temperature": 0, "cache_prompt": False}).encode()
j = json.load(urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/completion", body, {"Content-Type": "application/json"}), timeout=3600))
t = j.get("timings", {})
print(f'long prompt: n_prompt={t.get("prompt_n")} prompt={t.get("prompt_per_second",0):.1f} tok/s TTFT={t.get("prompt_ms",0)/1000:.1f}s gen={t.get("predicted_per_second",0):.2f} tok/s (n={t.get("predicted_n")})')
PY
echo "during: $(vram)" | tee -a "$OUT"
echo "assert check: $(grep -m1 -E 'ggml-backend-meta|GGML_ASSERT|out of memory|Segmentation' "$LOG" || echo clean)" | tee -a "$OUT"
echo "report: $OUT (log $LOG)"
