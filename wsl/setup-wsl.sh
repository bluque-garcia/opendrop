#!/usr/bin/env bash
# One-time (and after every `wsl --update`) setup of the AirDrop stack in WSL.
#
#   wsl -u root -- bash /mnt/c/.../opendrop/wsl/setup-wsl.sh
#
# Installs into $PREFIX (/opt/airdrop):
#   owl/   the AWDL daemon, built from the owl fork with the iOS 26 fixes
#   venv/  this OpenDrop checkout, installed editable, so a `git pull` of the
#          repo takes effect without reinstalling
# and builds the USB Wi-Fi drivers for the running kernel.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
PREFIX="${PREFIX:-/opt/airdrop}"
OWL_REPO="${OWL_REPO:-https://github.com/bluque-garcia/owl.git}"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

echo ">> packages"
export DEBIAN_FRONTEND=noninteractive
# A broken third-party apt source must not stop the install; the packages
# below all come from Ubuntu itself.
apt-get update -qq || true
apt-get install -y -qq python3-venv python3-dev libarchive13t64 build-essential \
    cmake git pkg-config libpcap-dev libev-dev libnl-3-dev libnl-genl-3-dev \
    libnl-route-3-dev iw tcpdump wireless-regdb usbutils kmod zstd \
    flex bison libelf-dev libssl-dev bc dwarves cpio rsync linux-firmware

echo ">> owl"
mkdir -p "$PREFIX"
if [ -d "$PREFIX/owl/.git" ]; then
    git -C "$PREFIX/owl" pull -q --ff-only
else
    git clone -q --recursive "$OWL_REPO" "$PREFIX/owl"
fi
cmake -S "$PREFIX/owl" -B "$PREFIX/owl/build" -DCMAKE_BUILD_TYPE=Release -Wno-dev >/dev/null
# Only the daemon: the vendored googletest does not build with current GCC.
cmake --build "$PREFIX/owl/build" --target owl -j"$(nproc)" >/dev/null
"$PREFIX/owl/build/daemon/owl" -S bogus >/dev/null 2>&1 || true   # links and runs

echo ">> opendrop ($REPO)"
[ -x "$PREFIX/venv/bin/python" ] || python3 -m venv "$PREFIX/venv"
"$PREFIX/venv/bin/pip" install -q --upgrade pip
"$PREFIX/venv/bin/pip" install -q -e "$REPO"
"$PREFIX/venv/bin/opendrop" --help >/dev/null

chmod +x "$HERE"/*.sh "$HERE/airdrop-tidy"

echo ">> Wi-Fi drivers"
bash "$HERE/build-wifi-modules.sh"

echo ""
echo "done. Attach the adapter from Windows and run:  windows\\AirDrop.cmd"
