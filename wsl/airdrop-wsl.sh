#!/usr/bin/env bash
# AirDrop inside WSL2 on a USB Wi-Fi adapter passed through with usbipd-win.
#
#   airdrop-wsl.sh receive              # appear on the iPhone's share sheet
#   airdrop-wsl.sh send FILE [FILE...]  # send to an iPhone in "Everyone" mode
#   airdrop-wsl.sh find                 # list AirDrop receivers in range
#   airdrop-wsl.sh doctor               # check every layer, change nothing
#
# Normally started from Windows by windows\AirDrop.ps1, which attaches the
# adapter and passes the settings below. Run as root.
#
# The adapter is dedicated to AWDL while this runs: Windows keeps its internet
# on the internal Wi-Fi, so there is no managed link to share a channel with.
#
# Settings (environment):
#   AIRDROP_NAME   name the phone shows                (default: Windows host name)
#   RECV_DIR       where received files go            (default: /root/AirDrop)
#   REG            regulatory country                 (default: ES)
#   CHAN           AWDL channel 6/44/149; unset = sweep for the busiest one
#   RECV_TIME      seconds to stay receiving, 0 = until Ctrl-C   (default: 0)
#   RECEIVER       send target, by name or ID         (default: first found)
#   FIND_TIME      give up discovery after this long  (default: 45)
#   STRATEGY       owl channel strategy (verbatim|widen) (default: verbatim)
#   VIF_MODE       auto|native|pair; pair is forced on mt7921u (default: auto)
#   IFACE          adapter interface                  (default: detected)
#   AIRDROP_CONFIRM  accept prompt hook; "none" accepts everything
#                    (default: confirm-windows.sh, a Windows dialog)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
MODE="${1:-receive}"; shift || true

PREFIX="${PREFIX:-/opt/airdrop}"          # where wsl/setup-wsl.sh installs
OWL="${OWL:-$PREFIX/owl/build/daemon/owl}"
OPENDROP="${OPENDROP:-$PREFIX/venv/bin/opendrop}"
REG="${REG:-ES}"
RECV_DIR="${RECV_DIR:-/root/AirDrop}"
RECV_TIME="${RECV_TIME:-0}"
FIND_TIME="${FIND_TIME:-45}"
STRATEGY="${STRATEGY:-verbatim}"
VIF_MODE="${VIF_MODE:-auto}"
RUN_DIR="${RUN_DIR:-/var/log/airdrop/$(date +%Y%m%d-%H%M%S)-$MODE}"
AWDL=awdl0 MON=mon0 MONA=mon1
AWDL_BSSID="00:25:00:ff:94:73"    # every AWDL frame carries it as addr3
DRIVERS=(mt7921u mt76x2u mt76x0u ath9k_htc rt2800usb)

if [ -z "${AIRDROP_NAME:-}" ]; then
    AIRDROP_NAME="$(powershell.exe -NoProfile -Command '$env:COMPUTERNAME' 2>/dev/null | tr -d '\r')"
    AIRDROP_NAME="${AIRDROP_NAME:-$(hostname)}"
fi
# The name goes into mDNS and into the phone's UI; apostrophes have been seen
# to break the share sheet entry.
AIRDROP_NAME="${AIRDROP_NAME//\'/}"
export AIRDROP_CONFIRM="${AIRDROP_CONFIRM-$HERE/confirm-windows.sh}"
[ "$AIRDROP_CONFIRM" = none ] && unset AIRDROP_CONFIRM
export AIRDROP_URL_HOOK="${AIRDROP_URL_HOOK:-$HERE/open-url-windows.sh}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n### %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (wsl -u root ...)"
[ -x "$OWL" ] || die "no owl binary at $OWL - run wsl/setup-wsl.sh"
[ -x "$OPENDROP" ] || die "no opendrop at $OPENDROP - run wsl/setup-wsl.sh"
mkdir -p "$RUN_DIR"

chan_mhz() { case "$1" in 6) echo 2437;; 36) echo 5180;; 44) echo 5220;; 149) echo 5745;; *) return 1;; esac; }

