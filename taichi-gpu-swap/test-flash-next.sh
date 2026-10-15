#!/usr/bin/env bash
# Phase 4.2 — first boot on the R9700s: exercise both llama.cpp builds with Qwen3.8-Flash-Next Q4_K_M.
# Vulkan first (reported faster than ROCm on the R9700 for token generation), then ROCm.
# For each backend: single card, then both cards (layer split):
#   - llama-bench: generation tok/s and prompt-processing tok/s
#   - llama-server: real ~30K-token prompt through /completion (prompt tok/s, gen tok/s, time to first token)
#   - dual-card: did the split load without the ggml-backend-meta assertion?
#   - vision via llama-mtmd-cli + mmproj
# Flags: --jinja -fa on, mmap on. Memory: this quant is ~89 GB of weights; Taichi Station has 64 GB of VRAM and
# 30 GB of RAM, so "-ngl 99 -fit off" cannot fit and, tried on 2026-10-15, starved the display card's VRAM
# (Hyprland aborted) and spilled into RAM until the OOM killer fired. Default is therefore FIT=on with -ngl left
# unset (fit only adjusts unset arguments) and a VRAM margin per device (FIT_TARGET_*; device 0 drives the
# desktop, keep >= 3 GB there). FIT=off restores the original full-offload attempt.
# Report: ~/gpu-swap/test-results-<ts>.md, logs in ~/gpu-swap/test-logs-<ts>/
set -uo pipefail
GPU_SWAP_DIR="${GPU_SWAP_DIR:-$HOME/gpu-swap}"
LLAMA_DIR="${LLAMA_DIR:-$GPU_SWAP_DIR/llama.cpp}"
MODELS="${MODELS:-$HOME/models}"
SUBDIR="${SUBDIR:-Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64}"
MODEL="${MODEL:-$(ls "$MODELS/$SUBDIR"/*00001-of-*.gguf 2>/dev/null | head -n1)}"
[ -n "$MODEL" ] || MODEL="$(ls "$MODELS/$SUBDIR"/*.gguf 2>/dev/null | head -n1)"
MMPROJ="${MMPROJ:-$MODELS/mmproj-Qwen3.8-Flash-Next-F16.gguf}"
CTX="${CTX:-40960}"            # room for the ~30K prompt + answer
PROMPT_TOKENS="${PROMPT_TOKENS:-30000}"
PORT="${PORT:-8099}"           # test port; production llama-server keeps its own
BACKENDS="${BACKENDS:-vulkan rocm}"
FIT="${FIT:-on}"                                  # on: let llama.cpp pick -ngl/ctx to fit; off: -ngl 99 -fit off
FIT_TARGET_SINGLE="${FIT_TARGET_SINGLE:-3072}"    # MiB of VRAM left free on the (display) card
FIT_TARGET_DUAL="${FIT_TARGET_DUAL:-3072,2048}"   # per device, comma separated (device 0 = display card)
BENCH_REPS="${BENCH_REPS:-1}"
CONFIGS="${CONFIGS:-single dual}"                 # which card configurations to run; on Taichi Station "dual" only:
                                                  # single card leaves ~56 GB of weights on the CPU side of 30 GB RAM
MIN_FREE_MB="${MIN_FREE_MB:-6000}"                # skip a step when MemAvailable is below this (protects the desktop)
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
kill_server() { if [ -n "${SRV_PID:-}" ]; then kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; fi; SRV_PID=""; }
mem_guard() {  # mem_guard <label> -> 0 if enough RAM is available to start a step, else logs and returns 1
  local avail; avail=$(( $(awk '/^MemAvailable:/{print $2}' /proc/meminfo) / 1024 ))
  [ "$avail" -ge "$MIN_FREE_MB" ] && return 0
  echo "SKIPPED $1: only ${avail} MB of RAM available (< MIN_FREE_MB=$MIN_FREE_MB); not risking the desktop" | tee -a "$REPORT"; return 1
}
in_configs() { case " $CONFIGS " in *" $1 "*) return 0;; *) return 1;; esac; }
fit_args() {  # fit_args <single|dual> -> the offload/fit flags for llama-server / llama-mtmd-cli
  if [ "$FIT" = on ]; then [ "$1" = dual ] && echo "-fit on -fitt $FIT_TARGET_DUAL" || echo "-fit on -fitt $FIT_TARGET_SINGLE"
  else echo "-ngl 99 -fit off"; fi
}
trap kill_server EXIT

