#!/usr/bin/env bash
#
# Start-KioskAgent-Linux.sh
#
# Advanced kiosk launcher + agent for Debian / Raspberry Pi OS. This is the
# "v2" companion to Start-KioskChrome-Linux.sh.
#
# It does everything the basic launcher does:
#   1. Detects Chromium/Chrome and locates the binary automatically.
#   2. Opens the firewall for the Chrome remote debugging port (ufw,
#      firewalld, or plain iptables - whichever is present).
#   3. Launches Chromium in kiosk mode with remote debugging enabled.
#   4. Works around recent Chromium builds hard-locking the debug listener to
#      127.0.0.1 by adding an iptables DNAT rule.
#
# ...and then keeps running as an agent that adds:
#   5. Server discovery - unless --server-url or --server-ip is given, the
#      script finds the VR HEADSET MANAGER server on its own by scanning the
#      local network (same approach as scripts/Tools/Find-VRHM-Server.ps1). A
#      successful match is cached next to this script, so later reboots
#      resolve instantly. If nothing is found, it offers to retry the scan,
#      accept a manually typed IP, or be cancelled with Ctrl+C - use
#      --server-ip for a routed network (scanning does not cross subnets).
#   6. Reporting - every few seconds it tells the VR HEADSET MANAGER server
#      this PC's hostname, OS version, Chromium version, and whether the
#      connection to the server runs over Ethernet or WiFi.
#   7. Remote power control - reboot / shutdown / browser restart ordered from
#      VR HEADSET MANAGER.
#   8. Browser watchdog - Chromium is relaunched automatically if it dies.
#
# IMPORTANT - this script never opens a listening port of its own. It only
# makes OUTBOUND calls: to its own loopback Chromium debug port, and to the
# VR HEADSET MANAGER server. Commands travel back inside the reply to its own
# report.
#
# Unlike the basic launcher, this script STAYS IN THE FOREGROUND - closing the
# terminal stops the agent. See README-KioskChrome.md for the systemd unit that
# runs it at boot.
#
# Usage:
#   ./Start-KioskAgent-Linux.sh [--server-url URL] [--server-ip IP] [--server-port PORT]
#                               [--url URL] [--port PORT]
#                               [--report-interval SECONDS] [--no-auto-restart]
#
#   Positional "URL PORT" is also accepted, matching the basic launcher.
#
# Examples:
#   ./Start-KioskAgent-Linux.sh
#   ./Start-KioskAgent-Linux.sh --server-url http://192.168.1.37:8080 --port 9222
#   ./Start-KioskAgent-Linux.sh --server-ip 10.0.5.12 --server-port 8080
#
# Reboot and shutdown need root. Either run this script with sudo, or grant the
# desktop user passwordless rights to just those two commands - see the README.
#
# Safe to re-run any time. Any previous kiosk Chromium and any previous
# port-redirect rule for the same port are stopped/removed first.

set -u

AGENT_VERSION="1.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
VRHM_SERVER_CACHE_FILE="$SCRIPT_DIR/vrhm_server_cache.conf"

DEFAULT_URL="data:text/html,%3Chtml%3E%3Chead%3E%3Cmeta%20charset%3D'utf-8'%3E%3Ctitle%3EKiosk%3C%2Ftitle%3E%3Cstyle%3Ehtml%2Cbody%7Bmargin%3A0%3Bheight%3A100%25%3Bbackground%3A%23000%3Bcolor%3A%23fff%3Bdisplay%3Aflex%3Balign-items%3Acenter%3Bjustify-content%3Acenter%3Bfont-family%3Asystem-ui%2Csans-serif%3Bflex-direction%3Acolumn%7Dh1%7Bfont-size%3A3vw%3Bletter-spacing%3A.08em%3Btext-transform%3Auppercase%3Bcolor%3A%23888%3Bmargin%3A0%7Dh2%7Bfont-size%3A5vw%3Bfont-weight%3A700%3Bmargin%3A12px%200%200%7D%3C%2Fstyle%3E%3C%2Fhead%3E%3Cbody%3E%3Ch1%3EKiosk%20Mode%3C%2Fh1%3E%3Ch2%3EReady%20to%20stream%3C%2Fh2%3E%3C%2Fbody%3E%3C%2Fhtml%3E"

# ---------------------------------------------------------------------------
# 0. Arguments
# ---------------------------------------------------------------------------
URL="$DEFAULT_URL"
PORT="9222"
SERVER_URL=""
SERVER_IP=""
SERVER_PORT="8080"
REPORT_INTERVAL="5"
AUTO_RESTART="1"
POSITIONAL=()

while [ $# -gt 0 ]; do
    case "$1" in
        --server-url)      SERVER_URL="${2:-}"; shift 2 ;;
        --server-ip)       SERVER_IP="${2:-}"; shift 2 ;;
        --server-port)     SERVER_PORT="${2:-}"; shift 2 ;;
        --url)             URL="${2:-}"; shift 2 ;;
        --port)            PORT="${2:-}"; shift 2 ;;
        --report-interval) REPORT_INTERVAL="${2:-}"; shift 2 ;;
        --no-auto-restart) AUTO_RESTART="0"; shift ;;
        -h|--help)
            sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

# Positional compatibility with Start-KioskChrome-Linux.sh: [URL] [PORT]
if [ "${#POSITIONAL[@]}" -ge 1 ]; then URL="${POSITIONAL[0]}"; fi
if [ "${#POSITIONAL[@]}" -ge 2 ]; then PORT="${POSITIONAL[1]}"; fi

