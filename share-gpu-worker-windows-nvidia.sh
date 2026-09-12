#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# llama.cpp RPC AUTO-DISCOVERY WORKER for Windows + Git Bash
#
# What it does:
#   - Detects NVIDIA GPU(s) and VRAM automatically.
#   - Builds llama.cpp with CUDA + RPC.
#   - Opens RPC TCP + discovery UDP only to LocalSubnet.
#   - Starts a tiny UDP discovery responder.
#   - Starts the llama.cpp RPC server.
#
# No IP address or GPU size needs to be entered.
#
# Requirements:
#   NVIDIA driver, CUDA Toolkit, Git for Windows, CMake,
#   Visual Studio 2022 / Build Tools with Desktop C++ workload.
# ============================================================

LLAMA_DIR="${LLAMA_DIR:-/c/llama.cpp}"
RPC_PORT="${RPC_PORT:-50052}"
DISCOVERY_PORT="${DISCOVERY_PORT:-50053}"
USE_CACHE="${USE_CACHE:-1}"
SCAN_SUBNETS="${SCAN_SUBNETS:-}"

REPO="https://github.com/ggml-org/llama.cpp.git"
DISCOVERY_MAGIC="LLAMA_CPP_RPC_DISCOVER_V1"

echo "============================================================"
echo " llama.cpp RPC WORKER - automatic LAN/GPU discovery"
echo "============================================================"
echo

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: '$1' is not available in PATH."
        exit 1
    fi
}

need_cmd git
need_cmd cmake
need_cmd powershell.exe
need_cmd nvidia-smi
need_cmd nvcc
need_cmd cygpath

echo "[1/6] Detecting NVIDIA GPU(s)"
GPU_INFO="$(nvidia-smi --query-gpu=index,name,memory.total,memory.free,driver_version --format=csv,noheader || true)"
if [[ -z "$GPU_INFO" ]]; then
    echo "ERROR: No NVIDIA GPU detected by nvidia-smi."
    exit 1
fi
echo "$GPU_INFO"
echo

echo "[2/6] Detecting this PC's active LAN address"
LAN_INFO="$(powershell.exe -NoProfile -Command \
  '$x=Get-NetIPConfiguration | Where-Object {$_.IPv4DefaultGateway -and $_.IPv4Address} | Select-Object -First 1; if($x){$x.IPv4Address.IPAddress}' \
  | tr -d '\r')"
if [[ -n "$LAN_INFO" ]]; then
    echo "LAN IPv4: $LAN_INFO"
else
    echo "LAN IPv4 could not be uniquely identified; RPC will still bind to all interfaces."
fi
echo

echo "[3/6] Cloning/updating llama.cpp"
if [[ -d "$LLAMA_DIR/.git" ]]; then
    git -C "$LLAMA_DIR" pull --ff-only
else
    mkdir -p "$(dirname "$LLAMA_DIR")"
    git clone "$REPO" "$LLAMA_DIR"
fi

cd "$LLAMA_DIR"

echo "[4/6] Building CUDA + RPC"
# Explicit VS generator lets this work from normal Git Bash.
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

# Support both current/older output names.
RPC_EXE="$(find_exe rpc-server || true)"
if [[ -z "$RPC_EXE" ]]; then
    RPC_EXE="$(find_exe ggml-rpc-server || true)"
fi
if [[ -z "$RPC_EXE" ]]; then
    echo "ERROR: RPC server executable was not found under $LLAMA_DIR/build."
    exit 1
fi

