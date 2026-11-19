#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
temp=$(mktemp -d /tmp/screenveil-icon.XXXXXXXX)
trap 'rm -rf "$temp"' EXIT
mkdir -p Resources
/usr/bin/xcrun swiftc -module-cache-path "$temp/cache" Branding/RenderIcon.swift -o "$temp/render"
"$temp/render" Branding/ScreenVeil-Artwork.png "$temp"
/usr/bin/python3 - "$temp" <<'PY'
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])
slots = dict(icp4=16, ic11=32, icp5=32, ic12=64, ic07=128, ic13=256,
             ic08=256, ic14=512, ic09=512, ic10=1024)
chunks = []
for tag, size in slots.items():
    png = (root / f"{size}.png").read_bytes()
    if not png.startswith(b"\x89PNG\r\n\x1a\n") or struct.unpack_from(">II", png, 16) != (size, size):
        raise ValueError(f"Incorrect dimensions for {tag}")
    chunks.append(struct.pack(">4sI", tag.encode("ascii"), len(png) + 8) + png)
body = b"".join(chunks)
Path("Resources/ScreenVeil.icns").write_bytes(struct.pack(">4sI", b"icns", len(body) + 8) + body)
PY
cp "$temp/1024.png" Branding/ScreenVeil.png
