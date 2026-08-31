#!/usr/bin/env bash
#
# Start-KioskChrome-Linux.sh
#
# Standalone setup script for a kiosk screen running Debian or Raspberry Pi
# OS (Raspbian). Copy this single file to the kiosk PC and run it from a
# normal graphical desktop session (it needs a DISPLAY to show the browser
# window - see the accompanying README for details on autostart / SSH use).
#
# What it does:
#   1. Detects Chromium/Chrome and locates the binary automatically.
#   2. Opens the firewall for the Chrome remote debugging port (ufw,
#      firewalld, or plain iptables - whichever is present), asking for
#      sudo only when a privileged command is actually needed.
#   3. Launches Chromium in kiosk mode with remote debugging enabled,
#      pointed at the given start URL.
#   4. Verifies the debug port actually became reachable from the LAN.
#      Recent Chromium builds silently ignore --remote-debugging-address
#      and hard-lock the debug listener to 127.0.0.1 for security
#      (see https://issues.chromium.org/issues/40242234). When that
#      happens, this script redirects LAN connections to the loopback
#      listener with an iptables DNAT rule (nothing to install - the same
#      "iptables" already used for the firewall step above) - the same
#      goal as the Windows counterpart script (Start-KioskChrome.ps1,
#      which uses "netsh interface portproxy").
#
# Usage:
#   ./Start-KioskChrome-Linux.sh [URL] [PORT]
#
# Examples:
#   ./Start-KioskChrome-Linux.sh
#   ./Start-KioskChrome-Linux.sh "https://example.com" 9222
#
# Safe to re-run any time (after a reboot, to change the URL, etc). Any
# previous kiosk Chromium and any previous port-redirect rule for the same
# port are stopped/removed first.

set -u

# ---------------------------------------------------------------------------
# 0. Arguments
# ---------------------------------------------------------------------------
URL="${1:-data:text/html,%3Chtml%3E%3Chead%3E%3Cmeta%20charset%3D'utf-8'%3E%3Ctitle%3EKiosk%3C%2Ftitle%3E%3Cstyle%3Ehtml%2Cbody%7Bmargin%3A0%3Bheight%3A100%25%3Bbackground%3A%23000%3Bcolor%3A%23fff%3Bdisplay%3Aflex%3Balign-items%3Acenter%3Bjustify-content%3Acenter%3Bfont-family%3Asystem-ui%2Csans-serif%3Bflex-direction%3Acolumn%7Dh1%7Bfont-size%3A3vw%3Bletter-spacing%3A.08em%3Btext-transform%3Auppercase%3Bcolor%3A%23888%3Bmargin%3A0%7Dh2%7Bfont-size%3A5vw%3Bfont-weight%3A700%3Bmargin%3A12px%200%200%7D%3C%2Fstyle%3E%3C%2Fhead%3E%3Cbody%3E%3Ch1%3EKiosk%20Mode%3C%2Fh1%3E%3Ch2%3EReady%20to%20stream%3C%2Fh2%3E%3C%2Fbody%3E%3C%2Fhtml%3E}"
PORT="${2:-9222}"

echo "=== VRHM Kiosk Chrome setup (Linux) ==="
echo "URL:  $URL"
echo "Port: $PORT"
echo ""

# ---------------------------------------------------------------------------
# 1. Identify the real desktop user and DISPLAY, in case this script was
#    itself launched via sudo (we never want to run the browser as root -
#    Chromium refuses to start as root unless --no-sandbox is passed, which
#    weakens the sandbox, and root usually cannot attach to the desktop
#    user's X/Wayland session anyway).
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    TARGET_USER="${SUDO_USER:-}"
    if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
        echo "This script was started as root and no other desktop user could be" >&2
        echo "identified. Please run it as your normal desktop user instead (the" >&2
        echo "script will ask for your sudo password only for the steps that need" >&2
        echo "it - firewall rules and the port relay, if required)." >&2
        exit 1
    fi
    RUN_AS_USER="sudo -u $TARGET_USER"
else
    TARGET_USER="$(id -un)"
    RUN_AS_USER=""
fi

# Resolve DISPLAY/XAUTHORITY/WAYLAND_DISPLAY for the target user if not
# already set in this shell (covers the case where the script is run from
# a plain SSH session without X forwarding, on a machine with an active
# local graphical session for that user).
if [ -z "${DISPLAY:-}" ]; then
    DISPLAY=":0"
fi
if [ -z "${XAUTHORITY:-}" ]; then
    XAUTHORITY="$(eval echo "~$TARGET_USER")/.Xauthority"
fi

# ---------------------------------------------------------------------------
# 2. Locate Chromium / Chrome
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
                echo "(older Raspberry Pi OS releases use the package name chromium-browser instead)" >&2
                exit 1
            fi
            ;;
        *)
            echo "Install one first, for example on Debian/Raspberry Pi OS:" >&2
            echo "  sudo apt-get update && sudo apt-get install -y chromium" >&2
            echo "(older Raspberry Pi OS releases use the package name chromium-browser instead)" >&2
            exit 1
            ;;
    esac
fi

echo "Chromium found at: $CHROME_BIN"

# ---------------------------------------------------------------------------
# 3. Open the firewall for the debug port (ufw, then firewalld, then
#    plain iptables - whichever is present). Uses sudo only for this step.
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

# ---------------------------------------------------------------------------
# 4. Stop any previous kiosk Chromium and port relay on this port
# ---------------------------------------------------------------------------
echo ""
echo "Stopping any previous kiosk Chromium / port relay on port $PORT..."

pkill -f "remote-debugging-port=$PORT" 2>/dev/null || true
pkill -f "socat.*:$PORT," 2>/dev/null || true
sleep 1

