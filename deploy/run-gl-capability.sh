#!/usr/bin/env sh
set -eu

bundle_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mesa_lib=$(find "$bundle_root/mesa" -type d -name dri -print -quit)
if [ -z "$mesa_lib" ]; then
  echo "RemoteGPU Mesa DRI drivers are missing from this artifact" >&2
  exit 1
fi
mesa_lib=${mesa_lib%/dri}
export LD_LIBRARY_PATH="$mesa_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBGL_DRIVERS_PATH="$mesa_lib/dri"

exec "$bundle_root/bin/gl-capability" "$@"
