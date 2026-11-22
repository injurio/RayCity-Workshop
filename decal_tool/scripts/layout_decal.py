"""Place a picture into RayCity's 512x512 car decal template (numpy only; run with Blender's Python: python -I).

python -I layout_decal.py <picture.png> <out_dir> <name> --layout sides|top|sides+top|wrap|raw
       [--scale 0.9] [--pos 0.5] [--mirror] [--recolor] [--colors "r,g,b;r,g,b;r,g,b"] [--bg keep|remove]

Template (verified by test renders, see README "How decals map onto a car"); rows from the top, front of the car = +u:
  rows   0..128  car RIGHT side, stored upside down (row 0 = sill, row 128 = roof line)
  rows 128..256  TOP (hood, roof, trunk lid); row 128 = right edge, row 256 = left edge
  rows 256..384  car LEFT side, upright (row 256 = roof line, row 384 = sill)
  rows 384..512  never shown (left transparent)
Writes <out_dir>/decal_<name>.png (512 RGBA), icon_<name>.png (64 RGBA), layout_<name>.png (template preview) and
colors_<name>.txt (the 3 colours when --recolor).
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pngio import read_png, write_png  # noqa: E402

S = 512
BANDS = {"right": (0, 128), "top": (128, 256), "left": (256, 384)}
MARGIN = 6  # px kept free at band edges (UV islands of some cars stop a little short of the band edge)


def resize(img, w, h):
    """Area-average down / nearest-bilinear-ish up resize of float RGBA (premultiplied for clean edges)."""
    img = img.astype(np.float32)
    a = img[..., 3:4] / 255.0
    pm = np.concatenate([img[..., :3] * a, img[..., 3:4]], 2)
    H, W = pm.shape[:2]
    ys = (np.arange(h + 1) * H / h)
    xs = (np.arange(w + 1) * W / w)
    # integral image for box filtering
    ii = np.zeros((H + 1, W + 1, 4), np.float64)
    ii[1:, 1:] = pm.cumsum(0).cumsum(1)

    def box(y0, y1, x0, x1):
        # bilinear sample of the integral image so fractional box edges work (up- and down-scaling)
        def at(y, x):
            y = np.clip(y, 0, H); x = np.clip(x, 0, W)
            yi = np.minimum(y.astype(int), H - 1); xi = np.minimum(x.astype(int), W - 1)
            fy = (y - yi)[..., None]; fx = (x - xi)[..., None]
            a00 = ii[yi, xi]; a01 = ii[yi, xi + 1]; a10 = ii[yi + 1, xi]; a11 = ii[yi + 1, xi + 1]
            return (a00 * (1 - fy) * (1 - fx) + a01 * (1 - fy) * fx + a10 * fy * (1 - fx) + a11 * fy * fx)
        return at(y1, x1) - at(y0, x1) - at(y1, x0) + at(y0, x0)

    Y0, X0 = np.meshgrid(ys[:-1], xs[:-1], indexing="ij")
    Y1, X1 = np.meshgrid(ys[1:], xs[1:], indexing="ij")
    area = ((Y1 - Y0) * (X1 - X0))[..., None]
    out = box(Y0, Y1, X0, X1) / area
    al = out[..., 3:4]
    rgb = np.where(al > 1e-3, out[..., :3] / np.maximum(al, 1e-3) * 255.0, 0)
    return np.clip(np.concatenate([rgb, al], 2), 0, 255).astype(np.uint8)


def remove_bg(img):
    """Make the picture's border colour transparent (for logos on a plain background)."""
    edge = np.concatenate([img[0], img[-1], img[:, 0], img[:, -1]]).astype(int)
    vals, counts = np.unique(edge[:, :3], axis=0, return_counts=True)
    bg = vals[counts.argmax()]
    d = np.abs(img[..., :3].astype(int) - bg).sum(2)
    out = img.copy()
    out[..., 3] = np.where(d < 40, 0, np.where(d < 80, (d - 40) * 255 // 40, img[..., 3])).astype(np.uint8)
    return out


def fit(pic, bw, bh, scale):
    """Resize pic to fit inside bw x bh (times scale), keeping its aspect."""
    h, w = pic.shape[:2]
    k = min(bw / w, bh / h) * scale
    return resize(pic, max(1, int(round(w * k))), max(1, int(round(h * k))))


def paste(canvas, pic, x, y):
    """Alpha-over paste, clipped to the canvas."""
    h, w = pic.shape[:2]
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(canvas.shape[1], x + w), min(canvas.shape[0], y + h)
    if x1 <= x0 or y1 <= y0:
        return
    src = pic[y0 - y:y1 - y, x0 - x:x1 - x].astype(np.float32)
    dst = canvas[y0:y1, x0:x1].astype(np.float32)
    a = src[..., 3:4] / 255
    rgb = src[..., :3] * a + dst[..., :3] * (1 - a)
    al = src[..., 3:4] + dst[..., 3:4] * (1 - a)
    canvas[y0:y1, x0:x1] = np.clip(np.concatenate([rgb, al], 2), 0, 255).astype(np.uint8)


def place_side(canvas, pic, band, scale, pos, rotate180):
    y0, y1 = BANDS[band]
    bh = (y1 - y0) - 2 * MARGIN
    p = fit(pic, S - 2 * MARGIN, bh, scale)
    if rotate180:
        p = p[::-1, ::-1]
    h, w = p.shape[:2]
    # pos: 0 = rear end, 1 = front end of the car (front = +u)
    cx = MARGIN + w / 2 + pos * (S - 2 * MARGIN - w)
    paste(canvas, p, int(round(cx - w / 2)), y0 + MARGIN + (bh - h) // 2)


def place_top(canvas, pic, scale, pos):
    """Picture seen from above with its top toward the car front: picture x -> rows 128..256, picture y -> u 512..0."""
    y0, y1 = BANDS["top"]
    p = np.transpose(pic, (1, 0, 2))[:, ::-1]  # top of picture -> +u (car front), picture left -> row 128 (checked by render)
    p = fit(p, S - 2 * MARGIN, (y1 - y0) - 2 * MARGIN, scale)
    h, w = p.shape[:2]
    cx = MARGIN + w / 2 + pos * (S - 2 * MARGIN - w)
    paste(canvas, p, int(round(cx - w / 2)), y0 + MARGIN + ((y1 - y0) - 2 * MARGIN - h) // 2)


def recolor(canvas, colors=None):
    """Turn the decal into the game's 3-colour form: each visible pixel -> one of 3 colours, stored as pure R, G or B
    (the shader paints R/G/B with the player's decal colours 1/2/3; black = transparent). Returns (canvas, colors)."""
    vis = canvas[..., 3] >= 128
    px = canvas[..., :3][vis].astype(np.float32)
    if colors is None:
        if len(px) == 0:
            raise SystemExit("picture has no visible pixels")
        # k-means, 3 clusters, started at dark / median / bright
        lum = px @ np.array([0.3, 0.59, 0.11], np.float32)
        order = np.argsort(lum)
        c = px[order[[len(px) // 10, len(px) // 2, len(px) * 9 // 10]]].copy()
        sub = px[:: max(1, len(px) // 60000)]
        for _ in range(25):
            lab = ((sub[:, None, :] - c[None]) ** 2).sum(2).argmin(1)
            for k in range(3):
                if (lab == k).any():
                    c[k] = sub[lab == k].mean(0)
        # most used colour first (= colour 1)
        lab = ((px[:, None, :] - c[None]) ** 2).sum(2).argmin(1)
        c = c[np.argsort(-np.bincount(lab, minlength=3))]
    else:
        c = np.array(colors, np.float32)
    lab = ((px[:, None, :] - c[None]) ** 2).sum(2).argmin(1)
    out = np.zeros_like(canvas)
    onehot = np.zeros((len(px), 3), np.uint8)
    onehot[np.arange(len(px)), lab] = 255
    out[..., :3][vis] = onehot
    out[..., 3][vis] = 255
    return out, [tuple(int(round(v)) for v in col) for col in c]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("picture"); ap.add_argument("out"); ap.add_argument("name")
    ap.add_argument("--layout", default="sides", choices=["sides", "top", "sides+top", "wrap", "raw"])
    ap.add_argument("--scale", type=float, default=0.9)
    ap.add_argument("--pos", type=float, default=0.5)
    ap.add_argument("--mirror", action="store_true", help="right side = mirror image of the left (faces the car front on both sides)")
    ap.add_argument("--recolor", action="store_true")
    ap.add_argument("--colors", default="")
    ap.add_argument("--bg", default="keep", choices=["keep", "remove"])
    a = ap.parse_args()

    pic = read_png(a.picture)
    if a.bg == "remove":
        pic = remove_bg(pic)
    canvas = np.zeros((S, S, 4), np.uint8)
    if a.layout == "raw":
        if pic.shape[:2] != (S, S):
            pic = resize(pic, S, S)
        canvas = pic.copy()
        canvas[384:] = 0
    elif a.layout == "wrap":
        # one picture unfolded over right side + top + left side (its top edge on the right sill)
        p = resize(pic, S, 384)
        canvas[:384] = p
    else:
        if a.layout in ("sides", "sides+top"):
            place_side(canvas, pic, "left", a.scale, a.pos, rotate180=False)
            if a.mirror:
                # mirror image: flip vertically only, so the picture's right edge still points to the car front
                y0, y1 = BANDS["left"]
                canvas[0:128] = canvas[y0:y1][::-1]
            else:
                place_side(canvas, pic, "right", a.scale, a.pos, rotate180=True)
        if a.layout in ("top", "sides+top"):
            place_top(canvas, pic, a.scale, a.pos)
    colors = None
    if a.recolor:
        user = [tuple(int(v) for v in c.split(",")) for c in a.colors.split(";")] if a.colors else None
        canvas, colors = recolor(canvas, user)
    os.makedirs(a.out, exist_ok=True)
    write_png(os.path.join(a.out, "decal_%s.png" % a.name), canvas)
    # icon: the picture itself (or the recoloured top/left band) on transparent 64x64
    src = pic if not a.recolor else canvas[256:384] if a.layout != "top" else canvas[128:256]
    if a.recolor:
        cols = np.array(colors, np.float32)
        rgb = (src[..., 0:1] / 255.0 * cols[0] + src[..., 1:2] / 255.0 * cols[1] + src[..., 2:3] / 255.0 * cols[2])
        src = np.concatenate([np.clip(rgb, 0, 255).astype(np.uint8), src[..., 3:4]], 2)
        ys, xs = np.nonzero(src[..., 3])
        if len(ys):
            src = src[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    icon = np.zeros((64, 64, 4), np.uint8)
    ic = fit(src, 60, 60, 1.0)
    paste(icon, ic, (64 - ic.shape[1]) // 2, (64 - ic.shape[0]) // 2)
    write_png(os.path.join(a.out, "icon_%s.png" % a.name), icon)
    # layout preview: template guide behind the decal
    guide = np.zeros((S, S, 4), np.uint8); guide[..., 3] = 255
    guide[0:128, :, :3] = (90, 60, 40); guide[128:256, :, :3] = (40, 60, 90); guide[256:384, :, :3] = (40, 90, 50)
    guide[384:, :, :3] = 30
    show = canvas.copy()
    if a.recolor:
        cols = np.array(colors, np.float32)
        rgb = canvas[..., 0:1] / 255.0 * cols[0] + canvas[..., 1:2] / 255.0 * cols[1] + canvas[..., 2:3] / 255.0 * cols[2]
        show[..., :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    paste(guide, show, 0, 0)
    write_png(os.path.join(a.out, "layout_%s.png" % a.name), guide)
    if colors:
        with open(os.path.join(a.out, "colors_%s.txt" % a.name), "w") as f:
            f.write("\n".join("%d %d %d" % c for c in colors) + "\n")
    print("layout ok", a.name, "colors" if colors else "", colors or "")


if __name__ == "__main__":
    main()