case "$REPORT_INTERVAL" in
    ''|*[!0-9]*) REPORT_INTERVAL=5 ;;
esac
[ "$REPORT_INTERVAL" -lt 1 ] && REPORT_INTERVAL=1

case "$SERVER_PORT" in
    ''|*[!0-9]*) SERVER_PORT=8080 ;;
esac

echo "=== VRHM Kiosk Agent setup (Linux) ==="
echo "URL:    $URL"
echo "Port:   $PORT"
if [ -n "$SERVER_URL" ]; then
    echo "Server: $SERVER_URL (reporting every ${REPORT_INTERVAL}s)"
elif [ -n "$SERVER_IP" ]; then
    echo "Server: http://$SERVER_IP:$SERVER_PORT (reporting every ${REPORT_INTERVAL}s)"
else
    echo "Server: will be found automatically on the local network."
fi
echo ""

# ---------------------------------------------------------------------------
# 1. Identify the real desktop user and DISPLAY, in case this script was itself
#    launched via sudo (we never want to run the browser as root - Chromium
#    refuses to start as root unless --no-sandbox is passed, which weakens the
#    sandbox, and root usually cannot attach to the desktop user's session).
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    TARGET_USER="${SUDO_USER:-}"
    if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
        echo "This script was started as root and no other desktop user could be" >&2
        echo "identified. Please run it as your normal desktop user instead, or via" >&2
        echo "sudo from that user's session." >&2
        exit 1
    fi
    RUN_AS_USER="sudo -u $TARGET_USER"
else
    TARGET_USER="$(id -un)"
    RUN_AS_USER=""
fi

if [ -z "${DISPLAY:-}" ]; then
    DISPLAY=":0"
fi
if [ -z "${XAUTHORITY:-}" ]; then
    XAUTHORITY="$(eval echo "~$TARGET_USER")/.Xauthority"
fi

# ---------------------------------------------------------------------------
# 2. curl is the agent's only hard dependency beyond the browser itself: it
#    carries both the loopback CDP reads and the outbound report.
# ---------------------------------------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required by the kiosk agent but was not found."
    read -p "Install curl now with apt-get? [Y/n]: " CURL_CHOICE
    case "$CURL_CHOICE" in
        [Nn]*)
            echo "Install it manually with: sudo apt-get install -y curl" >&2
            exit 1
            ;;
        *)
            sudo apt-get update -y && sudo apt-get install -y curl
            if ! command -v curl >/dev/null 2>&1; then
                echo "curl still not available - aborting." >&2
                exit 1
            fi
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# 3. Locate Chromium / Chrome
# ---------------------------------------------------------------------------
CHROME_BIN=""
for candidate in chromium-browser chromium google-chrome-stable google-chrome; do
    if command -v "$candidate" >/dev/null 2>&1; then
        CHROME_BIN="$(command -v "$candidate")"
        break
    fi
done

if [ -z "$CHROME_BIN" ]; then
    echo "Could not find chromium-browser, chromium, google-chrome-stable, or google-chrome." >&2
    echo ""
    read -p "Install Chromium now? [A] Auto-install (recommended) / [M] I'll install it manually: " CHROME_INSTALL_CHOICE

    case "$CHROME_INSTALL_CHOICE" in
        [Aa]*)
            echo "Installing chromium via apt-get (requires sudo)..."
            if sudo apt-get update -y && sudo apt-get install -y chromium; then
                :
            else
                echo "Package 'chromium' failed - trying 'chromium-browser' (older Raspberry Pi OS releases)..." >&2
                sudo apt-get install -y chromium-browser
            fi

            for candidate in chromium-browser chromium google-chrome-stable google-chrome; do
                if command -v "$candidate" >/dev/null 2>&1; then
                    CHROME_BIN="$(command -v "$candidate")"
                    break
                fi
            done

            if [ -z "$CHROME_BIN" ]; then
                echo "Automatic install did not succeed." >&2
                echo "Install one manually, for example:" >&2
                echo "  sudo apt-get update && sudo apt-get install -y chromium" >&2
                exit 1
            fi
            ;;
        *)
            echo "Install one first, for example on Debian/Raspberry Pi OS:" >&2
            echo "  sudo apt-get update && sudo apt-get install -y chromium" >&2
            exit 1
            ;;
    esac
fi

echo "Chromium found at: $CHROME_BIN"

# ---------------------------------------------------------------------------
# 3b. Hardware H264 decode check (Raspberry Pi VideoCore). Informational only -
#     never blocks startup, just logs whether the GPU path is available so a
#     silent fallback to software decoding shows up in the console/journal
#     instead of only as unexplained CPU load and dropped frames.
# ---------------------------------------------------------------------------
HW_H264_DECODE="unknown"

check_h264_hardware_decode() {
    if ! command -v vcgencmd >/dev/null 2>&1; then
        echo "vcgencmd not found - not a Raspberry Pi, or firmware tools not installed. Skipping H264 hardware check."
        return
    fi

    CODEC_STATUS="$(vcgencmd codec_enabled H264 2>/dev/null)"
    if [ "$CODEC_STATUS" = "H264=enabled" ]; then
        HW_H264_DECODE="1"
        echo "GPU H264 decode: enabled ($CODEC_STATUS)"
    else
        HW_H264_DECODE="0"
        echo "GPU H264 decode: NOT enabled ($CODEC_STATUS) - video will fall back to software decoding." >&2
    fi

    if dpkg -l 2>/dev/null | grep -q "rpi-chromium-mods"; then
        echo "rpi-chromium-mods: installed (Chromium hardware-decode patches present)."
    else
        echo "rpi-chromium-mods: NOT installed - this Chromium build likely has no hardware-decode patches." >&2
        echo "  Install with: sudo apt-get install -y rpi-chromium-mods" >&2
    fi
}

