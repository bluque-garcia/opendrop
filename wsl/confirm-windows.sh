#!/usr/bin/env bash
# AIRDROP_CONFIRM hook: ask on the Windows desktop before accepting a transfer.
#
#   confirm-windows.sh SENDER DETAIL     exit 0 = accept, anything else = decline
#
# Both arguments come from an unauthenticated peer, so they reach PowerShell
# only as environment variables (WSLENV) and are never spliced into the
# command text. No answer within AIRDROP_CONFIRM_TIMEOUT seconds is a no: the
# phone gives up on its own after about a minute, and an unanswered question
# is not consent.
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
[ -x "$PS" ] || exit 1

export AD_SENDER="${1:-unknown sender}" AD_DETAIL="${2:-}"
export AD_TIMEOUT="${AIRDROP_CONFIRM_TIMEOUT:-30}"
export WSLENV="${WSLENV:+$WSLENV:}AD_SENDER:AD_DETAIL:AD_TIMEOUT"

# 4 = Yes/No, 32 = question icon, 4096 = system modal (stays on top).
# Popup returns 6 for Yes, 7 for No, -1 on timeout.
answer="$("$PS" -NoProfile -NonInteractive -Command '
    $text = "$env:AD_SENDER quiere enviarte por AirDrop:`n`n$env:AD_DETAIL`n`n¿Aceptar?"
    (New-Object -ComObject WScript.Shell).Popup($text, [int]$env:AD_TIMEOUT, "AirDrop", 4 + 32 + 4096)
' 2>/dev/null | tr -d '\r')"
[ "$answer" = 6 ]
