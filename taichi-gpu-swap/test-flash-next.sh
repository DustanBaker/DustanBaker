#!/usr/bin/env bash
# Phase 4.2 — first boot on the R9700s: exercise both llama.cpp builds with Qwen3.8-Flash-Next Q4_K_M.
# Vulkan first (reported faster than ROCm on the R9700 for token generation), then ROCm.
# For each backend: single card, then both cards (layer split):
#   - llama-bench: generation tok/s and prompt-processing tok/s
#   - llama-server: real ~30K-token prompt through /completion (prompt tok/s, gen tok/s, time to first token)
#   - dual-card: did the split load without the ggml-backend-meta assertion?
#   - vision via llama-mtmd-cli + mmproj
# Flags per the plan: -ngl 99 --jinja -fa on -fit off, mmap on (no --no-mmap).
# Report: ~/gpu-swap/test-results-<ts>.md, logs in ~/gpu-swap/test-logs-<ts>/
set -uo pipefail
GPU_SWAP_DIR="${GPU_SWAP_DIR:-$HOME/gpu-swap}"
LLAMA_DIR="${LLAMA_DIR:-$GPU_SWAP_DIR/llama.cpp}"
MODELS="${MODELS:-$HOME/models}"
SUBDIR="${SUBDIR:-AD-4.27bpw-Q4_K_M-M64}"
MODEL="${MODEL:-$(ls "$MODELS/$SUBDIR"/*00001-of-*.gguf 2>/dev/null | head -n1)}"
[ -n "$MODEL" ] || MODEL="$(ls "$MODELS/$SUBDIR"/*.gguf 2>/dev/null | head -n1)"
MMPROJ="${MMPROJ:-$MODELS/mmproj-Qwen3.8-Flash-Next-F16.gguf}"
CTX="${CTX:-40960}"            # room for the ~30K prompt + answer
PROMPT_TOKENS="${PROMPT_TOKENS:-30000}"
PORT="${PORT:-8099}"           # test port; production llama-server keeps its own
BACKENDS="${BACKENDS:-vulkan rocm}"
TS="$(date +%Y%m%d-%H%M%S)"
LOGS="$GPU_SWAP_DIR/test-logs-$TS"; mkdir -p "$LOGS"
REPORT="$GPU_SWAP_DIR/test-results-$TS.md"
[ -f "$MODEL" ] || { echo "model not found under $MODELS/$SUBDIR" >&2; exit 1; }

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
row() { printf '| %s |\n' "$(printf '%s | ' "$@" | sed 's/ | $//')" | tee -a "$REPORT"; }
assert_check() {  # assert_check <logfile> -> "clean" or the offending line
  local l; l="$(grep -m1 -E 'ggml-backend-meta|GGML_ASSERT|unknown model architecture|failed to load model|out of memory|Segmentation|Aborted' "$1" 2>/dev/null || true)"
  [ -z "$l" ] && echo "clean" || echo "FAIL: ${l:0:120}"
}
kill_server() { [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""; }
trap kill_server EXIT

# ---- environment report
printf '# Qwen3.8-Flash-Next on 2x R9700 — first-boot test %s\n\n' "$TS" > "$REPORT"
say "model: \`$MODEL\`"; say "mmproj: \`$MMPROJ\`"; say "llama.cpp: \`$(cat "$GPU_SWAP_DIR/llama.cpp-commit.txt" 2>/dev/null || git -C "$LLAMA_DIR" rev-parse HEAD)\`"
say ""; say '```'
{ uname -r; lspci -nn -d ::0300; ls -l /dev/dri/by-path/ 2>/dev/null; vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName' ; rocminfo 2>/dev/null | grep -E '^\s+Name:\s+gfx' ; } | tee -a "$REPORT"
say '```'
say ""; say "Hyprland DRM device in use: \`$(cat /proc/$(pgrep -x Hyprland | head -n1)/environ 2>/dev/null | tr '\0' '\n' | grep AQ_DRM_DEVICES || echo 'AQ_DRM_DEVICES unset (aquamarine auto-pick)')\`"

# ---- a ~30K-token prompt (English prose ≈ 1.3 tokens/word → ~23K words)
PROMPT_FILE="$LOGS/prompt-30k.txt"
python3 -I - "$PROMPT_FILE" "$PROMPT_TOKENS" <<'PY'
import sys, random
out, n = sys.argv[1], int(sys.argv[2]); random.seed(7)
words = "the system boots into a working desktop and the inference server answers requests from the agent profiles while the second card sits on the chipset lanes which is fine for layer split decoding because activations crossing between cards are small compared to weights".split()
body = []; est = 0
while est < n: w = random.choice(words); body.append(w); est += 1.3
open(out, "w").write("Read the following log carefully, then answer the question at the end.\n\n" + " ".join(body) + "\n\nQuestion: In one sentence, what is the text about?\n")
PY
# test image for vision (red square + blue disc, pure stdlib)
IMG="$LOGS/test.png"
python3 -I - "$IMG" <<'PY'
import sys, zlib, struct
w = h = 256; rows = []
for y in range(h):
    row = bytearray([0])
    for x in range(w):
        inside = (x-128)**2 + (y-128)**2 < 60**2
        row += bytes((40, 80, 220) if inside else (220, 40, 40))
    rows.append(bytes(row))
raw = b"".join(rows)
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY

bench_flags() {  # llama-bench syntax differs slightly between versions; probe --help
  local b="$1" f="-ngl 99 -fa 1 -mmp 1 -p 512,$PROMPT_TOKENS -n 128 -r 2"
  "$b" --help 2>&1 | grep -q -- '-fit' && f="$f -fit 0"
  echo "$f"
}
server_bench() {  # server_bench <bin> <devices-arg> <label> [fit] -> prints "prompt_tps gen_tps ttft_s n_prompt assert"
  local bin="$1" dev="$2" label="$3" fit="${4:-off}" log="$LOGS/server-$label.log"
  kill_server
  "$bin" -m "$MODEL" --mmproj "$MMPROJ" -ngl 99 --jinja -fa on -fit "$fit" -c "$CTX" --host 127.0.0.1 --port "$PORT" $dev >"$log" 2>&1 &
  SRV_PID=$!
  for _ in $(seq 1 180); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; kill -0 "$SRV_PID" 2>/dev/null || break; sleep 2; done
  if ! curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    kill_server
    # 93 GB of Q4_K_M cannot sit in 64 GB of VRAM: if the -fit off run died on allocation, retry once with -fit on
    if [ "$fit" = off ] && grep -qiE 'out of memory|failed to allocate|ggml_backend_alloc|not enough' "$log"; then
      server_bench "$bin" "$dev" "$label-fit-on" on | sed 's/$/ (fallback:-fit_on)/'; return
    fi
    echo "- - - - $(assert_check "$log")"; return
  fi
  python3 -I - "$PORT" "$PROMPT_FILE" "$LOGS/server-$label.json" <<'PY'
import sys, json, time, urllib.request
port, pf, out = sys.argv[1:4]
body = json.dumps({"prompt": open(pf).read(), "n_predict": 64, "temperature": 0, "cache_prompt": False}).encode()
t0 = time.time()
r = urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/completion", body, {"Content-Type": "application/json"}), timeout=3600)
j = json.load(r); t = j.get("timings", {}); open(out, "w").write(json.dumps(j, indent=1))
print(f'{t.get("prompt_per_second",0):.1f} {t.get("predicted_per_second",0):.2f} {t.get("prompt_ms",0)/1000:.1f} n_prompt={t.get("prompt_n","?")}', end=" ")
PY
  local res=$?
  [ $res = 0 ] || printf -- '- - - request_failed '
  echo "$(assert_check "$log")"
  kill_server
}

for be in $BACKENDS; do
  BIN="$LLAMA_DIR/build-$be/bin"; [ -x "$BIN/llama-server" ] || { say ""; say "## $be: build missing at $BIN — skipped"; continue; }
  say ""; say "## backend: $be  (\`$BIN\`)"; say ""
  say '```'; "$BIN/llama-cli" --list-devices 2>&1 | tee -a "$REPORT"; say '```'
  if [ "$be" = vulkan ]; then D1="--device Vulkan0"; D2="--device Vulkan0,Vulkan1"; else D1="--device ROCm0"; D2="--device ROCm0,ROCm1"; fi
  # ---- llama-bench
  say ""; say "### llama-bench"; say ""; say '```'
  for cfg in "single:$D1" "dual:$D2"; do
    name="${cfg%%:*}"; dev="${cfg#*:}"
    echo "--- $name ($dev)" | tee -a "$REPORT"
    # shellcheck disable=SC2046
    "$BIN/llama-bench" -m "$MODEL" $(bench_flags "$BIN/llama-bench") -sm layer $(printf '%s' "$dev" | sed 's/--device/--device/') 2>"$LOGS/bench-$be-$name.err" | tee -a "$REPORT" | tail -n 6
    echo "load/assert check: $(assert_check "$LOGS/bench-$be-$name.err")" | tee -a "$REPORT"
  done
  say '```'
  # ---- llama-server with the 30K prompt
  say ""; say "### llama-server, ~${PROMPT_TOKENS}-token prompt, 64 generated tokens"; say ""
  row "config" "prompt tok/s" "gen tok/s" "TTFT (s)" "notes" "assert check"
  row "---" "---" "---" "---" "---" "---"
  r1="$(server_bench "$BIN/llama-server" "$D1" "$be-single" | tr '\n' ' ')"; set -- $r1; row "single card ($D1)" "${1:-?}" "${2:-?}" "${3:-?}" "${4:-}" "${*:5}"
  r2="$(server_bench "$BIN/llama-server" "$D2 -sm layer" "$be-dual" | tr '\n' ' ')"; set -- $r2; row "both cards, layer split" "${1:-?}" "${2:-?}" "${3:-?}" "${4:-}" "${*:5}"
  # ---- vision
  say ""; say "### vision (llama-mtmd-cli, both cards)"; say ""; say '```'
  timeout 900 "$BIN/llama-mtmd-cli" -m "$MODEL" --mmproj "$MMPROJ" --image "$IMG" -p "What shapes and colours are in this image? Answer in one sentence." -ngl 99 --jinja -fa on -fit off $D2 -n 64 --temp 0 >"$LOGS/mtmd-$be.log" 2>&1
  tail -n 4 "$LOGS/mtmd-$be.log" | tee -a "$REPORT"
  echo "vision check: $(grep -qiE 'blue|circle|disc|red|square' "$LOGS/mtmd-$be.log" && echo 'answer mentions the shapes/colours: OK' || echo 'answer did not describe the image — check log') / $(assert_check "$LOGS/mtmd-$be.log")" | tee -a "$REPORT"
  say '```'
done

say ""; say "## Summary"; say ""
say "- Logs: \`$LOGS\`"
say "- Dual-card split status: $(grep -l 'ggml-backend-meta' "$LOGS"/*dual* 2>/dev/null | wc -l) log(s) hit the ggml-backend-meta assertion (0 = good)."
say "- If Vulkan is faster for generation and ROCm for prompt processing (the Phoronix R9700 pattern), pick per workload: agents with long contexts → compare TTFT above."
say "- Memory: Q4_K_M ~93 GB does not fit in 64 GB VRAM; expect partial offload via -ngl auto or mmap paging unless -fit/-ot is used. Compare with: \`-ngl auto\` and \`--n-cpu-moe N\`."
echo; echo "report: $REPORT"
