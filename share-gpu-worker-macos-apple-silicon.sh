#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# share-gpu-worker-macos-apple-silicon.sh
# macOS / Apple Silicon only
#
# Run this on the Mac that will CONTRIBUTE its Metal GPU.
# It:
#   - checks Apple Silicon + GPU/memory
#   - installs build dependencies with Homebrew if needed
#   - builds llama.cpp with Metal + RPC
#   - starts llama.cpp RPC on TCP 50052
#   - advertises itself on Bonjour/mDNS so the main Mac
#     can discover it without knowing the IP address
#
# Keep this terminal open while the other Mac is using it.
# ============================================================

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/Library/Apple/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

RPC_PORT="${RPC_PORT:-50052}"
DISCOVERY_PORT="${DISCOVERY_PORT:-50053}"
DISCOVERY_MAGIC="LLAMA_CPP_RPC_DISCOVER_V1"
LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
SERVICE_TYPE="_llamacpp-rpc._tcp"
SERVICE_NAME="${SERVICE_NAME:-llama-rpc-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
REPO="https://github.com/ggml-org/llama.cpp.git"
USE_CACHE="${USE_CACHE:-1}"

die() { echo "ERROR: $*" >&2; exit 1; }

primary_ipv4() {
    local iface=""
    local ip=""

    iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}' || true)"
    if [[ -n "$iface" ]]; then
        ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    fi

    if [[ -z "$ip" ]]; then
        ip="$(ifconfig 2>/dev/null | awk '
            /inet / && $2 != "127.0.0.1" {
                print $2
                exit
            }
        ' || true)"
    fi

    printf '%s\n' "$ip"
}

all_ipv4s() {
    ifconfig 2>/dev/null | awk '
        /inet / && $2 != "127.0.0.1" {
            print $2
        }
    ' | sort -u
}

ensure_rpc_port_free() {
    if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$RPC_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        die "RPC port $RPC_PORT is already in use on this Mac. Stop the existing worker or set RPC_PORT to another port."
    fi
}

[[ "$(uname -s)" == "Darwin" ]] || die "This script is macOS-only."
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon (arm64) is required."

echo "============================================================"
echo " llama.cpp — SHARE MY MAC GPU"
echo "============================================================"
echo

CHIP="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip:/{print $2; exit}')"
MEM_BYTES="$(sysctl -n hw.memsize)"
MEM_GIB=$(( MEM_BYTES / 1024 / 1024 / 1024 ))
HOSTNAME_LOCAL="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
PRIMARY_IP="$(primary_ipv4)"
ALL_IPS="$(all_ipv4s)"

echo "Mac        : ${HOSTNAME_LOCAL}"
echo "Chip       : ${CHIP:-Apple Silicon}"
echo "Unified RAM: ${MEM_GIB} GiB"
echo "RPC port   : ${RPC_PORT}"
echo "Discovery  : UDP ${DISCOVERY_PORT}"
if [[ -n "$PRIMARY_IP" ]]; then
    echo "Primary IP : ${PRIMARY_IP}"
fi
echo

# ----- Dependencies -----
if ! command -v xcode-select >/dev/null 2>&1; then
    die "xcode-select is unavailable."
fi

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are required."
    echo "Run: xcode-select --install"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    die "git is required. Install Xcode Command Line Tools."
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

command -v dns-sd >/dev/null 2>&1 || die "dns-sd (Bonjour) is required on macOS."

# ----- Clone/update -----
echo
echo "[1/4] Preparing llama.cpp"
if [[ -d "$LLAMA_DIR/.git" ]]; then
    git -C "$LLAMA_DIR" pull --ff-only
else
    git clone "$REPO" "$LLAMA_DIR"
fi

# ----- Build -----
echo
echo "[2/4] Building Metal + RPC"
cd "$LLAMA_DIR"

cmake -S . -B build \
    -DGGML_RPC=ON \
    -DGGML_METAL=ON \
    -DCMAKE_BUILD_TYPE=Release

cmake --build build --config Release -j "$(sysctl -n hw.logicalcpu)"

RPC_EXE="$LLAMA_DIR/build/bin/ggml-rpc-server"
if [[ ! -x "$RPC_EXE" ]]; then
    RPC_EXE="$LLAMA_DIR/build/bin/rpc-server"