check_h264_hardware_decode

# ---------------------------------------------------------------------------
# 4. Open the firewall for the debug port
# ---------------------------------------------------------------------------
echo ""
echo "Configuring firewall for TCP port $PORT..."

if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -qi "^Status: active"; then
    sudo ufw allow "${PORT}/tcp" comment "VRHM Kiosk Chrome Debug" >/dev/null
    echo "ufw rule ensured for port $PORT."
elif command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
    sudo firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
    sudo firewall-cmd --reload >/dev/null
    echo "firewalld rule ensured for port $PORT."
elif command -v iptables >/dev/null 2>&1; then
    if ! sudo iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
        sudo iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        echo "iptables rule added for port $PORT."
        echo "Note: this iptables rule is not persisted across reboots unless you"
        echo "have iptables-persistent (or similar) installed and configured."
    else
        echo "iptables rule for port $PORT already present."
    fi
else
    echo "No supported firewall tool found (ufw/firewalld/iptables). Skipping firewall step -" >&2
    echo "make sure port $PORT is reachable by whatever means you use to manage this PC's firewall." >&2
fi

USER_DATA_DIR="$(eval echo "~$TARGET_USER")/.config/vrhm-kiosk-chrome"

# ---------------------------------------------------------------------------
# 5. Browser lifecycle helpers. Factored into functions because - unlike the
#    basic launcher - this script relaunches Chromium on its own.
# ---------------------------------------------------------------------------
stop_existing_browser() {
    pkill -f "remote-debugging-port=$PORT" 2>/dev/null || true
    pkill -f "socat.*:$PORT," 2>/dev/null || true
    sleep 1
}

clean_browser_profile() {
    mkdir -p "$USER_DATA_DIR" 2>/dev/null || true

    # When Chromium is closed via CDP "Browser.close" instead of this script's
    # own pkill, it can leave Singleton* lock files behind. A later launch then
    # silently hands off to (or is blocked by) that stale lock instead of
    # starting a genuinely fresh, debug-enabled process - Chromium opens and the
    # kiosk display looks fine, but the new debug listener never comes up, so the
    # server can no longer reach it. This matters far more here than in the basic
    # launcher, because the watchdog relaunches often.
    for lockFile in SingletonLock SingletonSocket SingletonCookie; do
        rm -f "$USER_DATA_DIR/$lockFile" 2>/dev/null || true
    done

    # A hard power loss leaves Preferences with exit_type=Crashed, and recent
    # Chromium builds show the "Restore pages?" popup based on that stored value
    # regardless of --disable-session-crashed-bubble.
    PREFS_FILE="$USER_DATA_DIR/Default/Preferences"
    if [ -f "$PREFS_FILE" ]; then
        if command -v python3 >/dev/null 2>&1; then
            python3 - "$PREFS_FILE" <<'PYEOF' 2>/dev/null || true
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

profile = data.get("profile")
if isinstance(profile, dict):
    profile["exit_type"] = "Normal"
    profile["exited_cleanly"] = True
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f)
PYEOF
        else
            sed -i \
                -e 's/"exit_type":"[^"]*"/"exit_type":"Normal"/' \
                -e 's/"exited_cleanly":false/"exited_cleanly":true/' \
                "$PREFS_FILE" 2>/dev/null || true
        fi
    fi
}

CHROME_PID=""

start_kiosk_browser() {
    clean_browser_profile

    echo "Starting Chromium in kiosk mode..."

    # Hardware-decode flags are a safety net only: on Raspberry Pi OS builds
    # with rpi-chromium-mods, hardware H264 decode is already patched in and
    # these flags are redundant; on a plain Debian/Chromium build (no RPi
    # patches, e.g. HW_H264_DECODE=0 above) they give VA-API/V4L2 a chance to
    # kick in instead of silently falling back to full-software decode.
    HW_DECODE_FLAGS=(
        --enable-features=VaapiVideoDecoder
        --enable-accelerated-video-decode
        --ignore-gpu-blocklist
    )

    $RUN_AS_USER env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" "$CHROME_BIN" \
        --remote-debugging-port="$PORT" \
        --remote-debugging-address=0.0.0.0 \
        --remote-allow-origins=* \
        --user-data-dir="$USER_DATA_DIR" \
        --kiosk \
        --noerrdialogs \
        --disable-infobars \
        --no-first-run \
        --deny-permission-prompts \
        --disable-notifications \
        --disable-features=Translate,TranslateUI,PrivacySandboxSettings4,AutofillServerCommunication \
        --disable-session-crashed-bubble \
        --no-default-browser-check \
        --autoplay-policy=no-user-gesture-required \
        "${HW_DECODE_FLAGS[@]}" \
        "$URL" >/dev/null 2>&1 &

    CHROME_PID=$!
    disown 2>/dev/null || true
}

remove_port_redirect() {
    sudo iptables -t nat -D PREROUTING -p tcp --dport "$PORT" -j DNAT \
        --to-destination "127.0.0.1:$PORT" -m comment --comment "VRHM_KIOSK_DEBUGPORT" 2>/dev/null || true
}