echo
FIREWALL_REMOTE_ADDRESSES="LocalSubnet"
if [[ -n "$SCAN_SUBNETS" ]]; then
    while IFS= read -r subnet; do
        subnet="$(printf '%s' "$subnet" | tr -d '[:space:]')"
        [[ -n "$subnet" ]] || continue
        if [[ ! "$subnet" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/(23|24)$ ]]; then
            echo "ERROR: Allowed host subnet '$subnet' must be an IPv4 /23 or /24 network."
            exit 1
        fi
        for octet in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
            if (( 10#$octet > 255 )); then
                echo "ERROR: Allowed host subnet '$subnet' is not valid IPv4."
                exit 1
            fi
        done
        FIREWALL_REMOTE_ADDRESSES+=",$subnet"
    done < <(printf '%s' "$SCAN_SUBNETS" | tr ',' '\n')
fi

echo "[5/6] Configuring Windows Firewall for: $FIREWALL_REMOTE_ADDRESSES"
RULE_RPC="llama.cpp RPC TCP ${RPC_PORT}"
RULE_DISC="llama.cpp Discovery UDP ${DISCOVERY_PORT}"
FW_CMD="\$ErrorActionPreference='Stop'; \
Get-NetFirewallRule -DisplayName '${RULE_RPC}' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue; \
Get-NetFirewallRule -DisplayName '${RULE_DISC}' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue; \
New-NetFirewallRule -DisplayName '${RULE_RPC}' -Direction Inbound -Protocol TCP -LocalPort ${RPC_PORT} -RemoteAddress ${FIREWALL_REMOTE_ADDRESSES} -Action Allow | Out-Null; \
New-NetFirewallRule -DisplayName '${RULE_DISC}' -Direction Inbound -Protocol UDP -LocalPort ${DISCOVERY_PORT} -RemoteAddress ${FIREWALL_REMOTE_ADDRESSES} -Action Allow | Out-Null"

powershell.exe -NoProfile -Command \
  "Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile','-Command',\"$FW_CMD\""

echo "[6/6] Starting automatic discovery responder + RPC worker"

DISCOVERY_PS1="$LLAMA_DIR/.llama-rpc-discovery-worker.ps1"
cat > "$DISCOVERY_PS1" <<'POWERSHELL'
param(
    [int]$DiscoveryPort = 50053,
    [int]$RpcPort = 50052
)

$ErrorActionPreference = "Stop"
$magic = "LLAMA_CPP_RPC_DISCOVER_V1"
$udp = New-Object System.Net.Sockets.UdpClient($DiscoveryPort)
$udp.EnableBroadcast = $true

try {
    while ($true) {
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $data = $udp.Receive([ref]$remote)
        $msg = [System.Text.Encoding]::UTF8.GetString($data)

        if ($msg -eq $magic) {
            $gpu = (& nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits 2>$null) -join "; "
            $hostName = $env:COMPUTERNAME
            $replyText = "LLAMA_CPP_RPC_V1|$hostName|$RpcPort|$gpu"
            $reply = [System.Text.Encoding]::UTF8.GetBytes($replyText)
            [void]$udp.Send($reply, $reply.Length, $remote.Address, $remote.Port)
        }
    }
}
finally {
    $udp.Close()
}
POWERSHELL

DISCOVERY_WIN="$(cygpath -w "$DISCOVERY_PS1")"

# Only start a responder if this port is not already owned.
DISCOVERY_BUSY="$(powershell.exe -NoProfile -Command \
  "if(Get-NetUDPEndpoint -LocalPort ${DISCOVERY_PORT} -ErrorAction SilentlyContinue){'yes'}else{'no'}" \
  | tr -d '\r')"

if [[ "$DISCOVERY_BUSY" != "yes" ]]; then
    powershell.exe -NoProfile -WindowStyle Hidden -Command \
      "Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','${DISCOVERY_WIN}','-DiscoveryPort','${DISCOVERY_PORT}','-RpcPort','${RPC_PORT}'" >/dev/null
    sleep 1
else
    echo "Discovery UDP port $DISCOVERY_PORT is already active; reusing the existing responder."
fi

echo
echo "Worker ready."
echo "  Host/IP       : ${LAN_INFO:-automatic}"
echo "  RPC port      : $RPC_PORT/TCP"
echo "  Discovery port: $DISCOVERY_PORT/UDP"
echo
echo "Detected GPU capacity:"
echo "$GPU_INFO"
echo
echo "The MAIN/JOINER script can now find this PC automatically."
echo "Keep this terminal open."
echo "RPC is restricted to your Windows LocalSubnet; do not expose it to the Internet."
echo

ARGS=(--host 0.0.0.0 --port "$RPC_PORT")
if [[ "$USE_CACHE" == "1" ]]; then
    ARGS+=(-c)
fi

exec "$RPC_EXE" "${ARGS[@]}"
