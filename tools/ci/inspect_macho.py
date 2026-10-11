#!/usr/bin/env python3
"""Read arm64 Mach-O library identities, dependencies and client restrictions."""
from pathlib import Path
import struct
import sys


def inspect(path):
    data = Path(path).read_bytes()
    if data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Expected little-endian 64-bit Mach-O")
    count = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    result = []
    names = {0xC: "dependency", 0xD: "identity", 0x14: "allowed-client", 0x80000018: "weak-dependency", 0x8000001F: "reexport"}
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError("Malformed Mach-O command")
        if command in names:
            start = offset + struct.unpack_from("<I", data, offset + 8)[0]
            if start >= offset + size:
                raise ValueError("Malformed Mach-O string")
            value = data[start:offset + size].split(b"\0")[0].decode()
            result.append((names[command], value))
        offset += size
    return result


if __name__ == "__main__":
    for argument in sys.argv[1:]:
        print(argument)
        for kind, value in inspect(argument):
            print(f"  {kind}: {value}")