restart_kiosk_browser() {
    reason="${1:-operator request}"
    echo "Restarting the kiosk browser ($reason)..."
    remove_port_redirect
    stop_existing_browser
    start_kiosk_browser
    update_port_redirect

    for attempt in $(seq 1 10); do
        if cdp_version >/dev/null 2>&1; then
            echo "Chromium debug endpoint is online after restart."
            return 0
        fi
        sleep 1
    done
    echo "Chromium restarted, but the local debug endpoint did not answer yet." >&2
    return 1
}

update_port_redirect() {
    echo "Verifying the debug port is reachable from the network..."

    # Chromium can take longer than a few seconds to bind the debug port on
    # slower hardware (e.g. Raspberry Pi), so poll instead of checking once.
    LISTEN_LINE=""
    for attempt in $(seq 1 15); do
        if command -v ss >/dev/null 2>&1; then
            LISTEN_LINE="$(ss -ltn 2>/dev/null | grep ":$PORT[[:space:]]" | head -n1)"
        elif command -v netstat >/dev/null 2>&1; then
            LISTEN_LINE="$(netstat -ltn 2>/dev/null | grep ":$PORT[[:space:]]" | head -n1)"
        fi
        [ -n "$LISTEN_LINE" ] && break
        sleep 1
    done

    # Always remove any previous redirect for this port before deciding whether a
    # new one is needed, so repeated relaunches stay idempotent.
    remove_port_redirect
    pkill -f "socat.*:$PORT," 2>/dev/null || true

    if [ -n "$LISTEN_LINE" ] && echo "$LISTEN_LINE" | grep -q "127.0.0.1:$PORT"; then
        echo "Chromium is only listening on 127.0.0.1:$PORT (LAN binding was ignored by this build)."
        echo "Redirecting LAN connections on port $PORT to the loopback listener (iptables DNAT)..."

        # The kernel treats a packet whose destination becomes 127.0.0.1 as
        # "martian" and drops it unless route_localnet is enabled - and it must be
        # set per already-up interface, not just "all", to take effect.
        sudo sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
        for iface in $(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$'); do
            sudo sysctl -w "net.ipv4.conf.${iface}.route_localnet=1" >/dev/null 2>&1 || true
        done

        if sudo iptables -t nat -A PREROUTING -p tcp --dport "$PORT" -j DNAT \
                --to-destination "127.0.0.1:$PORT" -m comment --comment "VRHM_KIOSK_DEBUGPORT"; then
            echo "Port redirect active: LAN:$PORT -> 127.0.0.1:$PORT (iptables DNAT)"
        else
            echo "Could not add the iptables DNAT rule for port $PORT." >&2
        fi
    elif [ -n "$LISTEN_LINE" ]; then
        echo "Chromium is listening on a LAN-reachable address - already reachable from the network."
    else
        echo "Could not confirm Chromium is listening on port $PORT yet." >&2
    fi
}

# ---------------------------------------------------------------------------
# 6. Agent helpers - local machine facts
# ---------------------------------------------------------------------------

# Machine identity and OS description never change while the script runs, so
# they are resolved once at startup rather than on every report.
MACHINE_ID="$(cat /etc/machine-id 2>/dev/null || true)"
[ -z "$MACHINE_ID" ] && MACHINE_ID="$(hostname)"

OS_DESCRIPTION="$( (grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null || true) | cut -d'"' -f2 )"
[ -z "$OS_DESCRIPTION" ] && OS_DESCRIPTION="$(uname -s)"
OS_DESCRIPTION="$OS_DESCRIPTION (kernel $(uname -r))"

HOST_NAME="$(hostname 2>/dev/null || echo unknown)"
STARTED_AT="$(date +%s)"

json_escape() {
    # Minimal JSON string escaping: backslash, double quote, and control chars.
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\000-\010\013\014\016-\037'
}

url_host() {
    # http://1.2.3.4:8080/path -> 1.2.3.4
    printf '%s' "$1" | sed -e 's|^[a-zA-Z]*://||' -e 's|/.*$||' -e 's|:.*$||'
}

IFACE_TYPE="Unknown"
IFACE_NAME=""
IFACE_SPEED=""

detect_session_interface() {
    # Reports the interface that actually carries the session with the server,
    # rather than guessing at "the primary adapter": ask the routing table which
    # device it would use to reach the server address.
    local server_host="$1"
    IFACE_TYPE="Unknown"; IFACE_NAME=""; IFACE_SPEED=""
    [ -z "$server_host" ] && return 0

    local target_ip route_line
    target_ip="$server_host"
    case "$server_host" in
        *[!0-9.]*)
            target_ip="$(getent hosts "$server_host" 2>/dev/null | awk '{print $1; exit}')"
            ;;
    esac
    [ -z "$target_ip" ] && return 0

    route_line="$(ip route get "$target_ip" 2>/dev/null | head -n1)"
    [ -z "$route_line" ] && return 0

    IFACE_NAME="$(printf '%s' "$route_line" | sed -n 's/.*[[:space:]]dev[[:space:]]\+\([^[:space:]]\+\).*/\1/p')"
    [ -z "$IFACE_NAME" ] && return 0

    # The presence of a "wireless" (or "phy80211") node under the interface is
    # the kernel's own answer to "is this WiFi", and needs no extra tooling.
    if [ -d "/sys/class/net/$IFACE_NAME/wireless" ] || [ -e "/sys/class/net/$IFACE_NAME/phy80211" ]; then
        IFACE_TYPE="WiFi"
    else
        IFACE_TYPE="Ethernet"
    fi

    # /sys .../speed is Mbps for wired links; it is absent or -1 on wireless.
    if [ -r "/sys/class/net/$IFACE_NAME/speed" ]; then
        local spd
        spd="$(cat "/sys/class/net/$IFACE_NAME/speed" 2>/dev/null || true)"
        case "$spd" in
            ''|*[!0-9]*) IFACE_SPEED="" ;;
            *) IFACE_SPEED="$spd" ;;
        esac
    fi
}

