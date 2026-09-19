#!/usr/bin/env python3
"""Generate the legacy-vtest edit against a checked-out Mesa tree.

This is a diagnostic aid for the pinned revision. It deliberately uses bytes,
not a fuzzy text substitution, so a changed upstream source produces a clear
failure rather than an accidentally misplaced transport boundary.
"""

from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_bytes()
needle = b"   vws->sock_fd = sock;\n   virgl_vtest_send_init(vws);\n"
addition = b"""   vws->sock_fd = sock;
   virgl_vtest_send_init(vws);

   /* RemoteGPU serializes this protocol over QUIC. Protocol >= 2 uses
    * mmap-able resources and Unix FD passing, neither of which crosses a
    * network connection. Keep the established protocol-0 inline path. */
   if (os_get_option(\"REMOTEGPU_VTEST_LEGACY\")) {
      vws->protocol_version = 0;
      return 0;
   }
"""

if source.count(needle) != 1:
    raise SystemExit("expected exactly one virgl_vtest_connect insertion point")
path.write_bytes(source.replace(needle, addition))
