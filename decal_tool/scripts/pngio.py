"""Minimal PNG read/write (RGBA8, numpy) for Blender's bundled Python (no PIL)."""
import struct
import zlib

import numpy as np


def read_png(path):
    """Returns an (h, w, 4) uint8 array. Supports 8-bit grey/RGB/RGBA/palette, non-interlaced."""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, idat, plte, trns = 8, [], None, None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"PLTE":
            plte = np.frombuffer(chunk, np.uint8).reshape(-1, 3)
        elif kind == b"tRNS":
            trns = np.frombuffer(chunk, np.uint8)
        elif kind == b"IDAT":
            idat.append(chunk)
        elif kind == b"IEND":
            break
    assert depth == 8 and interlace == 0, (path, depth, interlace)
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(b"".join(idat))
    stride = w * ch
    out = np.zeros((h, stride), np.uint8)
    prev = np.zeros(stride, np.int32)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = np.frombuffer(raw, np.uint8, stride, y * (stride + 1) + 1).astype(np.int32)
        if f == 0:
            cur = line
        elif f == 2:
            cur = (line + prev) & 255
        else:
            cur = np.zeros(stride, np.int32)
            for x in range(stride):
                a = cur[x - ch] if x >= ch else 0
                b = prev[x]
                c = prev[x - ch] if x >= ch else 0
                if f == 1:
                    p = a
                elif f == 3:
                    p = (a + b) >> 1
                else:
                    pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                    p = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                cur[x] = (line[x] + p) & 255
        out[y] = cur
        prev = cur
    img = out.reshape(h, w, ch)
    if ctype == 3:
        rgb = plte[img[..., 0]]
        a = np.full((h, w, 1), 255, np.uint8)
        if trns is not None:
            t = np.full(256, 255, np.uint8)
            t[:len(trns)] = trns
            a = t[img[..., 0]][..., None]
        return np.concatenate([rgb, a], 2)
    if ch == 1:
        img = np.repeat(img, 3, 2)
    elif ch == 2:
        img = np.concatenate([np.repeat(img[..., :1], 3, 2), img[..., 1:]], 2)
    if img.shape[2] == 3:
        img = np.concatenate([img, np.full((h, w, 1), 255, np.uint8)], 2)
    return img


def write_png(path, img):
    img = np.ascontiguousarray(img.astype(np.uint8))
    if img.ndim == 2:
        img = np.repeat(img[..., None], 3, 2)
    if img.shape[2] == 3:
        img = np.concatenate([img, np.full(img.shape[:2] + (1,), 255, np.uint8)], 2)
    h, w = img.shape[:2]
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(h))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))