cdp_browser_version() {
    curl -s -m 2 "http://127.0.0.1:$PORT/json/version" 2>/dev/null |
        grep -oE '"Browser"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 |
        sed -e 's/.*:[[:space:]]*"//' -e 's/"$//'
}

cdp_current_url() {
    # In kiosk mode there is a single page target, but /json/list can also carry
    # service-worker and devtools targets, so skip any URL scheme that cannot be
    # what is on screen.
    curl -s -m 2 "http://127.0.0.1:$PORT/json/list" 2>/dev/null |
        grep -oE '"url"[[:space:]]*:[[:space:]]*"[^"]*"' |
        sed -e 's/.*:[[:space:]]*"//' -e 's/"$//' |
        grep -vE '^(devtools|chrome-extension|chrome-untrusted)://' |
        head -n1
}

browser_alive() {
    if [ -n "$CHROME_PID" ] && kill -0 "$CHROME_PID" 2>/dev/null; then
        return 0
    fi
    # Chromium can hand a launch off to an existing process, retiring the PID we
    # hold while the browser itself is perfectly alive. Only a dead debug endpoint
    # proves the browser is really gone.
    if [ -n "$(cdp_browser_version)" ]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 7. Agent helpers - talking to the server
# ---------------------------------------------------------------------------

build_report() {
    # $1 = server base url, $2 = browserRunning (true/false), $3 = current url,
    # $4/$5/$6 = optional ack cmd / nonce / result
    local base="$1" running="$2" cur="$3" ack_cmd="${4:-}" ack_nonce="${5:-}" ack_result="${6:-}"

    detect_session_interface "$(url_host "$base")"

    local browser uptime speed_json ack_json
    browser="$(cdp_browser_version)"
    if [ -z "$browser" ]; then
        browser="$("$CHROME_BIN" --version 2>/dev/null | head -n1)"
    fi
    uptime=$(( $(date +%s) - STARTED_AT ))

    if [ -n "$IFACE_SPEED" ]; then speed_json="$IFACE_SPEED"; else speed_json="null"; fi

    ack_json=""
    if [ -n "$ack_cmd" ]; then
        ack_json=",\"ack\":{\"cmd\":\"$(json_escape "$ack_cmd")\",\"nonce\":\"$(json_escape "$ack_nonce")\",\"result\":\"$(json_escape "$ack_result")\"}"
    fi

    printf '{"type":"VRHM_KIOSK_AGENT","version":"%s","machineId":"%s","hostname":"%s","os":"%s","osFamily":"Linux","interfaceType":"%s","interfaceName":"%s","linkSpeedMbps":%s,"browser":"%s","browserRunning":%s,"cdpPort":%s,"currentUrl":"%s","uptimeSec":%s,"autoRestartBrowser":%s%s}' \
        "$AGENT_VERSION" \
        "$(json_escape "$MACHINE_ID")" \
        "$(json_escape "$HOST_NAME")" \
        "$(json_escape "$OS_DESCRIPTION")" \
        "$(json_escape "$IFACE_TYPE")" \
        "$(json_escape "$IFACE_NAME")" \
        "$speed_json" \
        "$(json_escape "$browser")" \
        "$running" \
        "$PORT" \
        "$(json_escape "$cur")" \
        "$uptime" \
        "$( [ "$AUTO_RESTART" = "1" ] && echo true || echo false )" \
        "$ack_json"
}

send_report() {
    # $1 = server base url, $2 = report json. Echoes the reply body, empty on
    # failure. The server's request loop is single-threaded and a few of its
    # endpoints block for a long time (a network scan, for example), so a timeout
    # here is expected occasionally and must not be treated as fatal.
    local base="${1%/}" body="$2"
    [ -z "$base" ] && return 1
    curl -s -m 5 -X POST -H "Content-Type: application/json" -d "$body" \
        "$base/api/kiosks/agent-report" 2>/dev/null
}

json_field_string() {
    printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 |
        sed -e 's/.*:[[:space:]]*"//' -e 's/"$//'
}

json_field_number() {
    printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*[0-9]+" | head -n1 |
        grep -oE '[0-9]+$'
}

run_privileged() {
    # Reboot/shutdown need root. Prefer an already-root shell, then a
    # passwordless sudo rule (see the README for the sudoers line).
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return $?
    fi
    sudo -n "$@" 2>/dev/null
}

BROWSER_RESTART_REQUESTED="0"
AGENT_STOP_REQUESTED="0"

invoke_kiosk_command() {
    # The caller has already acknowledged the command to the server -
    # deliberately, because a reboot leaves no opportunity to do so afterwards.
    local cmd="$1" delay="${2:-5}"

    case "$cmd" in
        reboot)
            echo ""
            echo "REBOOT ordered by VR HEADSET MANAGER - restarting in ${delay}s."
            remove_port_redirect
            sleep "$delay"
            if command -v systemctl >/dev/null 2>&1; then
                run_privileged systemctl reboot || run_privileged shutdown -r now || {
                    echo "Reboot failed - this user cannot run it without a password." >&2
                    echo "See README-KioskChrome.md for the sudoers line to add." >&2
                }
            else
                run_privileged shutdown -r now
            fi
            ;;
        shutdown)
            echo ""
            echo "SHUTDOWN ordered by VR HEADSET MANAGER - powering off in ${delay}s."
            remove_port_redirect
            sleep "$delay"
            if command -v systemctl >/dev/null 2>&1; then
                run_privileged systemctl poweroff || run_privileged shutdown -h now || {
                    echo "Shutdown failed - this user cannot run it without a password." >&2
                    echo "See README-KioskChrome.md for the sudoers line to add." >&2
                }
            else
                run_privileged shutdown -h now
            fi
            ;;
        browser-restart)
            echo ""
            echo "BROWSER RESTART ordered by VR HEADSET MANAGER."
            BROWSER_RESTART_REQUESTED="1"
            ;;
        agent-stop)
            echo ""
            echo "STOP ordered by VR HEADSET MANAGER - closing Chromium and stopping the agent."
            AGENT_STOP_REQUESTED="1"
            ;;
        *)
            echo "Ignoring unknown command '$cmd' from the server." >&2
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 7b. Server discovery - find the VR HEADSET MANAGER server on the LAN when
#     neither --server-url nor --server-ip was given, so a kiosk works out of
#     the box after a DHCP change on either side. This logic is ported from
#     (and should be kept in sync with) scripts/Tools/Find-VRHM-Server.ps1 -
#     duplicated here rather than shared with anything else, matching this
#     script's own "no dependency on any other project file" design. Uses
#     only curl (already this script's one hard dependency) plus coreutils/
#     awk/bash's own /dev/tcp - no jq, no python, no nmap/nc.
# ---------------------------------------------------------------------------

