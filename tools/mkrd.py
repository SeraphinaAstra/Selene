#!/usr/bin/env python3
# tools/mkrd.py — Selene ramdisk packer
# Usage: python3 tools/mkrd.py <input_dir> <output_file>
# Produces a flat binary ramdisk image for linking into selene.elf

import os
import sys
import struct

MAGIC = b'SLNE'
ALIGN = 8

def align_up(n, a):
    return (n + a - 1) & ~(a - 1)

def pack(input_dir, output_file):
    files = []

    for root, dirs, filenames in os.walk(input_dir):
        dirs.sort()
        for name in sorted(filenames):
            full = os.path.join(root, name)
            # Store path relative to input_dir's parent so it's like "nyx/shell.lua"
            rel = os.path.relpath(full, os.path.dirname(input_dir))
            with open(full, 'rb') as f:
                data = f.read()
            files.append((rel.replace(os.sep, '/'), data))
            print(f"  packing: {rel} ({len(data)} bytes)")

    with open(output_file, 'wb') as out:
        # Header
        out.write(MAGIC)
        out.write(struct.pack('<I', len(files)))

        for path, data in files:
            path_bytes = path.encode('utf-8')
            out.write(struct.pack('<I', len(path_bytes)))
            out.write(struct.pack('<I', len(data)))
            out.write(path_bytes)
            out.write(data)

            # Pad to 8-byte alignment
            total = len(path_bytes) + len(data)
            pad = align_up(total, ALIGN) - total
            out.write(b'\x00' * pad)

    print(f"  wrote {output_file} ({os.path.getsize(output_file)} bytes, {len(files)} files)")

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input_dir> <output_file>")
        sys.exit(1)
    pack(sys.argv[1], sys.argv[2])