# ---------------------------------------------------------------------------
# 5. Launch Chromium in kiosk mode with remote debugging enabled
# ---------------------------------------------------------------------------
USER_DATA_DIR="$(eval echo "~$TARGET_USER")/.config/vrhm-kiosk-chrome"
mkdir -p "$USER_DATA_DIR" 2>/dev/null || true

# When Chromium is closed via the CDP "Browser.close" call (the Kiosk
# Screens "Stop kiosk session" button on a basic kiosk) instead of this script's own pkill,
# it can leave this profile's SingletonLock/SingletonSocket/SingletonCookie
# files behind. A later launch then silently hands off to (or is blocked
# by) that stale lock instead of starting a genuinely fresh, debug-enabled
# process - Chromium opens and the kiosk display looks fine, but the new
# debug listener never actually comes up, so the server can no longer
# reach it. Clearing these before every launch guarantees a real fresh
# instance each time.
for lockFile in SingletonLock SingletonSocket SingletonCookie; do
    rm -f "$USER_DATA_DIR/$lockFile" 2>/dev/null || true
done

# A hard power loss (unplugging the kiosk instead of a clean shutdown) leaves
# this profile's Preferences file with exit_type=Crashed. Recent Chromium
# builds ignore --disable-session-crashed-bubble and always show the
# "Restore pages?" popup based on that stored exit_type, regardless of CLI
# flags. Rewrite it to a clean state before every launch so the popup never
# appears, no matter how the previous run ended.
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

echo ""
echo "Starting Chromium in kiosk mode..."

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
    "$URL" >/dev/null 2>&1 &

CHROME_PID=$!
disown

# ---------------------------------------------------------------------------
# 6. Verify the debug port is reachable from the LAN, not just loopback.
#    Recent Chromium silently ignores --remote-debugging-address and stays
#    on 127.0.0.1 regardless (see script header). If that happens, redirect
#    incoming LAN connections to the loopback listener with an iptables DNAT
#    rule - built into every Linux distro's netfilter stack already used
#    elsewhere in this script (the firewall step above), so nothing needs
#    to be installed from the internet to make this work.
# ---------------------------------------------------------------------------
echo ""
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

# Always remove any previous redirect for this port before deciding whether
# a new one is needed, so re-running this script stays idempotent. The
# "-m comment" tag is added both here and when the rule is created below,
# so this exact-match delete is reliable. Also clean up a socat relay left
# running by an older version of this script.
sudo iptables -t nat -D PREROUTING -p tcp --dport "$PORT" -j DNAT --to-destination "127.0.0.1:$PORT" -m comment --comment "VRHM_KIOSK_DEBUGPORT" 2>/dev/null || true
pkill -f "socat.*:$PORT," 2>/dev/null || true

if [ -n "$LISTEN_LINE" ] && echo "$LISTEN_LINE" | grep -q "127.0.0.1:$PORT"; then
    echo "Chromium is only listening on 127.0.0.1:$PORT (LAN binding was ignored by this Chromium build)."
    echo "Redirecting LAN connections on port $PORT to the loopback listener (iptables DNAT)..."

    # The kernel treats a packet whose destination becomes 127.0.0.1 as
    # "martian" and drops it unless route_localnet is enabled - and it must
    # be set per already-up interface, not just "all", to take effect.
    sudo sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
    for iface in $(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$'); do
        sudo sysctl -w "net.ipv4.conf.${iface}.route_localnet=1" >/dev/null 2>&1 || true
    done

    if sudo iptables -t nat -A PREROUTING -p tcp --dport "$PORT" -j DNAT --to-destination "127.0.0.1:$PORT" -m comment --comment "VRHM_KIOSK_DEBUGPORT"; then
        sleep 1
        if command -v nc >/dev/null 2>&1 && nc -z -w2 127.0.0.1 "$PORT" 2>/dev/null; then
            echo "Port redirect active: LAN:$PORT -> 127.0.0.1:$PORT (iptables DNAT)"
        else
            echo "iptables DNAT rule added for port $PORT. Could not double-confirm reachability locally - test from another LAN device."
        fi
    else
        echo "Could not add the iptables DNAT rule for port $PORT." >&2
        echo "Check 'sudo iptables -t nat -L PREROUTING -n' manually, and that this Pi's kernel has NAT support." >&2
    fi
elif [ -n "$LISTEN_LINE" ]; then
    echo "Chromium is listening on a LAN-reachable address - already reachable from the network."
else
    echo "Could not confirm Chromium is listening on port $PORT yet. Give it a few seconds and re-check with:" >&2
    echo "  ss -ltn | grep $PORT" >&2
fi

echo ""
echo "Kiosk Chromium started. This PC can now be discovered and controlled from"
echo "VR HEADSET MANAGER's Kiosk Screens feature on port $PORT."
echo ""

# ---------------------------------------------------------------------------
# 7. Watch the kiosk Chromium process in the background and tear down the
#    DNAT redirect when it exits, instead of leaving a dangling rule pointed
#    at a dead listener until the operator manually re-runs the script (for
#    example after remotely killing the browser via CDP Browser.close). This
#    is best-effort: if a background sudo call fails here (no cached
#    credential), the next script run's own cleanup step removes it anyway.
# ---------------------------------------------------------------------------
(
    while kill -0 "$CHROME_PID" 2>/dev/null; do
        sleep 1
    done
    sudo iptables -t nat -D PREROUTING -p tcp --dport "$PORT" -j DNAT --to-destination "127.0.0.1:$PORT" -m comment --comment "VRHM_KIOSK_DEBUGPORT" 2>/dev/null || true
) >/dev/null 2>&1 &
disown

echo "This terminal can be closed now - a background watcher will clean up"
echo "the port redirect automatically once Chromium exits."
