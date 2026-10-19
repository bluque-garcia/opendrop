#!/usr/bin/env bash
# Build USB Wi-Fi drivers for the running WSL2 kernel and install them.
#
# The stock WSL2 kernel ships cfg80211/mac80211 and USB/IP as modules but no
# Wi-Fi drivers. This builds the ones for adapters known to do active monitor
# mode with frame injection (what OWL needs) from Microsoft's tree at the exact
# tag of the running kernel, so vermagic and symbol CRCs match the shipped
# modules and nothing but the new drivers is installed.
#
# Run as root inside WSL:  sudo ./wsl/build-wifi-modules.sh
# Rerun after every WSL kernel update (`wsl --update` changes uname -r).
set -euo pipefail

KVER="$(uname -r)"
TAG="linux-msft-wsl-${KVER%-microsoft-standard-WSL2}"
SRC="${SRC:-/usr/src/wsl-kernel-${KVER}}"
DEST="/lib/modules/${KVER}/updates/airdrop"

# Drivers to build. Each is an adapter family with a working monitor + inject
# path in mainline: AR9271, MT7610U, MT7612U, MT7921AU, RT5370/RT5572.
DRIVERS=(ATH9K_HTC MT76x0U MT76x2U MT7921U RT2800USB)
EXTRA_ON=(WLAN_VENDOR_ATH WLAN_VENDOR_MEDIATEK WLAN_VENDOR_RALINK RT2X00
          RT2800USB_RT3573 RT2800USB_RT53XX RT2800USB_RT55XX)

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
command -v zstd >/dev/null || apt-get install -y -qq zstd

if [ ! -d "$SRC/.git" ]; then
    echo ">> cloning $TAG"
    git clone --depth 1 --branch "$TAG" \
        https://github.com/microsoft/WSL2-Linux-Kernel.git "$SRC"
fi
cd "$SRC"

zcat /proc/config.gz > .config
# --keep-case: scripts/config upper-cases names by default, and MT76x0U is not
# MT76X0U.
for opt in "${EXTRA_ON[@]}"; do scripts/config --keep-case --enable "$opt"; done
for opt in "${DRIVERS[@]}"; do scripts/config --keep-case --module "$opt"; done
make olddefconfig >/dev/null

for opt in "${DRIVERS[@]}"; do
    grep -q "^CONFIG_${opt}=m" .config || { echo "CONFIG_${opt} did not stick" >&2; exit 1; }
done

# A shallow clone at a tag must not pick up a "+" from setlocalversion, or the
# modules are refused with "disagrees about version of symbol module_layout".
touch .scmversion
REL="$(make -s kernelrelease LOCALVERSION=)"
[ "$REL" = "$KVER" ] || { echo "kernelrelease $REL != running $KVER" >&2; exit 1; }

echo ">> building modules (this takes a while the first time)"
make -j"$(nproc)" LOCALVERSION= modules >/var/log/airdrop-kbuild.log 2>&1 \
    || { tail -40 /var/log/airdrop-kbuild.log; exit 1; }

# Install only the wireless drivers; the cfg80211/mac80211 the kernel ships
# stay authoritative.
mkdir -p "$DEST"
find drivers/net/wireless -name '*.ko' -exec install -m 644 {} "$DEST"/ \;
depmod -a "$KVER"

echo ">> installed into $DEST:"
ls "$DEST"

# The WSL kernel decompresses XZ firmware only (FW_LOADER_COMPRESS_ZSTD is
# off) and Ubuntu's linux-firmware ships .zst, so the drivers would fail to
# load their firmware with -ENOENT. Keep a plain copy beside each blob.
echo ">> unpacking firmware"
cd /lib/firmware
for f in htc_9271.fw.zst ath9k_htc/*.fw.zst rt2870.bin.zst mediatek/mt7610u.bin.zst \
         mediatek/mt7662u*.bin.zst mediatek/WIFI_*MT7961*.bin.zst; do
    [ -e "$f" ] || continue
    [ -e "${f%.zst}" ] || zstd -q -d -k "$f"
    echo "   ${f%.zst}"
done