# ---------------------------------------------------------------- the adapter
find_iface() {
    local d drv
    for d in /sys/class/net/*/phy80211; do
        [ -e "$d" ] || continue
        local i; i="$(basename "$(dirname "$d")")"
        case "$i" in "$MON"|"$MONA"|"$AWDL") continue;; esac
        drv="$(basename "$(readlink -f "/sys/class/net/$i/device/driver")" 2>/dev/null)"
        echo "$i $drv"; return 0
    done
    return 1
}

# The kernel loads firmware from the WSL VM's root mount namespace, not from
# this distro, so Ubuntu's /lib/firmware is invisible to it ("Direct firmware
# load ... failed with error -2"). /mnt/wsl is a tmpfs shared with that
# namespace: stage the blobs there and point the loader at it. This has to
# happen before the adapter is attached - the driver asks for its firmware
# at probe time - and again after every WSL restart, since both the tmpfs
# and the module parameter are lost then.
FW_STAGE=/mnt/wsl/airdrop-firmware
prepare() {
    mkdir -p "$FW_STAGE"
    (cd /lib/firmware && cp --parents -u regulatory.db regulatory.db.p7s htc_9271.fw \
        rt2870.bin ath9k_htc/*.fw mediatek/mt7610u.bin mediatek/mt7662u*.bin \
        mediatek/WIFI_*MT7961*.bin "$FW_STAGE"/ 2>/dev/null)
    echo -n "$FW_STAGE" > /sys/module/firmware_class/parameters/path
    modprobe -q cfg80211; modprobe -q mac80211; modprobe -q tun
    for m in "${DRIVERS[@]}"; do modprobe -q "$m" 2>/dev/null; done
    # cfg80211 may have come up before the path was set, on the world domain
    # that forbids transmitting anywhere on 5 GHz. Setting the country makes
    # it read regulatory.db again.
    iw reg set "$REG"
    for _ in $(seq 10); do iw reg get | grep -q "country $REG" && return 0; sleep 0.3; done
    echo "WARNING: regulatory domain $REG not applied; 5 GHz AWDL channels stay passive" >&2
}

step "layer 0: USB Wi-Fi adapter"
prepare
[ "$MODE" = prepare ] && { trap - EXIT; say "  firmware staged in $FW_STAGE, drivers loaded"; exit 0; }
FOUND=""
for i in $(seq 20); do
    FOUND="$(find_iface)" && break
    # Attached before prepare ran (e.g. by hand): the probe failed for lack
    # of firmware. Reloading the drivers re-probes the device.
    if [ "$i" = 5 ]; then
        for m in "${DRIVERS[@]}"; do modprobe -r -q "$m" 2>/dev/null; modprobe -q "$m" 2>/dev/null; done
    fi
    sleep 1
done
if [ -n "${IFACE:-}" ]; then
    DRV="$(basename "$(readlink -f "/sys/class/net/$IFACE/device/driver")" 2>/dev/null)"
elif [ -n "$FOUND" ]; then
    read -r IFACE DRV <<<"$FOUND"
else
    say "  no Wi-Fi interface in WSL. USB devices WSL can see:"
    lsusb 2>/dev/null | sed 's/^/    /'
    die "attach the adapter first (windows\\AirDrop.ps1 does it), or it has no driver here"
fi
PHY="$(basename "$(readlink -f "/sys/class/net/$IFACE/phy80211")")"
say "  $IFACE on $PHY, driver $DRV"
iw phy "$PHY" info | grep -q "monitor" || die "$DRV does not offer monitor mode"
case "$VIF_MODE:$DRV" in
    auto:mt7921u|auto:mt7921*) VIF_MODE=pair ;;
    auto:*) VIF_MODE=native ;;
esac
say "  vif mode: $VIF_MODE"

# ------------------------------------------------------------------- cleanup
restore() {
    trap '' INT TERM
    pkill -x owl 2>/dev/null
    pkill -f "tcpdump -i ($AWDL|$MON)" 2>/dev/null
    [ -n "${TIDY_PID:-}" ] && kill "$TIDY_PID" 2>/dev/null
    iw dev "$MONA" del 2>/dev/null
    iw dev "$MON" del 2>/dev/null
    ip link set "$IFACE" down 2>/dev/null
    iw dev "$IFACE" set type managed 2>/dev/null
    [ -n "${MT76:-}" ] && { echo 1 > "$MT76/runtime-pm"; echo 1 > "$MT76/deep-sleep"; } 2>/dev/null
    say ""; say "logs: $RUN_DIR"
}
trap restore EXIT
trap 'exit 130' INT TERM

if [ "$MODE" = doctor ]; then
    step "doctor"
    say "  owl:      $OWL"
    say "  opendrop: $OPENDROP ($("$PREFIX/venv/bin/pip" show opendrop 2>/dev/null | grep -m1 Location))"
    iw phy "$PHY" info | grep -qi "active monitor\|ACTIVE_MONITOR" \
        && say "  driver advertises active monitor" \
        || say "  driver does not advertise active monitor (pair mode may still work)"
    iw phy "$PHY" info | grep -E "^\s+\* (2437|5220|5745) MHz" | sed 's/^/  /'
fi

# ------------------------------------------------------------ layer 1: radio
step "layer 1: radio"
iw reg set "$REG"
ip link set "$IFACE" down
iw dev "$MON" del 2>/dev/null
iw phy "$PHY" interface add "$MON" type monitor || die "could not create $MON"
ip link set "$MON" up || die "could not bring $MON up"
MT76=""
if [ -d "/sys/kernel/debug/ieee80211/$PHY/mt76" ]; then
    # mt76 runtime power management silently stops monitor reception.
    MT76="/sys/kernel/debug/ieee80211/$PHY/mt76"
    { echo 0 > "$MT76/runtime-pm"; echo 0 > "$MT76/deep-sleep"; } 2>/dev/null
fi

if [ -z "${CHAN:-}" ]; then
    say "  sweeping AWDL channels (keep the phone's share sheet open)"
    BEST=""; BEST_N=0
    for c in 149 44 6; do
        iw dev "$MON" set freq "$(chan_mhz "$c")" 2>/dev/null || { say "  ch $c: not allowed here"; continue; }
        n="$(timeout 5 tcpdump -i "$MON" -c 300 "wlan addr3 $AWDL_BSSID" 2>/dev/null | wc -l)"
        say "  ch $c: $n AWDL frames"
        [ "$n" -gt "$BEST_N" ] && { BEST="$c"; BEST_N="$n"; }
        [ "$n" -ge 100 ] && break
    done
    if [ -z "$BEST" ]; then
        say "  no AWDL traffic anywhere. Unlock the phone, AirDrop > Everyone for"
        say "  10 Minutes, and open a share sheet (that is what wakes its AWDL)."
        [ "$MODE" = doctor ] && exit 1
        BEST=149
    fi
    CHAN="$BEST"
fi
CHAN_MHZ="$(chan_mhz "$CHAN")" || die "CHAN must be 6, 36, 44 or 149"
say "  using channel $CHAN ($CHAN_MHZ MHz)"
[ "$MODE" = doctor ] && { say "  radio OK"; exit 0; }

# -------------------------------------------------------------- layer 2: owl
step "layer 2: AWDL (owl, strategy $STRATEGY)"
if [ "$VIF_MODE" = pair ]; then
    # The plain vif owns the channel, the active one (created second, on the
    # same channel) ACKs and follows it - see FINDINGS in airdrop-mt7921.
    iw dev "$MON" set freq "$CHAN_MHZ"
    iw phy "$PHY" interface add "$MONA" type monitor flags active || die "could not create $MONA"
    ip link set "$MONA" up
    OWL_ARGS=(-i "$MONA" -N)
else
    # owl puts the interface in active monitor mode itself.
    iw dev "$MON" del
    OWL_ARGS=(-i "$IFACE")
fi
stdbuf -oL "$OWL" "${OWL_ARGS[@]}" -c "$CHAN" -S "$STRATEGY" -v > "$RUN_DIR/owl.log" 2>&1 &
for _ in $(seq 15); do ip link show "$AWDL" >/dev/null 2>&1 && break; sleep 1; done
ip link show "$AWDL" >/dev/null 2>&1 || { grep -iE "error|unable" "$RUN_DIR/owl.log" | head -5; die "owl did not create $AWDL"; }
ip link set "$AWDL" up
say "  $AWDL up ($(grep -m1 'Host device' "$RUN_DIR/owl.log" | sed 's/.*: *//'))"

# --------------------------------------------------------- layer 3: AirDrop
OD=("$OPENDROP" -n "$AIRDROP_NAME" -i "$AWDL")
export PYTHONUNBUFFERED=1

discover() {
    local report="$HOME/.opendrop/discover.last.json" before
    before="$(stat -c %Y "$report" 2>/dev/null || echo 0)"
    "${OD[@]}" find > "$RUN_DIR/find.log" 2>&1 &
    local pid=$! t=0
    tail -f --pid=$pid "$RUN_DIR/find.log" 2>/dev/null | sed 's/^/  /' &
    while [ $t -lt $((FIND_TIME * 2)) ] && kill -0 $pid 2>/dev/null; do
        grep -q "Found" "$RUN_DIR/find.log" && { sleep 2; break; }
        sleep 0.5; t=$((t + 1))
    done
    # find writes its report on SIGINT and then hangs in zeroconf.close():
    # wait for the report, not for the process.
    kill -INT $pid 2>/dev/null
    for _ in $(seq 80); do
        kill -0 $pid 2>/dev/null || break
        [ "$(stat -c %Y "$report" 2>/dev/null || echo 0)" -gt "$before" ] && break
        sleep 0.25
    done
    kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
    grep -q "Found" "$RUN_DIR/find.log"
}

case "$MODE" in
receive)
    step "layer 3: receiving as \"$AIRDROP_NAME\" into $RECV_DIR"
    say "  On the iPhone: AirDrop > Everyone for 10 Minutes, share sheet > AirDrop >"
    say "  \"$AIRDROP_NAME\". Ctrl+C to stop."
    mkdir -p "$RECV_DIR"
    if [ -x "$HERE/airdrop-tidy" ]; then
        "$HERE/airdrop-tidy" --watch "$RECV_DIR" > "$RUN_DIR/tidy.log" 2>&1 &
        TIDY_PID=$!
    fi
    tcpdump -i "$AWDL" -w "$RUN_DIR/receive.pcap" >/dev/null 2>&1 &
    if [ "$RECV_TIME" -gt 0 ]; then
        ( cd "$RECV_DIR" && timeout --foreground "$RECV_TIME" "${OD[@]}" receive ) 2>&1 | tee "$RUN_DIR/receive.log"
    else
        ( cd "$RECV_DIR" && "${OD[@]}" receive ) 2>&1 | tee "$RUN_DIR/receive.log"
    fi
    [ -x "$HERE/airdrop-tidy" ] && AIRDROP_TIDY_SETTLE=0 "$HERE/airdrop-tidy" "$RECV_DIR" | sed 's/^/  /'
    ;;
