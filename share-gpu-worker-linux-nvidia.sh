#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# share-gpu-worker-linux-nvidia.sh
# Linux / NVIDIA CUDA
#
# Run this on a machine that will CONTRIBUTE its NVIDIA GPU.
# It:
#   - detects NVIDIA GPU(s)
#   - builds llama.cpp with CUDA + RPC
#   - starts a tiny UDP discovery responder
#   - starts the llama.cpp RPC server
# ============================================================

export PATH="/usr/local/cuda/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
RPC_PORT="${RPC_PORT:-50052}"
DISCOVERY_PORT="${DISCOVERY_PORT:-50053}"
USE_CACHE="${USE_CACHE:-1}"
REPO="https://github.com/ggml-org/llama.cpp.git"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: '$1' is not available in PATH."
        exit 1
    fi
}

echo "============================================================"
echo " llama.cpp RPC WORKER - Linux CUDA"
echo "============================================================"
echo

need_cmd git
need_cmd cmake
need_cmd nvidia-smi
need_cmd nvcc
need_cmd python3

echo "[1/5] Detecting NVIDIA GPU(s)"
GPU_INFO="$(nvidia-smi --query-gpu=index,name,memory.total,memory.free,driver_version --format=csv,noheader || true)"
if [[ -z "$GPU_INFO" ]]; then
    echo "ERROR: No NVIDIA GPU detected by nvidia-smi."
    exit 1
fi
echo "$GPU_INFO"
echo

LAN_INFO="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)"
echo "LAN IPv4: ${LAN_INFO:-automatic}"
echo

echo "[2/5] Cloning/updating llama.cpp"
if [[ -d "$LLAMA_DIR/.git" ]]; then
    git -C "$LLAMA_DIR" pull --ff-only
else
    git clone "$REPO" "$LLAMA_DIR"
fi

cd "$LLAMA_DIR"

echo "[3/5] Building CUDA + RPC"
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

RPC_EXE="$(find_exe rpc-server || true)"
if [[ -z "$RPC_EXE" ]]; then
    RPC_EXE="$(find_exe ggml-rpc-server || true)"
fi
if [[ -z "$RPC_EXE" ]]; then
    echo "ERROR: RPC server executable was not found under $LLAMA_DIR/build."
    exit 1
fi

echo "[4/5] Starting automatic discovery responder"
python3 - "$DISCOVERY_PORT" "$RPC_PORT" <<'PY' &
import socket
import subprocess
import sys

discovery_port = int(sys.argv[1])
rpc_port = int(sys.argv[2])
magic = "LLAMA_CPP_RPC_DISCOVER_V1"

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
sock.bind(("0.0.0.0", discovery_port))

while True:
    data, addr = sock.recvfrom(4096)
    if data.decode("utf-8", "replace") != magic:
        continue
    try:
        gpu = subprocess.check_output([
            "nvidia-smi",
            "--query-gpu=name,memory.total,memory.free",
            "--format=csv,noheader,nounits",
        ], stderr=subprocess.DEVNULL, text=True).strip().replace("\n", "; ")
    except Exception:
        gpu = "NVIDIA GPU"
    host = socket.gethostname()
    reply = f"LLAMA_CPP_RPC_V1|{host}|{rpc_port}|{gpu}".encode()
    sock.sendto(reply, addr)
PY
DISCOVERY_PID=$!

cleanup() {
    kill "$DISCOVERY_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo
echo "[5/5] Starting RPC worker"
echo "Host/IP       : ${LAN_INFO:-automatic}"
echo "RPC port      : $RPC_PORT/TCP"
echo "Discovery port: $DISCOVERY_PORT/UDP"
echo
echo "Use only on a trusted LAN. Do NOT expose the RPC port to the Internet."
echo

ARGS=(--host 0.0.0.0 --port "$RPC_PORT")
if [[ "$USE_CACHE" == "1" ]]; then
    ARGS+=(-c)
fi

exec "$RPC_EXE" "${ARGS[@]}"
