#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# start-distributed-model-macos-apple-silicon.sh
# macOS / Apple Silicon only
#
# Recommended for your setup:
#   Run THIS script on the M4 Pro 48 GB Mac.
#   Run share-gpu-worker-macos-apple-silicon.sh on the M4 16 GB Mac.
#
# It:
#   - discovers worker Macs automatically via Bonjour/mDNS
#   - detects local chip / unified memory
#   - builds llama.cpp with Metal + RPC
#   - lets llama.cpp distribute the model based on available
#     local/remote Metal memory
#   - starts llama-server
#
# Model path can be passed as the first argument:
#   ./start-distributed-model-macos-apple-silicon.sh /Users/me/Models/model.gguf
#
# Or:
#   MODEL=/Users/me/Models/model.gguf ./start-distributed-model-macos-apple-silicon.sh
# ============================================================

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/Library/Apple/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
SERVICE_TYPE="_llamacpp-rpc._tcp"
REPO="https://github.com/ggml-org/llama.cpp.git"

MODEL="${1:-${MODEL:-}}"
CONTEXT="${CONTEXT:-8192}"
SERVER_HOST="${SERVER_HOST:-127.0.0.1}"
SERVER_PORT="${SERVER_PORT:-8080}"
DISCOVERY_SECONDS="${DISCOVERY_SECONDS:-4}"
MODE="${MODE:-server}"       # server or cli

die() { echo "ERROR: $*" >&2; exit 1; }

model_alias_from_path() {
    local path="$1"
    local alias

    alias="$(printf '%s\n' "$path" | sed -nE 's#.*models--([^/]+)/.*#\1#p' | head -n 1)"
    if [[ -n "$alias" ]]; then
        printf '%s\n' "${alias//--//}"
        return 0
    fi

    basename "$path" | sed -E 's/\.[Gg][Gg][Uu][Ff]$//'
}

[[ "$(uname -s)" == "Darwin" ]] || die "This script is macOS-only."
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon (arm64) is required."

echo "============================================================"
echo " llama.cpp — START DISTRIBUTED MODEL"
echo "============================================================"
echo

CHIP="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip:/{print $2; exit}')"
MEM_BYTES="$(sysctl -n hw.memsize)"
MEM_GIB=$(( MEM_BYTES / 1024 / 1024 / 1024 ))

echo "Local chip : ${CHIP:-Apple Silicon}"
echo "Unified RAM: ${MEM_GIB} GiB"
echo

# ----- Dependencies -----
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are required."
    echo "Run: xcode-select --install"
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        echo "Installing CMake with Homebrew..."
        brew install cmake
    else
        echo "CMake is required."
        echo "Install Homebrew from https://brew.sh and then run: brew install cmake"
        exit 1
    fi
fi

command -v git >/dev/null 2>&1 || die "git is required."
command -v dns-sd >/dev/null 2>&1 || die "dns-sd (Bonjour) is required."

resolve_ipv4() {
    local host="$1"
    local resolve_log
    local ip

    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "$host"
        return 0
    fi

    resolve_log="$(mktemp -t llama-rpc-host-ip.XXXXXX)"
    dns-sd -G v4 "$host" >"$resolve_log" 2>&1 &
    local resolve_pid=$!
    sleep 2
    kill "$resolve_pid" >/dev/null 2>&1 || true
    wait "$resolve_pid" >/dev/null 2>&1 || true

    ip="$(awk '{for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}' "$resolve_log")"
    rm -f "$resolve_log"

    [[ -n "$ip" ]] && printf '%s\n' "$ip"
}

wait_for_tcp() {
    local host="$1"
    local port="$2"
    local label="$3"

    if ! command -v nc >/dev/null 2>&1; then
        echo "Cannot verify $label because nc is unavailable; using it anyway."
        return 0
    fi

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if nc -z -G 2 "$host" "$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    return 1
}

# ----- Discover workers -----
echo "[1/5] Discovering Macs sharing llama.cpp RPC..."
BROWSE_LOG="$(mktemp -t llama-rpc-browse.XXXXXX)"

