#!/usr/bin/env python3
"""Replay the macOS reference-capture measurements using only the standard library.

Reads every PNG listed in evidence.json byte-for-byte, checks its SHA-256, size,
dimensions, PNG header and ancillary chunks, decodes the stored samples with no
colour management (raw 8-bit values exactly as written in the file), and recomputes
every recorded sample rectangle. Any difference is a failure. There is no colour
tolerance.

    python3 investigation/visual-baseline/rendered-macos/replay.py
    python3 investigation/visual-baseline/rendered-macos/replay.py --record

--record rewrites only the file facts and "measured" blocks from the committed bytes;
the rectangles and colours to count are hand-chosen and never changed by the script.
"""

import hashlib
import json
import struct
import sys
import zlib
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVIDENCE = HERE / "evidence.json"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def read_chunks(data):
    if data[:8] != PNG_SIGNATURE:
        raise ValueError("not a PNG")
    pos, chunks = 8, []
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        kind = data[pos + 4 : pos + 8].decode("latin-1")
        chunks.append((kind, data[pos + 8 : pos + 8 + length]))
        pos += 12 + length
    return chunks


def decode(data):
    chunks = read_chunks(data)
    width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", chunks[0][1])
    if depth != 8 or colour not in (2, 6) or interlace != 0:
        raise ValueError(f"unsupported PNG layout depth={depth} colour={colour}")
    channels = 4 if colour == 6 else 3
    raw = zlib.decompress(b"".join(body for kind, body in chunks if kind == "IDAT"))
    stride = width * channels
    rows, prev, pos = [], bytearray(stride), 0
    for _ in range(height):
        kind = raw[pos]
        cur = bytearray(raw[pos + 1 : pos + 1 + stride])
        pos += 1 + stride
        if kind == 1:
            for i in range(channels, stride):
                cur[i] = (cur[i] + cur[i - channels]) & 0xFF
        elif kind == 2:
            for i in range(stride):
                cur[i] = (cur[i] + prev[i]) & 0xFF
        elif kind == 3:
            for i in range(stride):
                left = cur[i - channels] if i >= channels else 0
                cur[i] = (cur[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif kind == 4:
            for i in range(stride):
                a = cur[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                cur[i] = (cur[i] + pred) & 0xFF
        elif kind != 0:
            raise ValueError(f"bad filter {kind}")
        rows.append(bytes(cur))
        prev = cur
    return width, height, depth, colour, channels, rows, chunks


def chunk_facts(chunks):
    facts = {"order": [kind for kind, _ in chunks if kind != "IDAT"]}
    for kind, body in chunks:
        if kind == "sRGB":
            facts["sRGBRenderingIntent"] = body[0]
        elif kind == "iCCP":
            facts["iCCPProfileName"] = body.split(b"\0", 1)[0].decode("latin-1")
        elif kind == "pHYs":
            facts["pHYs"] = list(struct.unpack(">IIB", body))
        elif kind == "gAMA":
            facts["gAMA"] = struct.unpack(">I", body)[0]
    facts["hasICCP"] = "iCCP" in facts["order"]
    facts["IDATCount"] = sum(1 for kind, _ in chunks if kind == "IDAT")
    return facts


def measure(rows, channels, rect, count_rgb):
    x, y, w, h = rect
    pixels = []
    for row in rows[y : y + h]:
        for i in range(x, x + w):
            px = tuple(row[i * channels : i * channels + channels])
            pixels.append(px if channels == 4 else px + (255,))
    hist = Counter(pixels)
    ranked = sorted(hist.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
    result = {
        "pixels": len(pixels),
        "distinctRGBA": len(hist),
        "top5RGBACount": [list(colour) + [n] for colour, n in ranked],
        "maxChannelSpread": max(max(p[:3]) - min(p[:3]) for p in pixels),
    }
    if count_rgb:
        result["exactOpaqueRGBCounts"] = [
            list(rgb) + [sum(n for c, n in hist.items() if list(c) == list(rgb) + [255])]
            for rgb in count_rgb
        ]
    return result


def main():
    record = "--record" in sys.argv[1:]
    evidence = json.loads(EVIDENCE.read_text(encoding="utf-8"))
    failures, samples = [], 0
    for capture in evidence["captures"]:
        data = (HERE / capture["file"]).read_bytes()
        width, height, depth, colour, channels, rows, chunks = decode(data)
        facts = {
            "sha256": hashlib.sha256(data).hexdigest(),
            "bytes": len(data),
            "width": width,
            "height": height,
            "bitDepth": depth,
            "pngColourType": colour,
            "chunks": chunk_facts(chunks),
        }
        for key, value in facts.items():
            if record:
                capture[key] = value
            elif capture.get(key) != value:
                failures.append(f"{capture['file']}: {key} expected {capture.get(key)!r} got {value!r}")
        for sample in capture.get("samples", []):
            x, y, w, h = sample["rect"]
            if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > width or y + h > height:
                failures.append(f"{capture['file']}:{sample['id']}: rect outside image")
                continue
            got = measure(rows, channels, sample["rect"], sample.get("countRGB", []))
            samples += 1
            if record:
                sample["measured"] = got
            elif sample.get("measured") != got:
                failures.append(
                    f"{capture['file']}:{sample['id']}: expected {sample.get('measured')} got {got}"
                )
    if record:
        EVIDENCE.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        print(f"recorded {len(evidence['captures'])} captures, {samples} samples")
        return 0
    for failure in failures:
        print("FAIL", failure)
    verdict = "all match" if not failures else f"{len(failures)} mismatches"
    print(f"{len(evidence['captures'])} captures, {samples} samples: {verdict}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
