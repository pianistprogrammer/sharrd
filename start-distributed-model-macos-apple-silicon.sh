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
#   - uses a memory-weighted split so larger Macs carry more
#     of the model than smaller worker Macs
#   - starts llama-server
#
# Model path can be passed as the first argument:
#   ./start-distributed-model-macos-apple-silicon.sh /Users/me/Models/model.gguf
#
# Or:
#   MODEL=/Users/me/Models/model.gguf ./start-distributed-model-macos-apple-silicon.sh
#
# If Bonjour/mDNS discovery is blocked by office subnetting, manually pass worker
# RPC endpoint(s):
#   RPC_SERVERS=<worker-ip>:50052 WORKER_RAM_GIBS=<worker-ram> ./start-distributed-model-macos-apple-silicon.sh /Users/me/Models/model.gguf
# Or let the script scan routed office subnets for the RPC port:
#   SCAN_SUBNETS=10.27.180.0/23 ./start-distributed-model-macos-apple-silicon.sh /Users/me/Models/model.gguf
# ============================================================

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/Library/Apple/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
SERVICE_TYPE="_llamacpp-rpc._tcp"
RPC_PORT="${RPC_PORT:-50052}"
DISCOVERY_PORT="${DISCOVERY_PORT:-50053}"
DISCOVERY_MAGIC="LLAMA_CPP_RPC_DISCOVER_V1"
REPO="https://github.com/ggml-org/llama.cpp.git"

MODEL="${1:-${MODEL:-}}"
CONTEXT="${CONTEXT:-8192}"
SERVER_HOST="${SERVER_HOST:-127.0.0.1}"
SERVER_PORT="${SERVER_PORT:-8080}"
DISCOVERY_SECONDS="${DISCOVERY_SECONDS:-4}"
MODE="${MODE:-server}"       # server or cli
RPC_SERVERS="${RPC_SERVERS:-}"
WORKER_RAM_GIBS="${WORKER_RAM_GIBS:-}"
SCAN_RPC_WORKERS="${SCAN_RPC_WORKERS:-1}"
SCAN_SUBNETS="${SCAN_SUBNETS:-}"

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

ensure_server_port_free() {
    local port="$1"

    if command -v nc >/dev/null 2>&1 && nc -z -G 1 127.0.0.1 "$port" >/dev/null 2>&1; then
        die "Server port $port is already in use on this Mac. Stop the existing llama-server or choose a different port."
    fi
}

server_display_host() {
    local bind="$1"

    if [[ -z "$bind" || "$bind" == "0.0.0.0" || "$bind" == "::" ]]; then
        local_ipv4s | head -n 1
    else
        printf '%s\n' "$bind"
    fi
}

local_ipv4s() {
    ifconfig 2>/dev/null | awk '
        /inet / && $2 != "127.0.0.1" {
            print $2
        }
    ' | sort -u
}

scan_prefix_for_rpc() {
    local prefix="$1"
    local port="$2"
    local tmp
    local host
    local running=0

    tmp="$(mktemp -t llama-rpc-scan.XXXXXX)"
    for host in $(seq 1 254); do
        (
            if nc -z -G 1 "${prefix}.${host}" "$port" >/dev/null 2>&1; then
                printf '%s:%s\t16\n' "${prefix}.${host}" "$port" >>"$tmp"
            fi
        ) &
        running=$((running + 1))
        if [[ "$running" -ge 64 ]]; then
            wait
            running=0
        fi
    done
    wait

    sort -u "$tmp"
    rm -f "$tmp"
}

