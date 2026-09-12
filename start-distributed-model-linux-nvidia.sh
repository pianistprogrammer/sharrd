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
#   - uses a VRAM-weighted split so larger GPUs carry more
#     of the model than smaller worker GPUs
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
SCAN_SUBNETS="${SCAN_SUBNETS:-}"
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

local_vram_split() {
    nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits \
        | awk '{ gsub(/[^0-9.]/, "", $1); if ($1 > 0) { if (out != "") out = out ","; out = out int($1) } } END { print out }'
}

worker_vram_mib_from_gpu() {
    printf '%s\n' "$1" | awk '
        BEGIN { total = 0 }
        {
            n = split($0, cards, ";")
            for (i = 1; i <= n; i++) {
                m = split(cards[i], fields, ",")
                if (m >= 3) {
                    value = fields[3]
                } else if (m >= 2) {
                    value = fields[2]
                } else {
                    value = 0
                }
                gsub(/[^0-9.]/, "", value)
                total += int(value)
            }
        }
        END { if (total > 0) print total }
    '
}

join_csv() {
    local IFS=,
    echo "$*"
}

print_split_percentages() {
    local split_spec="$1"
    local local_count="$2"

    awk -v split_spec="$split_spec" -v local_count="$local_count" '
        BEGIN {
            n = split(split_spec, parts, ",")
            total = 0
            for (i = 1; i <= n; i++) total += parts[i]
            if (total <= 0) exit
            for (i = 1; i <= n; i++) {
                if (i <= local_count) {
                    label = (local_count == 1) ? "Host" : "Host" i
                } else {
                    label = "Worker" (i - local_count)
                }
                printf "Split device %s: %.0f%%\n", label, (parts[i] / total) * 100
            }
        }
    '
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
LOCAL_VRAM_SPLIT="$(local_vram_split)"
LOCAL_GPU_COUNT="$(awk -F, 'NF { count++ } END { print count + 0 }' <<< "$LOCAL_GPU")"
if [[ -z "$LOCAL_VRAM_SPLIT" ]]; then
    LOCAL_VRAM_SPLIT="8192"
    LOCAL_GPU_COUNT="1"
fi
echo

echo "[2/6] Discovering llama.cpp RPC workers locally and on configured remote subnets"
if [[ -n "${RPC_SERVERS:-}" ]]; then
    RPC_LIST="$RPC_SERVERS"
    WORKER_VRAM_SPLIT=""
    echo "Using manual RPC endpoint(s): $RPC_LIST"
else
    DISCOVERED="$(python3 - "$DISCOVERY_PORT" "$DISCOVERY_SECONDS" "$SCAN_SUBNETS" <<'PY'
import ipaddress
import socket
import sys
import time

port = int(sys.argv[1])
seconds = float(sys.argv[2])
scan_subnets = sys.argv[3]
magic = b"LLAMA_CPP_RPC_DISCOVER_V1"
seen = {}
targets = ["255.255.255.255"]

for spec in scan_subnets.replace(" ", "").split(","):
    if not spec:
        continue
    try:
        network = ipaddress.ip_network(spec, strict=False)
    except ValueError as error:
        raise SystemExit(f"ERROR: Invalid remote subnet '{spec}': {error}")
    if network.version != 4 or network.prefixlen not in (23, 24):
        raise SystemExit(f"ERROR: Remote subnet '{spec}' must be an IPv4 /23 or /24 network")
    targets.extend(str(address) for address in network.hosts())

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
sock.settimeout(0.3)

for target in dict.fromkeys(targets):
    try:
        sock.sendto(magic, (target, port))
    except OSError:
        pass

time.sleep(0.15)
sock.sendto(magic, ("255.255.255.255", port))

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
        echo "Start a worker first, set SCAN_SUBNETS to remote /23 or /24 networks, or set RPC_SERVERS manually."
        exit 1
    fi

    ENDPOINTS=()
    WORKER_VRAMS=()
    while IFS=$'\t' read -r endpoint hostname gpu; do
        worker_vram="$(worker_vram_mib_from_gpu "$gpu")"
        [[ -n "$worker_vram" ]] || worker_vram="8192"
        ENDPOINTS+=("$endpoint")
        WORKER_VRAMS+=("$worker_vram")
        echo "Found: $hostname at $endpoint"
        echo "       GPU: $gpu"
        echo "       Free VRAM advertised: ${worker_vram} MiB"
    done <<< "$DISCOVERED"
    echo

    if [[ "$USE_ALL_WORKERS" == "1" ]]; then
        RPC_LIST="$(join_csv "${ENDPOINTS[@]}")"
        WORKER_VRAM_SPLIT="$(join_csv "${WORKER_VRAMS[@]}")"
    else
        RPC_LIST="${ENDPOINTS[0]}"
        WORKER_VRAM_SPLIT="${WORKER_VRAMS[0]}"
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
AUTO_TENSOR_SPLIT=""
if [[ -n "$LOCAL_VRAM_SPLIT" && -n "${WORKER_VRAM_SPLIT:-}" ]]; then
    AUTO_TENSOR_SPLIT="$LOCAL_VRAM_SPLIT,$WORKER_VRAM_SPLIT"
fi
TENSOR_SPLIT="${TENSOR_SPLIT:-$AUTO_TENSOR_SPLIT}"
if [[ -n "$TENSOR_SPLIT" ]]; then
    echo "llama.cpp tensor split: $TENSOR_SPLIT"
    print_split_percentages "$TENSOR_SPLIT" "$LOCAL_GPU_COUNT"
else
    echo "llama.cpp tensor split: automatic"
fi
echo

COMMON_ARGS=(
    -m "$MODEL"
    --rpc "$RPC_LIST"
    --split-mode layer
    --gpu-layers auto
    --ctx-size "$CONTEXT"
    --fit on
)

if [[ -n "$TENSOR_SPLIT" ]]; then
    COMMON_ARGS+=(--tensor-split "$TENSOR_SPLIT")
fi

if [[ "$MODE" == "cli" ]]; then
    exec "$APP" "${COMMON_ARGS[@]}"
else
    ensure_server_port_free "$SERVER_PORT"
    echo "llama-server: http://${SERVER_BIND}:${SERVER_PORT}"
    echo
    SERVER_ARGS=(
        "${COMMON_ARGS[@]}"
        --alias "$MODEL_ALIAS"
        --host "$SERVER_BIND"
        --port "$SERVER_PORT"
    )
    if [[ -n "${SERVER_CORS_ORIGINS:-}" ]]; then
        SERVER_ARGS+=(--cors-origins "$SERVER_CORS_ORIGINS")
    fi
    exec "$APP" "${SERVER_ARGS[@]}"
fi
