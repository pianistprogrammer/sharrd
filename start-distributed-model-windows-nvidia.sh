#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# llama.cpp AUTO-DISCOVERY MAIN/JOINER for Windows + Git Bash
#
# What it does:
#   - Detects local NVIDIA GPU(s)/VRAM automatically.
#   - Discovers RPC worker(s) by UDP broadcast.
#   - Builds llama.cpp with CUDA + RPC.
#   - Uses a VRAM-weighted split so larger GPUs carry more
#     of the model than smaller worker GPUs.
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
SCAN_SUBNETS="${SCAN_SUBNETS:-}"

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
LOCAL_VRAM_SPLIT="$(local_vram_split)"
LOCAL_GPU_COUNT="$(awk -F, 'NF { count++ } END { print count + 0 }' <<< "$LOCAL_GPU")"
if [[ -z "$LOCAL_VRAM_SPLIT" ]]; then
    LOCAL_VRAM_SPLIT="8192"
    LOCAL_GPU_COUNT="1"
fi
echo

echo "[2/6] Discovering llama.cpp RPC workers locally and on configured remote subnets"
WORKER_VRAM_SPLIT=""

if [[ -n "${RPC_SERVERS:-}" ]]; then
    RPC_LIST="$RPC_SERVERS"
    echo "Using manual RPC endpoint(s): $RPC_LIST"
else
    DISCOVERY_PS1="$LLAMA_DIR/.llama-rpc-discovery-client.ps1"
    mkdir -p "$LLAMA_DIR"

    cat > "$DISCOVERY_PS1" <<'POWERSHELL'
param(
    [int]$DiscoveryPort = 50053,
    [int]$Seconds = 3,
    [string]$ScanSubnets = ""
)

$ErrorActionPreference = "Stop"
$magic = "LLAMA_CPP_RPC_DISCOVER_V1"

$udp = New-Object System.Net.Sockets.UdpClient
$udp.EnableBroadcast = $true
$udp.Client.ReceiveTimeout = 300

$payload = [System.Text.Encoding]::UTF8.GetBytes($magic)
$targets = New-Object System.Collections.Generic.List[string]
$targets.Add([System.Net.IPAddress]::Broadcast.ToString())

foreach ($spec in $ScanSubnets.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries)) {
    $value = $spec.Trim()
    if ($value -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.\d{1,3}/(23|24)$') {
        throw "Remote subnet '$value' must be an IPv4 /23 or /24 network"
    }

    $a = [int]$Matches[1]
    $b = [int]$Matches[2]
    $c = [int]$Matches[3]
    $prefix = [int]$Matches[4]
    if ($a -gt 255 -or $b -gt 255 -or $c -gt 255) {
        throw "Remote subnet '$value' is not valid IPv4"
    }

    $firstThirdOctet = if ($prefix -eq 23) { $c -band 254 } else { $c }
    $lastThirdOctet = if ($prefix -eq 23) { $firstThirdOctet + 1 } else { $firstThirdOctet }
    foreach ($thirdOctet in $firstThirdOctet..$lastThirdOctet) {
        foreach ($hostOctet in 1..254) {
            $targets.Add("$a.$b.$thirdOctet.$hostOctet")
        }
    }
}

foreach ($target in ($targets | Select-Object -Unique)) {
    try {
        [void]$udp.Send($payload, $payload.Length, $target, $DiscoveryPort)
    }
    catch [System.Net.Sockets.SocketException] {
    }
}

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
      -DiscoveryPort "$DISCOVERY_PORT" -Seconds "$DISCOVERY_SECONDS" -ScanSubnets "$SCAN_SUBNETS" | tr -d '\r' || true)"

    if [[ -z "$DISCOVERED" ]]; then
        echo
        echo "ERROR: No RPC worker answered automatic discovery."
        echo
        echo "Check that:"
        echo "  1. share-gpu-worker-windows-nvidia.sh is running on the other PC,"
        echo "  2. SCAN_SUBNETS includes the worker's remote /23 or /24 network when needed,"
        echo "  3. Windows Firewall allows the host network,"
        echo "  4. routing permits UDP discovery and TCP RPC between subnets."
        echo
        echo "You may override discovery manually as a fallback:"
        echo '  RPC_SERVERS=192.168.1.11:50052 ./start-distributed-model-windows-nvidia.sh'
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