scan_prefixes_for_udp_rpc() {
    local prefixes="$1"
    local discovery_port="$2"
    local fallback_rpc_port="$3"

    if ! command -v python3 >/dev/null 2>&1; then
        return 0
    fi

    python3 - "$prefixes" "$discovery_port" "$fallback_rpc_port" "$DISCOVERY_MAGIC" <<'PY'
import re
import socket
import sys
import time

prefixes = [p for p in sys.argv[1].splitlines() if p]
discovery_port = int(sys.argv[2])
fallback_rpc_port = sys.argv[3]
magic = sys.argv[4].encode()

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(0.2)

for prefix in prefixes:
    for i in range(1, 255):
        try:
            sock.sendto(magic, (f"{prefix}.{i}", discovery_port))
        except OSError:
            pass

seen = {}
end = time.time() + 3
while time.time() < end:
    try:
        data, addr = sock.recvfrom(4096)
    except socket.timeout:
        continue
    text = data.decode("utf-8", "replace")
    if not text.startswith("LLAMA_CPP_RPC_V1|"):
        continue
    parts = text.split("|", 3)
    if len(parts) != 4:
        continue
    rpc_port = parts[2] or fallback_rpc_port
    metadata = parts[3]
    ram = "16"
    match = re.search(r"ram_gib=([0-9]+)", metadata)
    if match:
        ram = match.group(1)
    endpoint = f"{addr[0]}:{rpc_port}"
    seen[endpoint] = ram

for endpoint in sorted(seen):
    print(f"{endpoint}\t{seen[endpoint]}")
PY
}

apply_scanned_workers() {
    local scanned="$1"
    local endpoint
    local ram

    [[ -n "$scanned" ]] || return 1

    RPC_ENDPOINTS=""
    WORKER_RAM_GIBS=""
    while IFS=$'\t' read -r endpoint ram; do
        [[ -n "$endpoint" ]] || continue
        [[ "$ram" =~ ^[0-9]+$ ]] || ram="16"

        if [[ -z "$RPC_ENDPOINTS" ]]; then
            RPC_ENDPOINTS="$endpoint"
            WORKER_RAM_GIBS="$ram"
        else
            RPC_ENDPOINTS="$RPC_ENDPOINTS,$endpoint"
            WORKER_RAM_GIBS="$WORKER_RAM_GIBS,$ram"
        fi
    done <<< "$scanned"

    [[ -n "$RPC_ENDPOINTS" ]]
}

