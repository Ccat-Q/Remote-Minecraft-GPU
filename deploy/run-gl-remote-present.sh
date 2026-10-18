#!/usr/bin/env sh
# Diagnostic only. Start your separate test proxy first; no production changes.
set -eu
: "${RGPU_MESA_ROOT:?Set to the mesa directory from the explicitly verified Linux bundle}"
: "${VTEST_SOCKET_NAME:?Set to the test proxy Unix socket}"
: "${REMOTEGPU_PRESENT_SOCKET:?Set to the same test proxy PRESENT socket}"
tool_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dri_path=$(find "$RGPU_MESA_ROOT" -type d -name dri -print -quit)
test -n "$dri_path" || { echo 'Mesa DRI directory missing' >&2; exit 1; }
mesa_lib=${dri_path%/dri}
# Do NOT put virpipe in Xvfb's environment: only the GL application is remote.
exec xvfb-run --auto-servernum env GALLIUM_DRIVER=virpipe REMOTEGPU_VTEST_LEGACY=1 \
    VTEST_SOCKET_NAME="$VTEST_SOCKET_NAME" REMOTEGPU_PRESENT_SOCKET="$REMOTEGPU_PRESENT_SOCKET" \
    LIBGL_DRIVERS_PATH="$dri_path" LD_LIBRARY_PATH="$mesa_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$tool_root/bin/gl-remote-present" "$@"