read_vrhm_server_cache() {
    # Prints "IP PORT" on stdout if a cache file exists and looks valid.
    [ -f "$VRHM_SERVER_CACHE_FILE" ] || return 1
    local ip port
    ip="$(sed -n '1p' "$VRHM_SERVER_CACHE_FILE" 2>/dev/null)"
    port="$(sed -n '2p' "$VRHM_SERVER_CACHE_FILE" 2>/dev/null)"
    [ -n "$ip" ] && [ -n "$port" ] || return 1
    printf '%s %s\n' "$ip" "$port"
}

write_vrhm_server_cache() {
    local ip="$1" port="$2"
    { printf '%s\n%s\n' "$ip" "$port" > "$VRHM_SERVER_CACHE_FILE"; } 2>/dev/null || true
}

test_vrhm_server_at() {
    # $1 = ip, $2 = port. Succeeds (exit 0) if a VRHM /api/version answers.
    curl -s -m 2 "http://$1:$2/api/version" 2>/dev/null | grep -q '"version"'
}

probe_host_port() {
    # $1 = ip, $2 = port. Prints the ip on stdout if the TCP port is open.
    # Exported so xargs -P can call it in parallel child shells.
    if timeout 0.3 bash -c ": >/dev/tcp/${1}/${2}" 2>/dev/null; then
        printf '%s\n' "$1"
    fi
}
export -f probe_host_port

expand_cidr_hosts() {
    # $1 = a.b.c.d/prefix -> one usable host IP per line. Pure arithmetic (no
    # gawk-only bitwise extensions), so it works with mawk/gawk/busybox awk.
    local cidr="$1" ip prefix
    ip="${cidr%/*}"
    prefix="${cidr#*/}"
    case "$prefix" in ''|*[!0-9]*) return 0 ;; esac
    [ "$prefix" -lt 7 ] && return 0
    [ "$prefix" -gt 30 ] && return 0

    awk -v ip="$ip" -v prefix="$prefix" 'BEGIN {
        split(ip, o, ".")
        ipnum = o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4]
        hostbits = 32 - prefix
        blocksize = 1
        for (k = 0; k < hostbits; k++) blocksize = blocksize * 2
        network = int(ipnum / blocksize) * blocksize
        maxhost = blocksize - 1
        for (i = 1; i < maxhost; i++) {
            n = network + i
            a = int(n / 16777216) % 256
            b = int(n / 65536) % 256
            c = int(n / 256) % 256
            d = n % 256
            printf "%d.%d.%d.%d\n", a, b, c, d
        }
    }'
}

find_vrhm_server_on_lan() {
    # $1 = port to scan. Prints "IP PORT" on stdout if a server is found.
    local port="$1"

    local cidrs
    cidrs="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | \
        grep -E '^(10\.[0-9]+\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+)/[0-9]+$')"
    if [ -z "$cidrs" ]; then
        echo "No private network interface found on this PC." >&2
        return 1
    fi

    local all_ips="" cidr
    while IFS= read -r cidr; do
        [ -z "$cidr" ] && continue
        all_ips="$all_ips
$(expand_cidr_hosts "$cidr")"
    done <<CIDRS
$cidrs
CIDRS
    all_ips="$(printf '%s\n' "$all_ips" | sed '/^$/d' | sort -u)"
    [ -z "$all_ips" ] && return 1

    local ip_count
    ip_count="$(printf '%s\n' "$all_ips" | grep -c .)"
    echo "Scanning $ip_count address(es) on port $port for a VR HEADSET MANAGER server..." >&2

    local open_hosts
    open_hosts="$(printf '%s\n' "$all_ips" | xargs -P 50 -I{} bash -c 'probe_host_port "$0" "$1"' {} "$port" 2>/dev/null)"
    [ -z "$open_hosts" ] && return 1

    local candidate
    while IFS= read -r candidate; do
        [ -z "$candidate" ] && continue
        if test_vrhm_server_at "$candidate" "$port"; then
            printf '%s %s\n' "$candidate" "$port"
            return 0
        fi
    done <<HOSTS
$open_hosts
HOSTS

    return 1
}