dns-sd -B "$SERVICE_TYPE" local >"$BROWSE_LOG" 2>&1 &
BROWSE_PID=$!

sleep "$DISCOVERY_SECONDS"
kill "$BROWSE_PID" >/dev/null 2>&1 || true
wait "$BROWSE_PID" >/dev/null 2>&1 || true

# dns-sd browse output ends with the service instance name after domain/type.
mapfile_compat() {
    # Bash 3.2 ships with macOS; avoid mapfile.
    while IFS= read -r line; do
        [[ -n "$line" ]] && printf '%s\n' "$line"
    done
}

SERVICE_NAMES="$(
    awk '
      / Add / && /_llamacpp-rpc\._tcp\./ {
          # Instance name begins after "_llamacpp-rpc._tcp."
          pos = index($0, "_llamacpp-rpc._tcp.")
          if (pos > 0) {
              s = substr($0, pos + length("_llamacpp-rpc._tcp."))
              sub(/^[[:space:]]+/, "", s)
              sub(/[[:space:]]+$/, "", s)
              if (s != "") print s
          }
      }
    ' "$BROWSE_LOG" | sort -u
)"
rm -f "$BROWSE_LOG"

[[ -n "$SERVICE_NAMES" ]] || {
    echo
    echo "No worker Mac was discovered."
    echo "Run share-gpu-worker-macos-apple-silicon.sh on the other Mac first."
    echo "Both Macs must be on the same Bonjour/mDNS-capable LAN."
    exit 1
}

echo "Found worker service(s):"
printf '%s\n' "$SERVICE_NAMES" | sed 's/^/  - /'
echo

# Resolve each Bonjour service to host + port.
RPC_ENDPOINTS=""
while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    RESOLVE_LOG="$(mktemp -t llama-rpc-resolve.XXXXXX)"

    dns-sd -L "$svc" "$SERVICE_TYPE" local >"$RESOLVE_LOG" 2>&1 &
    RESOLVE_PID=$!
    sleep 2
    kill "$RESOLVE_PID" >/dev/null 2>&1 || true
    wait "$RESOLVE_PID" >/dev/null 2>&1 || true

    # Typical dns-sd line:
    # <instance>._llamacpp-rpc._tcp.local. can be reached at host.local.:50052 (...)
    TARGET="$(
        awk '
          /can be reached at/ {
              for (i=1; i<=NF; i++) {
                  if ($i == "at" && (i+1) <= NF) {
                      x=$(i+1)
                      sub(/\.$/, "", x)
                      print x
                      exit
                  }
              }
          }
        ' "$RESOLVE_LOG"
    )"

    rm -f "$RESOLVE_LOG"

    if [[ -n "$TARGET" ]]; then
        # TARGET is usually host.local.:port or host.local:port.
        TARGET="${TARGET%.}"
        TARGET="${TARGET/.:/:}"
        TARGET_HOST="${TARGET%:*}"
        TARGET_PORT="${TARGET##*:}"
        TARGET_IP="$(resolve_ipv4 "$TARGET_HOST" || true)"
        ENDPOINT_HOST="${TARGET_IP:-$TARGET_HOST}"
        ENDPOINT="$ENDPOINT_HOST:$TARGET_PORT"

        echo "Resolved $svc -> $TARGET"
        if [[ -n "$TARGET_IP" && "$TARGET_IP" != "$TARGET_HOST" ]]; then
            echo "Using reachable IPv4 endpoint: $ENDPOINT"
        fi

        echo "Checking RPC TCP connection to $ENDPOINT..."
        if wait_for_tcp "$ENDPOINT_HOST" "$TARGET_PORT" "$ENDPOINT"; then
            if [[ -z "$RPC_ENDPOINTS" ]]; then
                RPC_ENDPOINTS="$ENDPOINT"
            else
                RPC_ENDPOINTS="$RPC_ENDPOINTS,$ENDPOINT"
            fi
        else
            echo "WARNING: $ENDPOINT was discovered by Bonjour but did not accept TCP connections on port $TARGET_PORT. Skipping it."
        fi
    fi
