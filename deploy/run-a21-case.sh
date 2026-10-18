#!/usr/bin/env bash
# Independent foreground diagnostic only. Never starts/stops system services.
set -euo pipefail
case_frames=${1:?Usage: run-a21-case.sh 1\|7\|12 NEW_EVIDENCE_DIRECTORY [HOLD_SECONDS]}
case_root=${2:?Provide a new evidence directory; existing records are never overwritten}
case_hold=${3:-120}
case "$case_frames" in
    1|7) case_fps=1 ;;
    12) case_fps=2 ;;
    *) echo 'Only 1, 7 and 12-frame diagnostics are supported' >&2; exit 2 ;;
esac
if ! [[ "$case_hold" =~ ^[0-9]+$ ]] || ((case_hold < 120 || case_hold > 3600)); then
    echo 'HOLD_SECONDS must be 120..3600; never shorten the 120-second observation' >&2
    exit 2
fi
tool_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -- "$case_root"
cp "$tool_root/SOURCE.txt" "$case_root/SOURCE.txt"
{
    printf 'A21_CASE frames=%s fps=%s hold_s=%s; UTC=' "$case_frames" "$case_fps" "$case_hold"
    date -u +%FT%TZ
    cat "$tool_root/SOURCE.txt"
    printf 'USER REQUIRED: screen record every triangle; wait quiet_s >= 120 while connected; share report before AND after Disconnect.\n'
    bash "$tool_root/run-gl-remote-present.sh" --frames "$case_frames" --fps "$case_fps" --hold-seconds "$case_hold"
} 2>&1 | tee "$case_root/ubuntu.log"
