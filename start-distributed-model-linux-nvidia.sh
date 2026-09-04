#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# start-distributed-model-linux-nvidia.sh
# Linux / NVIDIA CUDA
#
# Run this on the machine that will START the distributed model.
# It:
#   - detects local NVIDIA GPU(s)
#   - discovers RPC workers by UDP broadcast
#   - builds llama.cpp with CUDA + RPC
#   - lets llama.cpp split layers across local and remote GPUs
#   - starts llama-server or llama-cli
# ============================================================

export PATH="/usr/local/cuda/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
DISCOVERY_PORT="${DISCOVERY_PORT:-50053}"
DISCOVERY_SECONDS="${DISCOVERY_SECONDS:-3}"
MODEL="${MODEL:-$HOME/models/model.gguf}"
CONTEXT="${CONTEXT:-4096}"
SERVER_PORT="${SERVER_PORT:-8080}"
SERVER_BIND="${SERVER_BIND:-0.0.0.0}"
MODE="${MODE:-server}"
USE_ALL_WORKERS="${USE_ALL_WORKERS:-1}"
REPO="https://github.com/ggml-org/llama.cpp.git"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: '$1' is not available in PATH."
        exit 1
    fi
}

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

ensure_server_port_free() {
    local port="$1"

    if command -v ss >/dev/null 2>&1 && ss -ltn "sport = :$port" | grep -q LISTEN; then
        echo "ERROR: Server port $port is already in use on this machine. Stop the existing llama-server or choose a different port."
        exit 1
    fi

    if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "ERROR: Server port $port is already in use on this machine. Stop the existing llama-server or choose a different port."
        exit 1
    fi
}

echo "============================================================"
echo " llama.cpp MAIN/JOINER - Linux CUDA + RPC"
echo "============================================================"
echo

need_cmd git
need_cmd cmake
need_cmd nvidia-smi
need_cmd nvcc
need_cmd python3

echo "[1/6] Detecting local NVIDIA GPU(s)"
LOCAL_GPU="$(nvidia-smi --query-gpu=index,name,memory.total,memory.free,driver_version --format=csv,noheader || true)"
if [[ -z "$LOCAL_GPU" ]]; then
    echo "ERROR: No local NVIDIA GPU detected."
    exit 1
fi
echo "$LOCAL_GPU"
echo

echo "[2/6] Discovering llama.cpp RPC workers on the local subnet"
if [[ -n "${RPC_SERVERS:-}" ]]; then
    RPC_LIST="$RPC_SERVERS"
    echo "Using manual RPC endpoint(s): $RPC_LIST"
else
    DISCOVERED="$(python3 - "$DISCOVERY_PORT" "$DISCOVERY_SECONDS" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
seconds = float(sys.argv[2])
magic = b"LLAMA_CPP_RPC_DISCOVER_V1"
seen = {}

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
sock.settimeout(0.3)

for _ in range(2):
    sock.sendto(magic, ("255.255.255.255", port))
    time.sleep(0.15)

end = time.time() + seconds
while time.time() < end:
    try:
        data, addr = sock.recvfrom(4096)
    except socket.timeout:
        continue
    text = data.decode("utf-8", "replace")
    if text.startswith("LLAMA_CPP_RPC_V1|"):
        parts = text.split("|", 3)
        if len(parts) == 4:
            key = f"{addr[0]}:{parts[2]}"
            seen[key] = f"{key}\t{parts[1]}\t{parts[3]}"

for key in sorted(seen):
    print(seen[key])
PY
)"

    if [[ -z "$DISCOVERED" ]]; then
        echo
        echo "ERROR: No RPC worker answered automatic discovery."
        echo "Start a worker first, confirm both machines are on the same LAN, or set RPC_SERVERS manually."
        exit 1
    fi

    echo "$DISCOVERED" | while IFS=$'\t' read -r endpoint hostname gpu; do
        echo "Found: $hostname at $endpoint"
        echo "       GPU: $gpu"
    done
    echo

    mapfile -t ENDPOINTS < <(printf '%s\n' "$DISCOVERED" | awk -F $'\t' '{print $1}')
    if [[ "$USE_ALL_WORKERS" == "1" ]]; then
        RPC_LIST="$(IFS=,; echo "${ENDPOINTS[*]}")"
    else
        RPC_LIST="${ENDPOINTS[0]}"
    fi
fi
echo

echo "[3/6] Cloning/updating llama.cpp"
if [[ -d "$LLAMA_DIR/.git" ]]; then
    git -C "$LLAMA_DIR" pull --ff-only
else
    git clone "$REPO" "$LLAMA_DIR"
fi

cd "$LLAMA_DIR"

echo "[4/6] Building CUDA + RPC"
cmake -S . -B build \
    -DGGML_CUDA=ON \
    -DGGML_RPC=ON \
    -DCMAKE_BUILD_TYPE=Release

cmake --build build --config Release -j "$(nproc)"

find_exe() {
    local name="$1"
    local p
    for p in \
        "$LLAMA_DIR/build/bin/$name" \
        "$LLAMA_DIR/build/$name"; do
        [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

if [[ "$MODE" == "cli" ]]; then
    APP="$(find_exe llama-cli || true)"
else
    APP="$(find_exe llama-server || true)"
fi

if [[ -z "$APP" ]]; then
    echo "ERROR: llama.cpp application executable was not found."
    exit 1
fi

echo "[5/6] Checking model"
if [[ ! -f "$MODEL" ]]; then
    echo
    echo "ERROR: GGUF model not found at:"
    echo "  $MODEL"
    exit 1
fi

echo "[6/6] Starting distributed inference"
echo "Using RPC endpoint(s): $RPC_LIST"
echo
MODEL_ALIAS="${MODEL_ALIAS:-$(model_alias_from_path "$MODEL")}"
echo "Model name: $MODEL_ALIAS"
echo

COMMON_ARGS=(
    -m "$MODEL"
    --rpc "$RPC_LIST"
    --split-mode layer
    --gpu-layers auto
    --ctx-size "$CONTEXT"
    --fit on
)

if [[ "$MODE" == "cli" ]]; then
    exec "$APP" "${COMMON_ARGS[@]}"
else
    ensure_server_port_free "$SERVER_PORT"
    echo "llama-server: http://${SERVER_BIND}:${SERVER_PORT}"
    echo
    exec "$APP" \
        "${COMMON_ARGS[@]}" \
        --alias "$MODEL_ALIAS" \
        --cors-origins localhost \
        --host "$SERVER_BIND" \
        --port "$SERVER_PORT"
fi