find)
    step "layer 3: looking for receivers (${FIND_TIME}s max)"
    discover || { say "  nobody found. The phone must be unlocked, AirDrop on Everyone, share sheet CLOSED."; exit 1; }
    ;;
send)
    [ $# -gt 0 ] || die "send needs at least one file"
    FILES=()
    for f in "$@"; do [ -f "$f" ] || die "no such file: $f"; FILES+=(-f "$f"); done
    step "layer 3: looking for the receiver"
    discover || { say "  nobody found. The phone must be unlocked, AirDrop on Everyone, share sheet CLOSED."; exit 1; }
    ID="$(grep -oP 'Found\s+index\s+\S+\s+ID\s+\K[0-9a-f]{12}' "$RUN_DIR/find.log" | head -1)"
    TARGET="${RECEIVER:-${ID:-0}}"
    step "layer 4: sending ${#FILES[@]} item(s) to \"$TARGET\" (accept on the phone)"
    tcpdump -i "$AWDL" -w "$RUN_DIR/send.pcap" >/dev/null 2>&1 &
    "${OD[@]}" send -r "$TARGET" "${FILES[@]}" 2>&1 | tee "$RUN_DIR/send.log"
    exit "${PIPESTATUS[0]}"
    ;;
*)
    die "unknown mode $MODE (receive|send|find|doctor)"
    ;;
esac