scan_specs_to_prefixes() {
    local specs="$1"
    local old_ifs="$IFS"
    local spec
    local a b c base end

    IFS=','
    for spec in $specs; do
        spec="$(printf '%s' "$spec" | tr -d '[:space:]')"
        [[ -n "$spec" ]] || continue

        if [[ "$spec" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
            printf '%s\n' "$spec"
        elif [[ "$spec" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.0/24$ ]]; then
            printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        elif [[ "$spec" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.0/23$ ]]; then
            a="${BASH_REMATCH[1]}"
            b="${BASH_REMATCH[2]}"
            c="${BASH_REMATCH[3]}"
            base=$((c & 254))
            end=$((base + 1))
            printf '%s.%s.%s\n' "$a" "$b" "$base"
            printf '%s.%s.%s\n' "$a" "$b" "$end"
        else
            echo "WARNING: unsupported SCAN_SUBNETS entry '$spec' (use 10.27.180.0/23, 10.27.180.0/24, or 10.27.180)." >&2
        fi
    done
    IFS="$old_ifs"
}

default_scan_prefixes() {
    local ip
    local a b c d pair

    while IFS= read -r ip; do
        [[ "$ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || continue
        a="${BASH_REMATCH[1]}"
        b="${BASH_REMATCH[2]}"
        c="${BASH_REMATCH[3]}"
        d="${BASH_REMATCH[4]}"
        pair=$((c ^ 1))
        printf '%s.%s.%s\n' "$a" "$b" "$c"
        printf '%s.%s.%s\n' "$a" "$b" "$pair"
    done < <(local_ipv4s)
}

scan_for_rpc_workers() {
    local prefixes
    local prefix
    local found=""
    local scan_result

    if [[ "$SCAN_RPC_WORKERS" != "1" ]]; then
        return 0
    fi
    if ! command -v nc >/dev/null 2>&1; then
        echo "Cannot scan routed subnets because nc is unavailable."
        return 0
    fi

    if [[ -n "$SCAN_SUBNETS" ]]; then
        prefixes="$(scan_specs_to_prefixes "$SCAN_SUBNETS" | sort -u)"
    else
        prefixes="$(default_scan_prefixes | sort -u)"
    fi

    [[ -n "$prefixes" ]] || return 0

    echo >&2
    echo "No Bonjour worker found; scanning routed subnet prefixes for discovery UDP $DISCOVERY_PORT and RPC TCP $RPC_PORT..." >&2
    printf '%s\n' "$prefixes" | sed 's/^/  - /' >&2

    found="$(scan_prefixes_for_udp_rpc "$prefixes" "$DISCOVERY_PORT" "$RPC_PORT")"
    if [[ -n "$found" ]]; then
        printf '%s\n' "$found" | sort -u
        return 0
    fi

    echo "No worker answered UDP discovery; falling back to TCP port scan. Worker RAM will default to 16 GiB unless WORKER_RAM_GIBS is set." >&2

    while IFS= read -r prefix; do
        [[ -n "$prefix" ]] || continue
        scan_result="$(scan_prefix_for_rpc "$prefix" "$RPC_PORT")"
        if [[ -n "$scan_result" ]]; then
            if [[ -z "$found" ]]; then
                found="$scan_result"
            else
                found="$found
$scan_result"
            fi
        fi
    done <<< "$prefixes"

    if [[ -n "$found" ]]; then
        printf '%s\n' "$found" | sort -u
    fi
}

# ----- Discover workers -----
if [[ -n "$RPC_SERVERS" ]]; then
    echo "[1/5] Using manual RPC worker endpoint(s)..."
    RPC_ENDPOINTS="$RPC_SERVERS"
    IFS=',' read -r FIRST_ENDPOINT _REST <<< "$RPC_ENDPOINTS"
    FIRST_HOST="${FIRST_ENDPOINT%:*}"
    FIRST_PORT="${FIRST_ENDPOINT##*:}"
    echo "Checking RPC TCP connection to $FIRST_ENDPOINT..."
    wait_for_tcp "$FIRST_HOST" "$FIRST_PORT" "$FIRST_ENDPOINT" || die "Manual RPC endpoint is not reachable: $FIRST_ENDPOINT"

    RPC_COUNT_FOR_DEFAULT_RAM="$(awk -v endpoints="$RPC_ENDPOINTS" 'BEGIN { print split(endpoints, parts, ",") }')"
    if [[ -z "$WORKER_RAM_GIBS" ]]; then
        WORKER_RAM_GIBS="$(awk -v n="$RPC_COUNT_FOR_DEFAULT_RAM" 'BEGIN { for (i=1; i<=n; i++) { printf "%s16", (i == 1 ? "" : ",") } }')"
    fi
else
    echo "[1/5] Discovering Macs sharing llama.cpp RPC..."
    BROWSE_LOG="$(mktemp -t llama-rpc-browse.XXXXXX)"

    dns-sd -B "$SERVICE_TYPE" local >"$BROWSE_LOG" 2>&1 &
    BROWSE_PID=$!

    sleep "$DISCOVERY_SECONDS"
    kill "$BROWSE_PID" >/dev/null 2>&1 || true
    wait "$BROWSE_PID" >/dev/null 2>&1 || true

    SERVICE_NAMES="$(
        awk '
          / Add / && /_llamacpp-rpc\._tcp\./ {
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

    if [[ -z "$SERVICE_NAMES" ]]; then
        echo
        echo "No worker Mac was discovered."
        echo "Run share-gpu-worker-macos-apple-silicon.sh on the other Mac first."
        echo "Both Macs must be on the same Bonjour/mDNS-capable LAN."
        SCANNED_WORKERS="$(scan_for_rpc_workers)"
        if ! apply_scanned_workers "$SCANNED_WORKERS"; then
            echo "If the worker Mac showed a macOS incoming-connection prompt, click Allow there and run this command again."
            echo "If direct TCP works, retry with: RPC_SERVERS=<worker-ip>:50052 WORKER_RAM_GIBS=<worker-ram> $0 <model.gguf>"
            exit 1
        fi
    else

        echo "Found worker service(s):"
        printf '%s\n' "$SERVICE_NAMES" | sed 's/^/  - /'
        echo

        # Resolve each Bonjour service to host + port.
        RPC_ENDPOINTS=""
        WORKER_RAM_GIBS=""
        while IFS= read -r svc; do
            [[ -n "$svc" ]] || continue
            RESOLVE_LOG="$(mktemp -t llama-rpc-resolve.XXXXXX)"

            dns-sd -L "$svc" "$SERVICE_TYPE" local >"$RESOLVE_LOG" 2>&1 &
            RESOLVE_PID=$!
            sleep 2
            kill "$RESOLVE_PID" >/dev/null 2>&1 || true
            wait "$RESOLVE_PID" >/dev/null 2>&1 || true

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
            WORKER_RAM_GIB="$(grep -Eo 'ram_gib=[0-9]+' "$RESOLVE_LOG" | head -n 1 | cut -d= -f2 || true)"

            rm -f "$RESOLVE_LOG"

            if [[ -n "$TARGET" ]]; then
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
                    if [[ ! "$WORKER_RAM_GIB" =~ ^[0-9]+$ ]]; then
                        WORKER_RAM_GIB="16"
                    fi

                    if [[ -z "$RPC_ENDPOINTS" ]]; then
                        RPC_ENDPOINTS="$ENDPOINT"
                        WORKER_RAM_GIBS="$WORKER_RAM_GIB"
                    else
                        RPC_ENDPOINTS="$RPC_ENDPOINTS,$ENDPOINT"
                        WORKER_RAM_GIBS="$WORKER_RAM_GIBS,$WORKER_RAM_GIB"
                    fi
                else
                    echo "WARNING: $ENDPOINT was discovered by Bonjour but did not accept TCP connections on port $TARGET_PORT. Skipping it."
                fi
            fi
        done <<< "$SERVICE_NAMES"

        if [[ -z "$RPC_ENDPOINTS" ]]; then
            echo "Worker(s) were visible in Bonjour but no reachable RPC TCP endpoint was found. Trying routed subnet scan."
            SCANNED_WORKERS="$(scan_for_rpc_workers)"
            apply_scanned_workers "$SCANNED_WORKERS" || die "No reachable RPC worker was found. If the worker Mac showed a macOS incoming-connection prompt, click Allow there and run this command again."
        fi
    fi
fi

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
TENSOR_SPLIT="${TENSOR_SPLIT:-$MEM_GIB${WORKER_RAM_GIBS:+,$WORKER_RAM_GIBS}}"
echo "llama.cpp tensor split: $TENSOR_SPLIT"
awk -v split_spec="$TENSOR_SPLIT" '
    BEGIN {
        n = split(split_spec, parts, ",")
        total = 0
        for (i = 1; i <= n; i++) total += parts[i]
        if (total <= 0) exit
        for (i = 1; i <= n; i++) {
            label = (i == 1) ? "Host" : "Worker" (i - 1)
            printf "Split device %s: %.0f%%\n", label, (parts[i] / total) * 100
        }
    }
'
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
echo "Allocation is memory-weighted:"
echo "  local Metal GPU + discovered RPC Metal GPU(s)"
echo "  larger Macs receive a larger layer/KV share via --tensor-split."
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
    --tensor-split "$TENSOR_SPLIT"
    --ctx-size "$CONTEXT"
    --fit on
    --load-mode none
)

if [[ "$MODE" == "cli" ]]; then
    exec "$CLI_EXE" "${COMMON_ARGS[@]}"
else
    ensure_server_port_free "$SERVER_PORT"
    DISPLAY_SERVER_HOST="$(server_display_host "$SERVER_HOST")"
    echo "llama-server bind: ${SERVER_HOST}:${SERVER_PORT}"
    if [[ -n "$DISPLAY_SERVER_HOST" ]]; then
        echo "llama-server URL : http://${DISPLAY_SERVER_HOST}:${SERVER_PORT}"
    fi
    echo
    SERVER_ARGS=(
        "${COMMON_ARGS[@]}"
        --alias "$MODEL_ALIAS"
        --host "$SERVER_HOST"
        --port "$SERVER_PORT"
    )
    if [[ -n "${SERVER_CORS_ORIGINS:-}" ]]; then
        SERVER_ARGS+=(--cors-origins "$SERVER_CORS_ORIGINS")
    fi
    exec "$SERVER_EXE" "${SERVER_ARGS[@]}"
fi
