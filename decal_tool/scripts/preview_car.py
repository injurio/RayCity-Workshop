"""Render a game car with a decal on it (preview only; reads the OBJ export made by research/extract_car.ps1).

blender -b --factory-startup -P scripts/preview_car.py -- <car extract dir> <decal.png> <out prefix> [rgba|3color] [1to1|squash] ["r,g,b;r,g,b;r,g,b" decal colours] [views]

Composite texture (512x512, v from the top) as the game builds it (fx.jmd cartexture.fx):
  rows 0..383 (v < 0.75): body = mask channels x paint colours x mask alpha, then the decal blended on top
  part textures (bumpers, lights ...) in their slot rectangles (tuktuk_car/scripts/carcompose.py SLOT_RECTS)
'1to1' samples mask and decal at the same v as the composite (only their top 384 rows show); 'squash' fits the whole
512-row image into v 0..0.75. 1to1 is what the game's own masks and decals are drawn for (see README).
"""
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from pngio import read_png, write_png  # noqa: E402

argv = sys.argv[sys.argv.index("--") + 1:]
src, decal_path, out = (os.path.abspath(x) for x in argv[:3])
mode = argv[3] if len(argv) > 3 else "rgba"
mapping = argv[4] if len(argv) > 4 else "1to1"
colors_arg = argv[5] if len(argv) > 5 and argv[5] not in ("", "-") else ""
views_arg = argv[6].split(",") if len(argv) > 6 and argv[6] else None
car = os.path.basename(os.path.normpath(src))

SLOT_RECTS = [
    (0, 0, 1, 0.75), (0.75, 0.75, 1, 0.875), (0, 0.25, 0.125, 0.375),
    (0, 0.75, 0.25, 1), (0, 0.625, 0.125, 0.75), (0, 0, 0.125, 0.125),
    (0, 0.5, 0.125, 0.625), (0, 0.375, 0.125, 0.5), (0, 0.125, 0.0625, 0.1875),
    (0.0625, 0.125, 0.125, 0.1875), (0.5, 0.75, 0.75, 0.875), (0.5, 0.875, 0.75, 1),
    (0.25, 0.75, 0.5, 1), (0.75, 0.875, 1, 1), (0, 0.1875, 0.125, 0.25),
]
PART_TYPES = ["frontbumper", "rearbumper", "mainspoiler", "lamp", "skirt", "roof", "headlight", "grill",
              "rearlight", "hood", "dooropen"]
PAINTS = np.array([(205, 210, 215), (40, 46, 58), (150, 155, 160)], np.float32)  # player colours 1/2/3 (preview)
DECAL3 = np.array([[float(x) for x in c.split(",")] for c in colors_arg.split(";")] if colors_arg else
                  [(255, 200, 0), (220, 30, 30), (20, 20, 20)], np.float32)  # decal colours 1/2/3
S = 512


def sample_rows(img, rows_v):
    """img rows for composite v values (1to1: same v, squash: v/0.75)."""
    h = img.shape[0]
    vv = rows_v if mapping == "1to1" else rows_v / 0.75
    return np.clip((vv * h).astype(int), 0, h - 1)


def resize_w(img, w):
    cols = np.clip(((np.arange(w) + 0.5) / w * img.shape[1]).astype(int), 0, img.shape[1] - 1)
    return img[:, cols]


v = (np.arange(S) + 0.5) / S
body_rows = v < 0.75
comp = np.zeros((S, S, 3), np.float32) + 90
mask = resize_w(read_png(os.path.join(src, car + "_base.png")), S).astype(np.float32) / 255
m = mask[sample_rows(mask, v[body_rows])]
seam = m[..., 3]
comp[body_rows] = (m[..., 0:1] * PAINTS[0] + m[..., 1:2] * PAINTS[1] + m[..., 2:3] * PAINTS[2]) * seam[..., None]
d = resize_w(read_png(decal_path), S).astype(np.float32) / 255
d = d[sample_rows(d, v[body_rows])]
if mode == "3color":
    rgb = (d[..., 0:1] * DECAL3[0] + d[..., 1:2] * DECAL3[1] + d[..., 2:3] * DECAL3[2]) * seam[..., None]
    a = np.clip(d[..., 0] + d[..., 1] + d[..., 2], 0, 1)
