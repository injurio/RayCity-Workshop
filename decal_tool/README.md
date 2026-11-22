# RayCity decal tool: picture → car pattern

Turns any picture (PNG, JPG, BMP or GIF) into a RayCity **decal**, the game's car pattern item, and shows it on real
game cars in 3D. A second script adds finished decals to copies of the game's decal archives for the developer.
Game files are only read, never changed.

**Status (2026-11-20)**
- Works end to end on the test pictures in `samples/`.
- Checked by renders on two game cars (Clio and cx7).
- **Not tested in game.** The new decal ids still need the server side (see [For the developer](#for-the-developer)).

## Quick start

```powershell
cd decal_tool    # in the Workshop folder (or Ray\decal_tool on the dev PC)
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File make_decal.ps1 -Image C:\path\my_logo.png -Name samui_logo -RemoveBg
```

The result is in `out\samui_logo\`. Look at `preview\clio_left.png` and the other renders. Change the options and run it
again until it looks right. Then build the package:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File make_package.ps1 -Names samui_logo
```

Several decals at once: `-Names samui_logo,samui_wave`.

## Options (`make_decal.ps1`)

| Option | What it does |
|---|---|
| `-Image` | The picture: PNG, JPG, BMP or GIF |
| `-Name` | Decal name: lowercase letters, digits and `_` (2–40 characters). Becomes the game names `<name>.xml` and `decal_<name>` |
| `-Layout sides` (default) | The picture on **both sides** of the car, readable on both |
| `-Layout top` | On the hood or roof, readable with the car's front at the top |
| `-Layout sides+top` | Both of the above |
| `-Layout wrap` | One picture stretched over right side, top and left side, like a full wrap |
| `-Layout raw` | Your picture **is** the finished 512×512 template (see [template_guide.png](template_guide.png)) |
| `-Scale 0.9` | Size inside its area, from 0 to 1 (1 = as large as fits) |
| `-Pos 0.5` | Position along the car: 0 = rear end, 1 = front end |
| `-Mirror` | Right side = mirror image of the left, so the picture faces the car's front on both sides (flames, arrows, animals). Without it, text reads correctly on both sides |
| `-RemoveBg` | Makes the picture's border colour transparent (a logo on a white background) |
| `-Recolor` | Makes a **3-colour decal**: the picture is reduced to its 3 main colours, and players can change them in game like the game's own recolourable decals. Without it, the decal keeps the picture's colours exactly |
| `-Colors "r,g,b;r,g,b;r,g,b"` | With `-Recolor`: use these 3 colours instead of picking them automatically |
| `-Frame 3` | GIF: use this frame (default 0, the first) |
| `-AllFrames` | GIF: make one decal per frame, `<name>_f00`, `<name>_f01` … (see [Animated decals](#animated-gif-decals)) |
| `-Cars clio,cx7` | Which game cars to render previews on (default `clio`). Any car file name from `Data\car` works; it is exported once into `research\<car>\` |
| `-NoPreview` | Skip the 3D renders (faster) |

## Output (`out\<name>\`)

| File | What |
|---|---|
| `decal_<name>.png` | The decal: 512×512 RGBA, the game's near texture |
| `decal_<name>_s.dds` | Far copy: 256×256 DXT3 with mips, the same format as the game's decals (made with JMDReader's encoder) |
| `<name>.xml` | Decal settings: `custom no`, or `custom yes` + the 3 default colours (`-Recolor`). UTF-16 like the game's |
| `icon_<name>.png` | 64×64 shop icon |
| `layout_<name>.png` | The decal over a coloured template guide, to see where everything is |
| `source_<name>.png` | The input picture (or GIF frame) as read |
| `colors_<name>.txt` | The 3 colours (`-Recolor` only) |
| `preview\<car>_left/right/top/front34.png` | Renders on game cars. `<car>_texture.png` is the composed car texture |

## How decals map onto a car

Checked with a labelled test grid rendered on the Clio (`research/test_grid.png`, `out/test/`) and the cx7.

A decal is one 512×512 image laid over the car's paint, **1:1 with the paint mask** (`<car>_base.png`).
The car's model UVs decide where each pixel lands. All cars share the same unfolded layout:

| Rows | Part of the car | Orientation |
|---|---|---|
| 0–128 | **right** side | upside down: row 0 = sill, row 128 = roof line |
| 128–256 | **top** (hood, roof, trunk lid; the hood and roof are part files that use this band) | row 128 = right edge, row 256 = left edge |
| 256–384 | **left** side | upright: row 256 = roof line, row 384 = sill |
| 384–512 | not shown by the game | |

The front of the car is always to the **right** (high u). [template_guide.png](template_guide.png) shows this over the
Clio's UV wireframe.

**Evidence that the mapping is 1:1** (the bottom quarter is never drawn, not squeezed in):
- Every game paint mask and decal checked leaves rows 384–512 empty: clio, cx7, tutuki, sambari, porter2, scooter,
  `c_decal_01`, `a_flame_001`.
- A test render that squeezed all 512 rows into the paint area put the unused band on the left door, which no game
  decal would survive.

Cars differ a little in where their panels sit inside each band, so check the preview on the car you care about.
Windows are glass in the game (drawn without the decal), but the preview paints them like body.

**How the game draws it** (`Data\etc\fx.jmd` → `cartexture.fx`):
- **Normal decal** (`custom no`): colour = decal rgb × the mask's shading, then blended by the decal alpha.
- **3-colour decal** (`custom yes`): the decal's R/G/B channels = the player's decal colours 1/2/3. Black is
  transparent, and the alpha comes from r+g+b. `<color0..2>` in the xml are the default colours, written as A R G B.

## For the developer

`make_package.ps1` writes `out\package\` in the client folder layout:

| File | Change |
|---|---|
| `Data\car\common\decal4.jmd` | + `decal_<name>.png`, `decal_<name>_s.dds`, `<name>.xml`, `icon/<name>.png` (decal4 is the game's newest decal archive) |
| `Data\car\common\decalinfo.jmd` | `list.xml` + `<part id='N' name='<name>' tex='decal_<name>'/>`. N starts after the highest id in use (1000 → 1001, 1002 …) or at `-StartId` |
| `FileInfo.0m` | Copy of the client folder's file list (`<client>\FileInfo.0m`, read only), with the two archives' new size and block hashes |

- `package_log.txt` lists what was added.
- The script refuses names or ids that already exist.
- Every new entry is read back and must be byte-identical.

Still needed (not in the package):
1. **Server/DB:** a decal item for each new decal id (shop entry, price), the same way as the existing decals.
2. **Launcher:** put the two archives and `FileInfo.0m` in the patch manifest. The launcher re-downloads any listed
   file that differs, so copying the package into a client by hand only lasts until the next launch.

## Animated (GIF) decals

**The game can't animate a decal today.**
- A decal is one still texture.
- Its xml only has colour settings.
- The car shader (`cartexture.fx`) has no time or frame input. The game composes the car's texture once, when the car
  is painted, not every frame.

What the tool does with a GIF:
- By default it takes one frame (`-Frame`).
- With `-AllFrames` it makes every frame a separate, ready decal and prints the GIF's frame delays.

Two ways to get real animation, both developer work:
1. **Client mod** (`landverse.dll`, which already adds the under-car neon): swap the car's decal between the frame
   decals on a timer and recompose that car's texture. It's cheap for one car, but needs care with many cars on
   screen. Our `<name>_fNN` decals and the frame delays are the input it would need.
2. **Effects instead of decals:** roof accessories (`Data\car\common\lamp.jmd`) can name an animated glow effect
   (`lampEffect`; the Woong lamps and the siren bar use one). New glowing or moving accessories are possible.
   Brand-new effect types are defined in files we can't decode yet.

## Files

| Path | What |
|---|---|
| `make_decal.ps1` | Picture/GIF → decal + previews (main tool) |
| `make_package.ps1` | Finished decals → `out\package\` (patched copies of decal4.jmd, decalinfo.jmd, FileInfo.0m) |
| `scripts/layout_decal.py` | Places the picture in the template, does background removal, 3-colour reduction and the icon (numpy, Blender's Python) |
| `scripts/preview_car.py` | Blender render of a game car with the decal (`blender -b -P`) |
| `scripts/pngio.py` | PNG read/write (copied from `tuktuk_car/scripts`) |
| `template_guide.png` | The 512 template, labelled, over the Clio's UVs |
| `research/extract_car.ps1` | Read-only export of a game car (archive + OBJ meshes) into `research\<car>\` |
| `research/uv_overlay.py`, `make_guide.ps1`, `test_grid.ps1` | The checks behind the mapping table |
| `samples/` | Test inputs: `samui_logo.png` and `wave_anim.gif` (4 frames), made by `make_samples.ps1` |
| `out/test_*` | Test results: `test_samui` (sides), `test_samui3` (3-colour, sides+top), `test_top`, `test_wave_f00..03` (GIF frames) |

Needs: Windows PowerShell 5, Blender (its bundled Python is used too), and JMDReader's `JmdLibrary.dll`. The client
folder and the JMDReader folder come from the Workshop's `workshop.config.json` (asked at the Workshop's first start).
Blender is found under `Program Files\Blender Foundation`, or set `"blender"` in that file. Nothing gets installed.
