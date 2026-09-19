"""Wire format shared by phones, the hub, subscribers and the simulator.

Binary frame message: [uint32 big-endian header length][UTF-8 JSON header][JPEG bytes]
"""
from __future__ import annotations

import json
import struct
import time


def now_ms() -> float:
    return time.time() * 1000


def pack(header: dict, payload: bytes) -> bytes:
    h = json.dumps(header, separators=(",", ":")).encode()
    return struct.pack(">I", len(h)) + h + payload


def unpack(buf: bytes) -> tuple[dict, bytes]:
    if len(buf) < 4:
        raise ValueError("truncated frame prefix")
    (n,) = struct.unpack_from(">I", buf, 0)
    if n > 65536 or n > len(buf) - 4:
        raise ValueError("invalid frame header length")
    header = json.loads(buf[4 : 4 + n])
    if not isinstance(header, dict):
        raise ValueError("frame header must be an object")
    return header, buf[4 + n :]