else:
    rgb = d[..., :3] * 255 * seam[..., None]
    a = d[..., 3]
comp[body_rows] += (rgb - comp[body_rows]) * a[..., None]
for folder in PART_TYPES:
    p = os.path.join(src, folder, "%s_%s.png" % (car, folder))
    if not os.path.exists(p):
        continue
    l, t, r, b = SLOT_RECTS[PART_TYPES.index(folder) + 4]
    x0, y0, x1, y1 = int(l * S), int(t * S), int(r * S), int(b * S)
    img = read_png(p).astype(np.float32)
    ys = np.clip(((np.arange(y1 - y0) + 0.5) / (y1 - y0) * img.shape[0]).astype(int), 0, img.shape[0] - 1)
    xs = np.clip(((np.arange(x1 - x0) + 0.5) / (x1 - x0) * img.shape[1]).astype(int), 0, img.shape[1] - 1)
    tx = img[ys][:, xs]
    al = tx[..., 3:4] / 255
    comp[y0:y1, x0:x1] += (tx[..., :3] - comp[y0:y1, x0:x1]) * al
tex_path = out + "_texture.png"
rgba = np.concatenate([np.clip(comp, 0, 255).astype(np.uint8), np.full((S, S, 1), 255, np.uint8)], 2)
write_png(tex_path, rgba)

# ---------------------------------------------------------------- scene
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.engine = "BLENDER_EEVEE"
sc.render.resolution_x, sc.render.resolution_y = 960, 600
sc.view_settings.view_transform = "Standard"
world = bpy.data.worlds.new("w")
sc.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.78, 0.84, 0.92, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 1.0
sun = bpy.data.lights.new("sun", "SUN")
sun.energy = 2.5
so = bpy.data.objects.new("sun", sun)
so.rotation_euler = (math.radians(40), 0, math.radians(30))
sc.collection.objects.link(so)

mat = bpy.data.materials.new("car")
mat.use_nodes = True
nt = mat.node_tree
tn = nt.nodes.new("ShaderNodeTexImage")
tn.image = bpy.data.images.load(tex_path)
tn.interpolation = "Closest"
bsdf = nt.nodes["Principled BSDF"]
nt.links.new(tn.outputs[0], bsdf.inputs["Base Color"])
bsdf.inputs["Roughness"].default_value = 0.5

files = ["body_2.obj"] + ["%s/default_2.obj" % f for f in ("frontbumper", "grill", "headlight", "hood", "rearbumper",
                                                          "rearlight", "roof", "skirt")]
for rel in files:
    p = os.path.join(src, rel)
    if not os.path.exists(p):
        continue
    before = set(bpy.data.objects)
    bpy.ops.wm.obj_import(filepath=p, forward_axis="Y", up_axis="Z")
    for o in set(bpy.data.objects) - before:
        uv = o.data.uv_layers.active
        if uv:
            for dd in uv.data:
                dd.uv = (dd.uv[0], 1 - dd.uv[1])  # OBJ keeps DirectX v (top-down)
        o.data.materials.clear()
        o.data.materials.append(mat)

cd = bpy.data.cameras.new("cam")
cd.lens = 50
cam = bpy.data.objects.new("cam", cd)
sc.collection.objects.link(cam)
sc.camera = cam
# azimuth 0 = in front of the car (front is -Y), 90 = the car's right side (+X)
VIEWS = {"left": (270, 3, 7.0), "right": (90, 3, 7.0), "top": (0, 89, 7.5), "front34": (35, 20, 6.5),
         "rear34": (215, 22, 6.5)}
target = Vector((0, 0, 0.7))
for name, (az, el, dist) in VIEWS.items():
    if views_arg and name not in views_arg:
        continue
    a, e = math.radians(az), math.radians(el)
    cam.location = target + dist * Vector((math.sin(a) * math.cos(e), -math.cos(a) * math.cos(e), math.sin(e)))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    sc.render.filepath = "%s_%s.png" % (out, name)
    bpy.ops.render.render(write_still=True)
print("rendered", out)
