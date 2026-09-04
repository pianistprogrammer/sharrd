#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# llama.cpp AUTO-DISCOVERY MAIN/JOINER for Windows + Git Bash
#
# What it does:
#   - Detects local NVIDIA GPU(s)/VRAM automatically.
#   - Discovers RPC worker(s) by UDP broadcast.
#   - Builds llama.cpp with CUDA + RPC.
#   - Lets llama.cpp automatically split according to free VRAM.
#   - Starts llama-server (or llama-cli for testing).
#
# No worker IP or GPU size needs to be entered.
# ============================================================

LLAMA_DIR="${LLAMA_DIR:-/c/llama.cpp}"
DISCOVERY_PORT="${DISCOVERY_PORT:-50053}"
DISCOVERY_SECONDS="${DISCOVERY_SECONDS:-3}"

# MODEL is the only normal setting you need to provide.
MODEL="${MODEL:-/c/models/model.gguf}"

CONTEXT="${CONTEXT:-4096}"
SERVER_PORT="${SERVER_PORT:-8080}"
SERVER_BIND="${SERVER_BIND:-0.0.0.0}"
MODE="${MODE:-server}"          # server or cli
USE_ALL_WORKERS="${USE_ALL_WORKERS:-1}"

REPO="https://github.com/ggml-org/llama.cpp.git"

echo "============================================================"
echo " llama.cpp MAIN/JOINER - automatic worker + VRAM discovery"
echo "============================================================"
echo

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

    if powershell.exe -NoProfile -Command "if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) { exit 1 }"; then
        return 0
    fi

    echo "ERROR: Server port $port is already in use on this machine. Stop the existing llama-server or choose a different port."
    exit 1
}

need_cmd git
need_cmd cmake
need_cmd powershell.exe
need_cmd nvidia-smi
need_cmd nvcc
need_cmd cygpath

echo "[1/6] Detecting local NVIDIA GPU(s)"
LOCAL_GPU="$(nvidia-smi --query-gpu=index,name,memory.total,memory.free,driver_version --format=csv,noheader || true)"
if [[ -z "$LOCAL_GPU" ]]; then
    echo "ERROR: No local NVIDIA GPU detected."
    exit 1
fi
echo "$LOCAL_GPU"
echo

echo "[2/6] Discovering llama.cpp RPC workers on the local subnet"

DISCOVERY_PS1="$LLAMA_DIR/.llama-rpc-discovery-client.ps1"
mkdir -p "$LLAMA_DIR"

cat > "$DISCOVERY_PS1" <<'POWERSHELL'
param(
    [int]$DiscoveryPort = 50053,
    [int]$Seconds = 3
)

$ErrorActionPreference = "Stop"
$magic = "LLAMA_CPP_RPC_DISCOVER_V1"

$udp = New-Object System.Net.Sockets.UdpClient
$udp.EnableBroadcast = $true
$udp.Client.ReceiveTimeout = 300

$payload = [System.Text.Encoding]::UTF8.GetBytes($magic)

# Limited broadcast works on the common same-subnet office LAN case.
[void]$udp.Send(
    $payload,
    $payload.Length,
    [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Broadcast, $DiscoveryPort)
)

# Send a few times to make discovery less sensitive to packet loss.
Start-Sleep -Milliseconds 150
[void]$udp.Send(
    $payload,
    $payload.Length,
    [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Broadcast, $DiscoveryPort)
)

$end = [DateTime]::UtcNow.AddSeconds($Seconds)
$seen = @{}

while ([DateTime]::UtcNow -lt $end) {
    try {
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $bytes = $udp.Receive([ref]$remote)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)

        if ($text.StartsWith("LLAMA_CPP_RPC_V1|")) {
            $parts = $text.Split("|", 4)
            if ($parts.Count -ge 4) {
                $ip = $remote.Address.ToString()
                $hostName = $parts[1]
                $rpcPort = $parts[2]
                $gpu = $parts[3]
                $key = "$ip`:$rpcPort"
                $seen[$key] = "$key`t$hostName`t$gpu"
            }
        }
    }
    catch [System.Net.Sockets.SocketException] {
        # Receive timeout: keep collecting until the overall deadline.
    }
}

$udp.Close()

$seen.Keys | Sort-Object | ForEach-Object {
    $seen[$_]
}
POWERSHELL

DISCOVERY_WIN="$(cygpath -w "$DISCOVERY_PS1")"

DISCOVERED="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$DISCOVERY_WIN" \
  -DiscoveryPort "$DISCOVERY_PORT" -Seconds "$DISCOVERY_SECONDS" | tr -d '\r' || true)"

if [[ -z "$DISCOVERED" ]]; then
    echo
    echo "ERROR: No RPC worker answered automatic discovery."
    echo
    echo "Check that:"
    echo "  1. share-gpu-worker-windows-nvidia.sh is running on the other PC,"
    echo "  2. both PCs are on the same LAN/VLAN,"
    echo "  3. Windows Firewall considers them part of LocalSubnet,"
    echo "  4. your network does not block local UDP broadcast."
    echo
    echo "You may override discovery manually as a fallback:"
    echo '  RPC_SERVERS=192.168.1.11:50052 ./start-distributed-model-windows-nvidia.sh'
    exit 1
fi

echo "$DISCOVERED" | while IFS=$'\t' read -r endpoint hostname gpu; do
    echo "Found: $hostname at $endpoint"
    echo "       GPU: $gpu"
done
echo

if [[ -n "${RPC_SERVERS:-}" ]]; then
    RPC_LIST="$RPC_SERVERS"
else
    mapfile -t ENDPOINTS < <(printf '%s\n' "$DISCOVERED" | awk -F $'\t' '{print $1}')
    if [[ "$USE_ALL_WORKERS" == "1" ]]; then
        RPC_LIST="$(IFS=,; echo "${ENDPOINTS[*]}")"
    else
        RPC_LIST="${ENDPOINTS[0]}"
    fi
fi

echo "Using RPC endpoint(s): $RPC_LIST"
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
    -G "Visual Studio 17 2022" \
    -A x64 \
    -DGGML_CUDA=ON \
    -DGGML_RPC=ON

cmake --build build --config Release -j

find_exe() {
    local name="$1"
    local p
    for p in \
        "$LLAMA_DIR/build/bin/Release/$name.exe" \
        "$LLAMA_DIR/build/bin/$name.exe" \
        "$LLAMA_DIR/build/Release/$name.exe"; do
        [[ -f "$p" ]] && { printf '%s\n' "$p"; return 0; }
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
    echo
    echo "Run with your model path, e.g.:"
    echo '  MODEL=/d/models/model.gguf ./start-distributed-model-windows-nvidia.sh'
    exit 1
fi

echo "[6/6] Starting distributed inference"
echo
echo "IMPORTANT:"
echo "  No --tensor-split is specified."
echo "  llama.cpp will automatically allocate layers/KV across local"
echo "  and RPC GPUs according to AVAILABLE device memory."
echo "  --fit is left enabled (the default) so runtime settings can"
echo "  be adjusted to fit device memory."
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
    echo "Server bind: $SERVER_BIND:$SERVER_PORT"
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
