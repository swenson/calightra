#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# Pad the compiled Calightra MCU ROM binary to 64 KB (65536 bytes) and append
# the 48-byte SHA-384 digest of bytes [0..65488] at offset [65488..65536],
# matching `caliptra_mcu_builder::append_rom_digest`.

import hashlib
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <rom.bin> [rom_size_bytes]", file=sys.stderr)
        return 1

    path = sys.argv[1]
    rom_size = int(sys.argv[2], 0) if len(sys.argv) >= 3 else 65536
    digest_size = 48
    digest_offset = rom_size - digest_size

    with open(path, "rb") as f:
        data = bytearray(f.read())

    orig_len = len(data)
    if orig_len > digest_offset:
        print(
            f"ERROR: ROM binary {path} is {orig_len} bytes, exceeding max code size {digest_offset} bytes",
            file=sys.stderr,
        )
        return 1

    data.extend(b"\x00" * (rom_size - orig_len))
    digest = hashlib.sha384(data[:digest_offset]).digest()
    data[digest_offset:rom_size] = digest

    with open(path, "wb") as f:
        f.write(data)

    print(
        f"[MCU-ROM] {path}: code={orig_len}B, padded={rom_size}B, sha384={digest.hex()[:32]}..."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