done <<< "$SERVICE_NAMES"

[[ -n "$RPC_ENDPOINTS" ]] || die "Worker(s) were visible in Bonjour but no reachable RPC TCP endpoint was found."

echo
echo "RPC worker(s): $RPC_ENDPOINTS"
RPC_COUNT="$(awk -v endpoints="$RPC_ENDPOINTS" 'BEGIN { print split(endpoints, parts, ",") }')"
DEVICE_LIST="MTL0"
RPC_INDEX=0
while [[ "$RPC_INDEX" -lt "$RPC_COUNT" ]]; do
    DEVICE_LIST="$DEVICE_LIST,RPC$RPC_INDEX"
    RPC_INDEX=$((RPC_INDEX + 1))
done
echo "llama.cpp device list: $DEVICE_LIST"
echo

# ----- Clone/update -----
echo "[2/5] Preparing llama.cpp"
if [[ -d "$LLAMA_DIR/.git" ]]; then
    git -C "$LLAMA_DIR" pull --ff-only
else
    git clone "$REPO" "$LLAMA_DIR"
fi

# ----- Build -----
echo
echo "[3/5] Building Metal + RPC"
cd "$LLAMA_DIR"

cmake -S . -B build \
    -DGGML_RPC=ON \
    -DGGML_METAL=ON \
    -DCMAKE_BUILD_TYPE=Release

cmake --build build --config Release -j "$(sysctl -n hw.logicalcpu)"

SERVER_EXE="$LLAMA_DIR/build/bin/llama-server"
CLI_EXE="$LLAMA_DIR/build/bin/llama-cli"

[[ -x "$SERVER_EXE" ]] || die "llama-server was not found after build."
[[ -x "$CLI_EXE" ]] || die "llama-cli was not found after build."

# ----- Model -----
echo
echo "[4/5] Checking model"
if [[ -z "$MODEL" ]]; then
    echo
    echo "No GGUF model path was supplied."
    echo "Example:"
    echo "  ./start-distributed-model-macos-apple-silicon.sh /Users/$USER/Models/model.gguf"
    exit 1
fi

[[ -f "$MODEL" ]] || die "Model file not found: $MODEL"

MODEL_SIZE_BYTES="$(stat -f%z "$MODEL")"
MODEL_SIZE_GIB="$(awk -v b="$MODEL_SIZE_BYTES" 'BEGIN { printf "%.2f", b/1024/1024/1024 }')"

echo "Model     : $MODEL"
MODEL_ALIAS="${MODEL_ALIAS:-$(model_alias_from_path "$MODEL")}"
echo "Model name: $MODEL_ALIAS"
echo "GGUF size : ${MODEL_SIZE_GIB} GiB"
echo "Context   : $CONTEXT"
echo

# ----- Run -----
echo "[5/5] Starting distributed inference"
echo
echo "Allocation is automatic:"
echo "  local Metal GPU + discovered RPC Metal GPU(s)"
echo "  llama.cpp splits layers/KV according to available device memory."
echo
echo "Using --load-mode none to avoid the current Metal+RPC mmap"
echo "memory-retention issue when splitting models across Macs."
echo

COMMON_ARGS=(
    -m "$MODEL"
    --rpc "$RPC_ENDPOINTS"
    --device "$DEVICE_LIST"
    --gpu-layers auto
    --split-mode layer
    --ctx-size "$CONTEXT"
    --fit on
    --load-mode none
)

if [[ "$MODE" == "cli" ]]; then
    exec "$CLI_EXE" "${COMMON_ARGS[@]}"
else
    echo "llama-server: http://${SERVER_HOST}:${SERVER_PORT}"
    echo
    exec "$SERVER_EXE" \
        "${COMMON_ARGS[@]}" \
        --alias "$MODEL_ALIAS" \
        --cors-origins localhost \
        --host "$SERVER_HOST" \
        --port "$SERVER_PORT"
fi