resolve_vrhm_server_url() {
    # Cascade: --server-url > --server-ip > cached last-known server > LAN
    # scan > a blocking console menu (retry the scan, type an IP manually, or
    # Ctrl+C to give up). Prints the resolved URL on stdout; all status/prompt
    # text goes to stderr so command substitution only captures the URL.
    if [ -n "$SERVER_URL" ]; then
        printf '%s\n' "$SERVER_URL"
        return 0
    fi
    if [ -n "$SERVER_IP" ]; then
        printf 'http://%s:%s\n' "$SERVER_IP" "$SERVER_PORT"
        return 0
    fi

    local cached cip cport
    cached="$(read_vrhm_server_cache)"
    if [ -n "$cached" ]; then
        cip="$(printf '%s' "$cached" | awk '{print $1}')"
        cport="$(printf '%s' "$cached" | awk '{print $2}')"
        if test_vrhm_server_at "$cip" "$cport"; then
            echo "Using the last known VR HEADSET MANAGER server at $cip:$cport." >&2
            printf 'http://%s:%s\n' "$cip" "$cport"
            return 0
        fi
    fi

    while true; do
        local found fip fport
        found="$(find_vrhm_server_on_lan "$SERVER_PORT")"
        if [ -n "$found" ]; then
            fip="$(printf '%s' "$found" | awk '{print $1}')"
            fport="$(printf '%s' "$found" | awk '{print $2}')"
            echo "Found VR HEADSET MANAGER server at $fip:$fport." >&2
            write_vrhm_server_cache "$fip" "$fport"
            printf 'http://%s:%s\n' "$fip" "$fport"
            return 0
        fi

        echo "" >&2
        echo "No VR HEADSET MANAGER server was found on the network." >&2
        echo "  [R] Restart the search" >&2
        echo "  [I] Enter the server IP manually" >&2
        echo "  Ctrl+C to stop this script" >&2
        local choice manual_ip
        read -r -p "Choice: " choice </dev/tty

        case "$choice" in
            [Ii]*)
                read -r -p "Server IP address: " manual_ip </dev/tty
                if [[ "$manual_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    write_vrhm_server_cache "$manual_ip" "$SERVER_PORT"
                    printf 'http://%s:%s\n' "$manual_ip" "$SERVER_PORT"
                    return 0
                fi
                echo "'$manual_ip' is not a valid IPv4 address." >&2
                ;;
            *)
                # [R], or anything else, or empty input -> restart the search
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 8. Start the browser
# ---------------------------------------------------------------------------
echo ""
echo "Stopping any previous kiosk Chromium / port relay on port $PORT..."
stop_existing_browser

echo ""
start_kiosk_browser
echo ""
update_port_redirect

echo ""
echo "Kiosk Chromium started. This PC can be discovered and controlled from"
echo "VR HEADSET MANAGER's Kiosk Screens feature on port $PORT."
echo ""
echo "Hostname : $HOST_NAME"
echo "OS       : $OS_DESCRIPTION"

CURRENT_SERVER_URL="$(resolve_vrhm_server_url)"
echo "Server   : $CURRENT_SERVER_URL (reporting every ${REPORT_INTERVAL}s)"

if [ "$AUTO_RESTART" = "1" ]; then
    echo "Browser  : auto-restart enabled"
else
    echo "Browser  : auto-restart DISABLED"
fi
echo ""
echo "Agent running in the foreground. Closing this terminal stops the reporting"
echo "and the browser watchdog - see the README for the systemd unit. Ctrl+C to stop."
echo ""

cleanup() {
    # Single cleanup path for every exit - Ctrl+C/TERM, remote agent-stop, and the
    # browser-watchdog give-up all reach here. Same end state as the operator
    # sending "Stop kiosk" from the server: browser closed, port redirect and
    # firewall rule removed. stop_existing_browser/remove_port_redirect are
    # idempotent, so it is harmless that EXIT can fire this a second time after
    # INT/TERM already ran it once.
    echo ""
    echo "Kiosk agent stopping - cleaning up."
    stop_existing_browser
    remove_port_redirect
    if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -qi "^Status: active"; then
        sudo ufw delete allow "${PORT}/tcp" >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
        sudo firewall-cmd --permanent --remove-port="${PORT}/tcp" >/dev/null 2>&1 || true
        sudo firewall-cmd --reload >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1; then
        sudo iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 9. Agent loop. One tick per second: browser watchdog every tick, report to the
#    server every $REPORT_INTERVAL.
# ---------------------------------------------------------------------------
TICKS_UNTIL_REPORT=0
LAST_COMMAND_NONCE=""
LAST_REPORT_OK="1"
REPORT_FAILURES=0
MAX_REPORT_BACKOFF=60
BROWSER_DEAD_SINCE=""

while true; do

    if [ "$AGENT_STOP_REQUESTED" = "1" ]; then
        break
    fi

    # ---- Browser watchdog ----
    if browser_alive; then BROWSER_IS_ALIVE="true"; else BROWSER_IS_ALIVE="false"; fi

    if [ "$BROWSER_RESTART_REQUESTED" = "1" ]; then
        BROWSER_RESTART_REQUESTED="0"
        restart_kiosk_browser "operator request" || true
        BROWSER_DEAD_SINCE=""
    elif [ "$BROWSER_IS_ALIVE" = "false" ]; then
        if [ "$AUTO_RESTART" = "0" ]; then
            echo ""
            echo "Kiosk Chromium has exited and auto-restart is disabled - cleaning up."
            break
        fi
        # Short grace period: a browser-initiated restart, or a slow shutdown,
        # should not race the watchdog into launching a second instance.
        if [ -z "$BROWSER_DEAD_SINCE" ]; then
            BROWSER_DEAD_SINCE="$(date +%s)"
            echo "Kiosk Chromium is not running - relaunching shortly..."
        elif [ $(( $(date +%s) - BROWSER_DEAD_SINCE )) -ge 3 ]; then
            restart_kiosk_browser "watchdog" || true
            BROWSER_DEAD_SINCE=""
            echo "Kiosk Chromium relaunched by the watchdog."
        fi
    else
        BROWSER_DEAD_SINCE=""
    fi

    # ---- Report + command collection ----
    TICKS_UNTIL_REPORT=$(( TICKS_UNTIL_REPORT - 1 ))
    if [ "$TICKS_UNTIL_REPORT" -le 0 ]; then
        BACKOFF_MULTIPLIER=1
        BACKOFF_STEPS="$REPORT_FAILURES"
        [ "$BACKOFF_STEPS" -gt 4 ] && BACKOFF_STEPS=4
        while [ "$BACKOFF_STEPS" -gt 0 ]; do
            BACKOFF_MULTIPLIER=$(( BACKOFF_MULTIPLIER * 2 ))
            BACKOFF_STEPS=$(( BACKOFF_STEPS - 1 ))
        done
        BACKOFF=$(( REPORT_INTERVAL * BACKOFF_MULTIPLIER ))
        [ "$BACKOFF" -gt "$MAX_REPORT_BACKOFF" ] && BACKOFF="$MAX_REPORT_BACKOFF"
        if [ "$REPORT_FAILURES" -gt 0 ]; then
            JITTER=$(( RANDOM % 4 ))
        else
            JITTER=0
        fi
        TICKS_UNTIL_REPORT=$(( BACKOFF + JITTER ))
        [ "$TICKS_UNTIL_REPORT" -gt "$MAX_REPORT_BACKOFF" ] && TICKS_UNTIL_REPORT="$MAX_REPORT_BACKOFF"

        CURRENT_URL="$(cdp_current_url)"

        if [ -n "$CURRENT_SERVER_URL" ]; then
            REPLY_BODY="$(send_report "$CURRENT_SERVER_URL" "$(build_report "$CURRENT_SERVER_URL" "$BROWSER_IS_ALIVE" "$CURRENT_URL")")"

            if printf '%s' "$REPLY_BODY" | grep -q '"ok"'; then
                if [ "$LAST_REPORT_OK" = "0" ]; then
                    echo "Reporting to $CURRENT_SERVER_URL restored."
                fi
                LAST_REPORT_OK="1"
                REPORT_FAILURES=0
                TICKS_UNTIL_REPORT="$REPORT_INTERVAL"

                CMD="$(json_field_string "$REPLY_BODY" "cmd")"
                if [ -n "$CMD" ]; then
                    NONCE="$(json_field_number "$REPLY_BODY" "nonce")"
                    DELAY="$(json_field_number "$REPLY_BODY" "delaySec")"
                    [ -z "$DELAY" ] && DELAY=5

                    if [ "$NONCE" != "$LAST_COMMAND_NONCE" ]; then
                        LAST_COMMAND_NONCE="$NONCE"
                        # Acknowledge BEFORE acting: a reboot gives no second chance.
                        send_report "$CURRENT_SERVER_URL" \
                            "$(build_report "$CURRENT_SERVER_URL" "$BROWSER_IS_ALIVE" "$CURRENT_URL" "$CMD" "$NONCE" "ok")" >/dev/null
                        invoke_kiosk_command "$CMD" "$DELAY"
                    fi
                fi
            else
                REPORT_FAILURES=$(( REPORT_FAILURES + 1 ))
                if [ "$LAST_REPORT_OK" = "1" ]; then
                    echo "Cannot reach the VR HEADSET MANAGER server at $CURRENT_SERVER_URL - will keep retrying." >&2
                    LAST_REPORT_OK="0"
                fi
            fi
        fi

        # ---- Sentinel fallback ----
        # Kept as defense-in-depth for the case reporting to $CURRENT_SERVER_URL
        # is failing (e.g. it went stale after this ran) - a page pushed to this
        # screen over CDP still carries a command, and matching its URL re-teaches
        # us the server address too.
        case "$CURRENT_URL" in
            *kiosk_command.html\?*)
                S_CMD="$(printf '%s' "$CURRENT_URL" | sed -n 's/.*[?&]cmd=\([a-zA-Z-]*\).*/\1/p')"
                S_NONCE="$(printf '%s' "$CURRENT_URL" | sed -n 's/.*[?&]nonce=\([0-9]*\).*/\1/p')"
                if [ -n "$S_CMD" ] && [ "$S_NONCE" != "$LAST_COMMAND_NONCE" ]; then
                    LAST_COMMAND_NONCE="$S_NONCE"
                    if [ -z "$CURRENT_SERVER_URL" ]; then
                        CURRENT_SERVER_URL="$(printf '%s' "$CURRENT_URL" | sed -e 's|\(^[a-zA-Z]*://[^/]*\).*|\1|')"
                        echo "Learned the VR HEADSET MANAGER server address: $CURRENT_SERVER_URL"
                    fi
                    echo "Command '$S_CMD' received on the fallback channel."
                    invoke_kiosk_command "$S_CMD" 5
                fi
                ;;
        esac
    fi

    sleep 1
done