# ---- environment report
printf '# Qwen3.8-Flash-Next on 2x R9700 — first-boot test %s\n\n' "$TS" > "$REPORT"
say "model: \`$MODEL\`"; say "mmproj: \`$MMPROJ\`"; say "llama.cpp: \`$(cat "$GPU_SWAP_DIR/llama.cpp-commit.txt" 2>/dev/null || git -C "$LLAMA_DIR" rev-parse HEAD)\`"
say ""; say '```'
{ uname -r; lspci -nn -d ::0300; ls -l /dev/dri/by-path/ 2>/dev/null; vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName' ; rocminfo 2>/dev/null | grep -E '^\s+Name:\s+gfx' ; } | tee -a "$REPORT"
say '```'
say ""; say "RAM: $(free -g | awk '/^Mem:/{print $2" GB total, "$7" GB available"}'); VRAM: $(for d in /sys/class/drm/card[0-9]/device/mem_info_vram_total; do echo -n "$(( $(cat $d) / 1073741824 ))G "; done); weights on disk: $(du -sh "$(dirname "$MODEL")" | cut -f1); fit mode: FIT=$FIT (margins single=$FIT_TARGET_SINGLE dual=$FIT_TARGET_DUAL MiB)"
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

bench_flags() {  # bench_flags <single|dual>; llama-bench (b7xxx+): -fa on|off, -lm mmap, -fitt <MiB,...>, -dev a/b
  local f="-fa on -lm mmap -sm layer -p 512,$PROMPT_TOKENS -n 128 -r $BENCH_REPS"
  # llama-bench takes a single -fitt value (broadcast to every device): use the display card's margin
  if [ "$FIT" = on ]; then f="$f -fitt ${FIT_TARGET_SINGLE%%,*}"; else f="$f -ngl 99"; fi
  echo "$f"
}
server_bench() {  # server_bench <bin> <devices-arg> <label> <single|dual> [fit-override] -> "prompt_tps gen_tps ttft_s n_prompt assert"
  local bin="$1" dev="$2" label="$3" cfg="$4" fitov="${5:-}"
  local log="$LOGS/server-$label.log" fargs
  fargs="$(fit_args "$cfg")"; [ "$fitov" = on ] && fargs="-fit on -fitt $([ "$cfg" = dual ] && echo "$FIT_TARGET_DUAL" || echo "$FIT_TARGET_SINGLE")"
  kill_server
  "$bin" -m "$MODEL" --mmproj "$MMPROJ" --jinja -fa on $fargs -c "$CTX" --host 127.0.0.1 --port "$PORT" $dev >"$log" 2>&1 &
  SRV_PID=$!
  for _ in $(seq 1 180); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; kill -0 "$SRV_PID" 2>/dev/null || break; sleep 2; done
  if ! curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    kill_server
    # 93 GB of Q4_K_M cannot sit in 64 GB of VRAM: if the -fit off run died on allocation, retry once with -fit on
    if [ "$FIT" = off ] && [ -z "$fitov" ] && grep -qiE 'out of memory|failed to allocate|ggml_backend_alloc|not enough' "$log"; then
      server_bench "$bin" "$dev" "$label-fit-on" "$cfg" on | sed 's/$/ (fallback:-fit_on)/'; return
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
  printf '%s ' "$(grep -oE 'offloaded [0-9]+/[0-9]+ layers' "$log" | tail -n1 | tr ' ' '_' || true)"
  echo "$(assert_check "$log")"
  kill_server
}

for be in $BACKENDS; do
  BIN="$LLAMA_DIR/build-$be/bin"; [ -x "$BIN/llama-server" ] || { say ""; say "## $be: build missing at $BIN — skipped"; continue; }
  say ""; say "## backend: $be  (\`$BIN\`)"; say ""
  say '```'; "$BIN/llama-cli" --list-devices 2>&1 | tee -a "$REPORT"; say '```'
  # device 0 is the card driving the desktop (top slot). llama-server/mtmd take a comma list, llama-bench a slash list.
  if [ "$be" = vulkan ]; then D1="--device Vulkan0"; D2="--device Vulkan0,Vulkan1"; B1="-dev Vulkan0"; B2="-dev Vulkan0/Vulkan1"
  else D1="--device ROCm0"; D2="--device ROCm0,ROCm1"; B1="-dev ROCm0"; B2="-dev ROCm0/ROCm1"; fi
  # ---- llama-bench
  say ""; say "### llama-bench"; say ""; say '```'
  for cfg in "single:$B1" "dual:$B2"; do
    name="${cfg%%:*}"; dev="${cfg#*:}"
    in_configs "$name" || { echo "--- $name: not in CONFIGS=\"$CONFIGS\", skipped" | tee -a "$REPORT"; continue; }
    mem_guard "llama-bench $be $name" || continue
    echo "--- $name ($dev; $(bench_flags "$name"))" | tee -a "$REPORT"
    # shellcheck disable=SC2046
    "$BIN/llama-bench" -m "$MODEL" $(bench_flags "$name") $dev 2>"$LOGS/bench-$be-$name.err" | tee -a "$REPORT" | tail -n 6
    echo "load/assert check: $(assert_check "$LOGS/bench-$be-$name.err")" | tee -a "$REPORT"
  done
  say '```'
  # ---- llama-server with the 30K prompt
  say ""; say "### llama-server, ~${PROMPT_TOKENS}-token prompt, 64 generated tokens"; say ""
  row "config" "prompt tok/s" "gen tok/s" "TTFT (s)" "notes" "assert check"
  row "---" "---" "---" "---" "---" "---"
  if in_configs single && mem_guard "llama-server $be single"; then
    r1="$(server_bench "$BIN/llama-server" "$D1" "$be-single" single | tr '\n' ' ')"; set -- $r1; row "single card ($D1)" "${1:-?}" "${2:-?}" "${3:-?}" "${4:-} ${5:-}" "${*:6}"
  else row "single card ($D1)" "-" "-" "-" "skipped (CONFIGS=$CONFIGS / RAM guard)" "-"; fi
  if in_configs dual && mem_guard "llama-server $be dual"; then
    r2="$(server_bench "$BIN/llama-server" "$D2 -sm layer" "$be-dual" dual | tr '\n' ' ')"; set -- $r2; row "both cards, layer split" "${1:-?}" "${2:-?}" "${3:-?}" "${4:-} ${5:-}" "${*:6}"
  else row "both cards, layer split" "-" "-" "-" "skipped (CONFIGS=$CONFIGS / RAM guard)" "-"; fi
  # ---- vision
  say ""; say "### vision (llama-mtmd-cli, both cards)"; say ""; say '```'
  mem_guard "llama-mtmd-cli $be" && \
  timeout 1800 "$BIN/llama-mtmd-cli" -m "$MODEL" --mmproj "$MMPROJ" --image "$IMG" -p "What shapes and colours are in this image? Answer in one sentence." --jinja -fa on $(fit_args dual) $D2 -n 64 --temp 0 >"$LOGS/mtmd-$be.log" 2>&1
  tail -n 4 "$LOGS/mtmd-$be.log" | tee -a "$REPORT"
  echo "vision check: $(grep -qiE 'blue|circle|disc|red|square' "$LOGS/mtmd-$be.log" && echo 'answer mentions the shapes/colours: OK' || echo 'answer did not describe the image — check log') / $(assert_check "$LOGS/mtmd-$be.log")" | tee -a "$REPORT"
  say '```'
done

say ""; say "## Summary"; say ""
say "- Logs: \`$LOGS\`"
say "- Dual-card split status: $(grep -l 'ggml-backend-meta' "$LOGS"/*dual* 2>/dev/null | wc -l) log(s) hit the ggml-backend-meta assertion (0 = good)."
say "- If Vulkan is faster for generation and ROCm for prompt processing (the Phoronix R9700 pattern), pick per workload: agents with long contexts → compare TTFT above."
say "- Memory: ~89 GB of Q4_K_M weights vs 64 GB VRAM + 30 GB RAM: with FIT=on the layers that do not fit stay mmapped on the CPU side and page from NVMe, which dominates prompt processing on a single card. A smaller quant (3.84bpw IQ4_XS is in the same HF repo) or more RAM is the real fix."
echo; echo "report: $REPORT"
