#!/usr/bin/env bash
# AIRDROP_URL_HOOK: open an AirDropped link in the Windows default browser.
#
# OpenDrop only passes http(s) links, but the URL comes from an unauthenticated
# peer and this hook can be run on its own, so check again - and refuse
# anything with whitespace or quotes, which the Windows command line built by
# WSL interop would otherwise have to survive.
url="${1:-}"
case "$url" in
    http://*|https://*) ;;
    *) exit 1 ;;
esac
[[ "$url" =~ [[:space:]\"\'\`] ]] && exit 1
exec /mnt/c/Windows/System32/rundll32.exe url.dll,FileProtocolHandler "$url"