fi
[[ -x "$RPC_EXE" ]] || die "RPC server executable was not found after build."

ensure_rpc_port_free

# ----- Discovery responders -----
echo
echo "[3/4] Advertising this worker with Bonjour and UDP discovery"

DNS_LOG="$(mktemp -t llama-rpc-dnssd.XXXXXX)"
dns-sd -R "$SERVICE_NAME" "$SERVICE_TYPE" local "$RPC_PORT" \
    "chip=${CHIP:-Apple-Silicon}" \
    "ram_gib=${MEM_GIB}" \
    >"$DNS_LOG" 2>&1 &
DNS_PID=$!
DISCOVERY_PID=""
DISCOVERY_LOG="$(mktemp -t llama-rpc-udp-discovery.XXXXXX)"

cleanup() {
    kill "$DNS_PID" >/dev/null 2>&1 || true
    if [[ -n "$DISCOVERY_PID" ]]; then
        kill "$DISCOVERY_PID" >/dev/null 2>&1 || true
    fi
    rm -f "$DNS_LOG"
    rm -f "$DISCOVERY_LOG"
}
trap cleanup EXIT INT TERM

sleep 1
if ! kill -0 "$DNS_PID" >/dev/null 2>&1; then
    cat "$DNS_LOG" >&2 || true
    die "Bonjour service advertisement failed."
fi

if command -v python3 >/dev/null 2>&1; then
    python3 - "$DISCOVERY_PORT" "$RPC_PORT" "$DISCOVERY_MAGIC" "$HOSTNAME_LOCAL" "$CHIP" "$MEM_GIB" >"$DISCOVERY_LOG" 2>&1 <<'PY' &
import socket
import sys

discovery_port = int(sys.argv[1])
rpc_port = sys.argv[2]
magic = sys.argv[3].encode()
host_name = sys.argv[4]
chip = sys.argv[5] or "Apple Silicon"
ram_gib = sys.argv[6]

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("0.0.0.0", discovery_port))

metadata = f"chip={chip};ram_gib={ram_gib}"
reply = f"LLAMA_CPP_RPC_V1|{host_name}|{rpc_port}|{metadata}".encode()

while True:
    data, remote = sock.recvfrom(4096)
    if data == magic:
        sock.sendto(reply, remote)
PY
    DISCOVERY_PID=$!
    sleep 1
    if ! kill -0 "$DISCOVERY_PID" >/dev/null 2>&1; then
        echo "WARNING: UDP discovery responder did not start; Bonjour and manual RPC can still work." >&2
        cat "$DISCOVERY_LOG" >&2 || true
        DISCOVERY_PID=""
    fi
else
    echo "WARNING: python3 is unavailable; routed UDP discovery responder is disabled." >&2
fi

# ----- Start RPC -----
echo
echo "[4/4] Starting RPC worker"
echo
echo "This Mac is now sharing its Metal GPU."
echo "Bonjour service: $SERVICE_NAME.$SERVICE_TYPE.local"
echo "RPC endpoint   : 0.0.0.0:$RPC_PORT"
echo "Discovery UDP  : 0.0.0.0:$DISCOVERY_PORT"
echo
echo "macOS firewall: if a prompt asks whether to allow incoming connections"
echo "for ggml-rpc-server, rpc-server, python3, or Terminal, click Allow."
if [[ -n "$PRIMARY_IP" ]]; then
    echo
    echo "Manual connect fallback for the model starter:"
    echo "  RPC_SERVERS=${PRIMARY_IP}:${RPC_PORT} WORKER_RAM_GIBS=${MEM_GIB} ./start-distributed-model-macos-apple-silicon.sh /path/to/model.gguf"
fi
if [[ -n "$ALL_IPS" ]]; then
    echo
    echo "This Mac's non-loopback IPv4 address(es):"
    printf '%s\n' "$ALL_IPS" | sed 's/^/  - /'
fi
echo
echo "Keep this terminal open."
echo "Use only on a trusted LAN. Do NOT expose the RPC port to the Internet."
echo

ARGS=(--host 0.0.0.0 --port "$RPC_PORT" --device MTL0)
if [[ "$USE_CACHE" == "1" ]]; then
    ARGS+=(-c)
fi

exec "$RPC_EXE" "${ARGS[@]}"
