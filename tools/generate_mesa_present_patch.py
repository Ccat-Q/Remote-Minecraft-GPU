#!/usr/bin/env python3
"""Generate the checked RemoteGPU present patch from pristine pinned winsys."""
import difflib
from pathlib import Path
import sys


def once(source, old, new):
    if source.count(old) != 1:
        raise ValueError("Pinned Mesa context changed: " + old[:80])
    return source.replace(old, new, 1)


PRESENT_HELPER = r'''
/* Explicit little-endian wire layout, without native struct padding. */
static void rgpu_store_le(uint8_t *dst, uint64_t value, unsigned bytes)
{
   for (unsigned i = 0; i < bytes; i++)
      dst[i] = value >> (8 * i);
}

int virgl_vtest_send_present(struct virgl_vtest_winsys *vws,
                            struct virgl_hw_res *res,
                            unsigned level, unsigned layer,
                            const struct pipe_box *box)
{
   const char *path = os_get_option("REMOTEGPU_PRESENT_SOCKET");
   struct sockaddr_un addr = { .sun_family = AF_UNIX };
   uint8_t signal[52] = { 'R', 'G', 'P', 'F' };
   if (!path || !os_get_option("REMOTEGPU_VTEST_LEGACY") || vws->protocol_version != 0)
      return -EINVAL;
   if (strlen(path) >= sizeof(addr.sun_path))
      return -ENAMETOOLONG;
   memcpy(addr.sun_path, path, strlen(path) + 1);
   rgpu_store_le(signal + 4, vws->raw_stream_bytes, 8);
   rgpu_store_le(signal + 12, vws->present_frame_id + 1, 8);
   rgpu_store_le(signal + 20, res->res_handle, 8);
   rgpu_store_le(signal + 28, level, 4);
   rgpu_store_le(signal + 32, layer, 4);
   rgpu_store_le(signal + 36, box->x, 4);
   rgpu_store_le(signal + 40, box->y, 4);
   rgpu_store_le(signal + 44, box->width, 4);
   rgpu_store_le(signal + 48, box->height, 4);
   int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
   if (fd < 0)
      return -errno;
   /* Linux autobind gives the proxy a unique local return address. */
   struct sockaddr_un local = { .sun_family = AF_UNIX };
   struct timeval timeout = { .tv_sec = 5 };
   if (bind(fd, (struct sockaddr *)&local, sizeof(local.sun_family)) < 0 ||
       setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
      int err = -errno;
      close(fd);
      return err;
   }
   ssize_t written;
   do {
      written = sendto(fd, signal, sizeof(signal), 0,
                       (struct sockaddr *)&addr, sizeof(addr));
   } while (written < 0 && errno == EINTR);
   int result = written < 0 ? -errno : (written == sizeof(signal) ? 0 : -EIO);
   if (!result) {
      /* ACK means the proxy queued this marker, not GPU completion. Without
       * this local barrier, RESOURCE_UNREF could overtake the datagram. */
      uint8_t ack[13], expected[12] = { 'R', 'G', 'P', 'A' };
      rgpu_store_le(expected + 4, vws->present_frame_id + 1, 8);
      ssize_t received;
      do {
         received = recv(fd, ack, sizeof(ack), 0);
      } while (received < 0 && errno == EINTR);
      if (received < 0)
         result = -errno;
      else if (received != sizeof(expected) || memcmp(ack, expected, sizeof(expected)))
         result = -EPROTO;
   }
   close(fd);
   if (!result)
      vws->present_frame_id++;
   return result;
}

'''


def transform(name, source):
    if name == "virgl_vtest_winsys.h":
        source = once(source, "   int sock_fd;\n", "   int sock_fd;\n   uint64_t raw_stream_bytes;\n   uint64_t present_frame_id;\n")
        source = once(source, "int virgl_vtest_connect(struct virgl_vtest_winsys *vws);", """int virgl_vtest_send_present(struct virgl_vtest_winsys *vws,
                            struct virgl_hw_res *res,
                            unsigned level, unsigned layer,
                            const struct pipe_box *box);
int virgl_vtest_connect(struct virgl_vtest_winsys *vws);""")
    elif name == "virgl_vtest_socket.c":
        source = once(source, "#include <sys/socket.h>", "#include <sys/socket.h>\n#include <sys/time.h>")
        source = once(source, "static int virgl_block_write(int fd, void *buf, int size)",
                      "static int virgl_block_write(struct virgl_vtest_winsys *vws, void *buf, int size)")
        source = once(source, "   left = size;\n   do {\n      ret = write(fd, ptr, left);",
                      "   left = size;\n   if (!size)\n      return 0;\n   do {\n      ret = write(fd, ptr, left);")
        source = once(source, """      ret = write(fd, ptr, left);
      if (ret < 0)
         return -errno;
      assert(ret <= left);
      left -= ret;""", """      ret = write(vws->sock_fd, ptr, left);
      if (ret < 0 && errno == EINTR)
         continue;
      if (ret <= 0)
         return ret < 0 ? -errno : -EIO;
      assert(ret <= left);
      vws->raw_stream_bytes += ret;
      left -= ret;""")
        calls = "virgl_block_write(vws->sock_fd,"
        if source.count(calls) != 25:
            raise ValueError("Pinned Mesa write call count changed")
        source = source.replace(calls, "virgl_block_write(vws,")
        source = once(source, "static int virgl_block_read(int fd, void *buf, int size)",
                      PRESENT_HELPER + "static int virgl_block_read(int fd, void *buf, int size)")
    elif name == "virgl_vtest_winsys.c":
        source = once(source, '#include "util/os_time.h"', '#include "util/os_time.h"\n#include "util/u_process.h"')
        source = once(source, """   virgl_vtest_transfer_get_internal(vws, res, &box, res->stride, 0, offset,
                                     level, true);""", """   if (os_get_option("REMOTEGPU_PRESENT_SOCKET")) {
      /* The caller already flushed rendering commands before frontbuffer
       * presentation. Order the marker behind the exact vtest byte offset.
       * Failure must never silently restore the CPU presentation path. */
      int err = virgl_vtest_send_present(vtws, res, level, layer, &box);
      if (err) {
         fprintf(stderr, "RemoteGPU: present notification failed (%d)\\n", err);
         abort();
      }
      return;
   }

   virgl_vtest_transfer_get_internal(vws, res, &box, res->stride, 0, offset,
                                     level, true);""")
    else:
        raise ValueError(name)
    return source


def main():
    root = Path(sys.argv[1])
    for name in ("virgl_vtest_winsys.h", "virgl_vtest_socket.c", "virgl_vtest_winsys.c"):
        original = (root / name).read_text()
        updated = transform(name, original)
        target = "src/gallium/winsys/virgl/vtest/" + name
        print("diff --git a/" + target + " b/" + target)
        sys.stdout.writelines(difflib.unified_diff(original.splitlines(True), updated.splitlines(True),
                                               fromfile="a/" + target, tofile="b/" + target))


if __name__ == "__main__":
    main()
