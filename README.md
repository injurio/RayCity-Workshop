# RayCity Workshop

One local app, in a night theme, for making RayCity car content. Tabs:

- **3D Preview:** any game car with paint, decal, plate, windshield, roof accessory and body-kit parts.
- **Decal:** picture → car decal (runs `decal_tool\make_decal.ps1`).
- **Plate:** licence-plate editor.
- **Windshield:** window tint and pattern editor.
- **Roof accessory:** OBJ model → `lamp.jmd` item, with an optional glow effect.
- **Wheels:** repaint a game rim, or turn your own OBJ rim into a `wheel.jmd` wheel (normal + wide).
- **Set effect:** plays the game's set-item effects (legend auras, wheel sparks, lamp effects) on the car, and makes new
  ones from them with your own colours or pictures.
- **Map:** the city map tiles in 3D with their textures and render maps (lightmaps), for every map in `Data\field`.
- **Import & ask Claude:** drop files and describe what you want; Claude picks the request up and does the work.

Game files are only read. Everything the app writes goes to `workshop\cache`, `workshop\out`, `workshop\inbox` and
(decals) `decal_tool\out`.

Source: https://github.com/injurio/RayCity-Workshop. Setup for a server machine: the repo's Releases page (see
[Install on a server machine](#install-on-a-server-machine)).

**Status (2026-11-20)**
- Every tab tested in the browser: Clio previews; a plate, a windshield and a roof accessory made and packaged; a
  decal made from the sample logo; an import request saved and answered.
- Wheels, Set effect and Map (added later the same day) were tested in the browser:
  - **Wheels:** game rims shown on the Clio; a repainted rim and an OBJ rim made and packaged.
  - **Set effect:** Horus, TIG2010 and other set effects played; a recoloured Horus made, packaged and previewed from
    its own files.
  - **Map:** tiles of b1, d1 and sm (Samui) shown with render maps and the car for scale.
- **Not tested in game.** New item ids also need the server/DB side (see [For the developer](#for-the-developer)).

## Start

Double-click `Start_Workshop.cmd`. It starts the server and opens http://127.0.0.1:8765/ in your browser. Close the
black window to stop it. Or from a terminal, in the Workshop folder:

```powershell
node server.js --open
```

**Folders (asked at the first start):** the Workshop asks for two folders and saves them in `workshop.config.json`:

| Folder | What | Check |
|---|---|---|
| Client folder | The RayCity client: the folder with `Data\` and `FileInfo.0m`. Game files are only read from it. | has `Data\car` |
| JMDReader folder | `JMDReader-master` (or its `dist\JMDReader`). Not shipped with the Workshop. | has `JmdLibrary.dll` |

A folder picker opens for each; if it is cancelled, the path can be typed in the black window. At every start both
folders are checked again, and **a folder that is gone is asked for again**. If a folder goes away while the Workshop
is running, the page says so. `Change_Folders.cmd` asks for both again on purpose. `-NoDialog` (or
`WORKSHOP_NODIALOG=1`) asks in the console only, for machines without a desktop.

Optional `"blender"` in `workshop.config.json`: Blender's folder or `blender.exe`, when it is not under
`Program Files\Blender Foundation`.

Needs: Node.js (LTS), Windows PowerShell 5, JMDReader's `JmdLibrary.dll`, and Blender (only for the Decal tab).
The server only listens on this PC (127.0.0.1).

## Install on a server machine

The setup is for a machine that pre-renders models (car exports, map tiles, set effects) before they are imported to the
real server.

1. From the repo's **Releases**, download `RayCity-Workshop-Setup-<version>.exe` (or the `.zip`).
2. Run it. It asks for the install folder (default `C:\RayCity Workshop`), copies the Workshop there and makes
   Start-menu and desktop shortcuts. An update keeps `workshop.config.json`, `cache\`, `out\` and `inbox\`.
3. If Node.js is missing, the setup offers to install Node.js LTS with `winget` (or install it from https://nodejs.org/).
4. Start **RayCity Workshop**. The first start asks for the client folder and the JMDReader folder.

Building the release (developer): `powershell -File release\build_release.ps1 -Version 1.0.0` writes
`release\dist\RayCity-Workshop-<version>.zip` and `RayCity-Workshop-Setup-<version>.exe` (Windows IExpress; no extra tools).

The first time you open a car it takes about 10 seconds (it's exported into `cache\cars\<car>\`), then it's instant.

## Tabs

### 3D Preview

- **Car:** search by name, display name or CarID. **Our own new cars come first, marked ★**: Samui Tuk (1017,
  `tuktuk_car`) and Steelwedge (1018, `evtruck_car`). They are read from `<folder around the Workshop>\<project>\package\Data\car\` (on the dev PC `Ray\<project>\…`) (the car
  archive plus that package's `car.xml`, read only). Any future project with a `package\Data\car\car.jmd` shows up the
  same way after a restart. When a project rebuilds its package, the workshop re-exports that car the next time it's
  opened.
- **Cars added by hand:** a car `.jmd` copied into the client's `Data\car` also shows with a ★. The workshop takes its id
  and name from the client's `car.xml` (`<client>\Data\car\car.jmd`, read only). With no row it is listed as id 0.
- **"Big" cars:** some cars are converted with `Convert_car --game full` and drawn by the server's `landverse.dll` mod,
  for example aventadorlb. Their `body_*.0m` is only a 12-vertex stand-in, so the workshop draws `big_<lod>.rcb`
  instead: body, glass, and the doors with their windows. The `RCB1` layout is in `backend\export_car.ps1`.
- **Paint:** colours 1/2/3, as players pick them, plus quick presets.
- **Decal / Plate / Windshield / Roof accessory / Wheels / Set effect:** choose "Game …" to browse the game's own items
  (766 decals, 626 plates, 489 windshields, 390 accessories, 1 067 wheels, 41 set effects), or "My …" for items made
  here. 3-colour decals and tinted windshields show colour pickers.
- **Body kit parts:** every `list.xml` variant per part folder (bumpers, spoiler, roof …).
- **Toolbar:** camera views, Spin, Texture (shows the composed 512×512 car texture), Screenshot (PNG download), and
  these toggles, which work in every tab:
  - **Wheels turn:** each wheel spins at its own mount.
  - **Game look:** lighting like the game's car shader (`fx.jmd` `standard/pixel.fx`): diffuse × sun light plus a
    reflection, with a sky gradient standing in for the game's cube map.
  - **Lights:** head and tail lights glow (draw groups 3/4), with light pools on the ground.
  - **Doors:** open and close.
    - Doors are the draw parts of category 1: in the body for ordinary doors, or in the roof file for scissor-door
      cars like sparta. Big cars use their `big_door*` meshes.
    - Each door turns on a hinge at its front edge: ordinary doors swing out by 65°, scissor doors go up by 67.5°
      (sparta's own track).
    - It's an approximation: the real swing is a controller inside the `.0m` that the workshop doesn't read yet.
  - **Effects:** pauses or plays the set effects and the accessory glow.
  Mouse: drag = turn, right-drag = move, wheel = zoom, double-click = reset.
- Accessories with a glow effect pulse in the preview. This only *suggests* the game's effect; it isn't the real
  effect.

### Decal

Same options as `decal_tool\make_decal.ps1` (see `decal_tool\README.md`). The result shows on the 3D car, with the
tool's layout and render images under it. **Build package** = `decal_tool\make_package.ps1`.

### Plate (128 × 64)

- **Design:** background colour or fade, border, rounded corners, bolts, a picture, and two lines of text (any
  Windows font).
- **Edit:** drag on the plate to move the text or the picture.
- **Preview:** the design shows live on the car's front and rear plates.

### Windshield (64 × 64, the game draws it on every window)

- **Picture:** fixed colours.
- **Tint:** players pick 1 colour.
- **Pattern:** players pick 3 colours (red/green/blue parts of the picture = colours 1/2/3).
- **Darkness at top/bottom:** the tint strength, which is the texture's alpha, as in the game's glass.

### Roof accessory

1. Drop an OBJ (Blender: File → Export → Wavefront, Z up, metres; car front = −Y) and optionally its PNG texture.
2. **Size / Turn / Forward-back / Up-down** fit it on the roof. **Sit on roof** puts its base on the roof.
3. **Glow effect:** reuses one of the game's 18 lamp effects (siren, Desert, police, the Woong lamps …).
   The game can't load new effect types.
4. **Make accessory**, then **Build package**.

Limits, from the game's format:
- The whole accessory uses **one 64×64 texture**. The game draws it into the car texture's lamp slot.
- The model is one draw part, at most 65 000 vertices. Game accessories use 200–2 000 triangles.
- The same model is used for all three detail levels (LOD 0/1/2).

### Wheels (texture 128 × 128)

1. **Rim:** pick one of two ways.
   - *Repaint a game rim:* pick the rim. The new wheel keeps its shape.
   - *My own rim model:* drop an OBJ and its PNG, then set it up:
     - **Axle along:** the workshop picks the thinnest side for you.
     - **Flip:** use it if the face points inwards.
     - **Fit game size:** scales it to about 0.35 m radius with the tyre.
2. **Texture:** tint, hue, brightness and a logo. Drag the logo on the texture; *Round* clips it to a circle. The base's
   alpha is kept, because the game uses it as shading.
3. **Make wheel**, then **Build package**. Each wheel gets two list rows, `<name>` and `<name>wide`, like the game's own
   rims. The wide version is for wide cars.

How the game stores wheels (`wheel.jmd`):
- **Meshes:** `<mesh>_0/1/2.0m`. LOD 2 has the most detail. LOD 0 is the same 26-vertex far disc for every rim.
- **Textures:** `<tex>.png` (128 × 128) plus `_s.dds` (64 × 64, DXT3).
- **Icons:** `icon/common_wheel_<name>.png`, 64 × 64.
- **List rows:** `<part id name mesh tex/>`. Many rows share a mesh.
- **Wheel space:** the axle is X, the rim face looks to −X, and the radius is about 0.35 m including the tyre.
- **Wide meshes:** the inner edge stays at x = +0.12; the face moves out by about 0.115 m and the radius grows ×1.05.
- **Texture slot:** the texture sits in the car texture's wheel slot (0, 0.75, 0.25, 1).
- **Preview:** the rim goes on the body's wheel mounts (slots 0 and 1) with a stand-in tyre.

### Reshape (sculpt the car)

Two menus:
- **Edit car:** fix broken spots, or change the body or a fitted part. With **All pieces together** (on by default), the
  brush shapes the body and every fitted part as one, so a separate roof part follows the body's roof edge.
- **Shape new set:** pick a part folder and the variant to start from, reshape it, and save it under a new name as a
  **new body-kit part**. The original part stays as it was.

Tools:
- **Brush** (left-drag on the car; right-drag turns the view, shift-drag moves it):
  - **Move:** grab and drag.
  - **Push / pull:** drag up or down to push the surface in or pull it out.
  - **Smooth**, **Flatten** and **Restore** (back to the original shape) work by rubbing over the surface.
  - **Size**, **Strength**, and **Mirror left / right** (on by default; it keeps the car symmetrical).
- **Whole piece:** size % in X/Y/Z, move in cm, and inflate along the surface. Then press **Apply**.
- **Broken spots:**
  - **Find** marks two kinds of problem in red:
    - spikes: a point more than 5 cm and 2× the neighbours' spread away from their middle (open panel edges are
      skipped);
    - stray needle triangles: an edge over 1 m and 15× the usual edge, on a needle-thin triangle.
  - **Next ›** flies the camera to each one; **Fix all** smooths them.
  - Tested: clean cars show 0–12 hits, and a 25 cm spike I added was found and fixed.
- **Undo / Redo / Reset piece.**
- **Save & build package**, then **Load saved edits** to continue later.

What saving does (`backend\reshape.ps1`):
- **Your edit:** LOD 2 gets your shape. LOD 1 and 0 get the same change, carried over from the LOD-2 points within
  6 cm. A LOD file that is identical to LOD 2 gets the exact shape.
- **Normals:** each normal changes only by how much the surface around it bent, so hard edges and seams keep their look.
- **Writing:**
  - `.0m` files go through JMDReader `OmObjImport.ReplaceCarGeometry`, which keeps mounts, door controllers and part
    settings. Each one is then re-parsed: same parts, same triangle count.
  - Big cars' `big_<L>.rcb` files are patched in place.
- **Package:** `out\package\car_<car>\Data\car\<car>.jmd`, with `FileInfo.0m` when the test client's file list has
  the car. Hand-added cars aren't in that list, so add them to the launcher's list yourself.
- **New sets:** a new set gets `<folder>/<name>_0/1/2.0m`, a `list.xml` row using the base part's texture, and a copy
  of the base part's icon. The server still needs a shop item for its id.

### Reshape → Clean texture ("broken pixels")

**Who needs it:** cars converted with `Convert_car --game full`, such as aventadorlb. On those cars, 72% of the body's
triangles take their colour from the small `_color` picture. In the game's 512×512 car texture that picture is shrunk
into a 128×64 strip, so vents, trim and splitter turn into stair-stepped speckles. The tab's info line shows the share
for the loaded car.

**Clean & preview** (`backend\clean_texture.ps1`, about 5 s for a big car):
1. **Read the colours:** each detail triangle gets the average colour it shows in the game. That's read from the
   picture shrunk to the game's 128×64.
   - If most of its samples are see-through, it goes to a see-through swatch, so paint still shows there (the Clio's
     detail picture is mostly see-through, so it barely changes).
   - A triangle that straddles a colour edge (under 80% one colour) is split in 4 at its edge midpoints, up to twice
     and never below ~6 pixels. Neighbours share the midpoints, so no cracks open.
2. **Build the palette:** colours covering at least 0.2% of the detail area become swatches, up to **Colours** (16 by
   default). The biggest comes first, then always the most different one, then k-means refines them, all weighted by
   area.
3. **Remove specks** (optional): colour islands under 4 cm² take their surroundings' colour. "Teeth" of zigzag edges
   (two of their three neighbours in another colour) are straightened.
4. **Rebuild the picture:** `<car>_color.png` becomes a grid of solid swatches, same size, plus its `_s.dds`. Each
   detail triangle points at its swatch's centre; corners shared by two colours are split. So every triangle is one
   clean colour, and colour edges follow the model.
5. **Paint mask** (optional): blobs under 40 pixels join their surroundings, and edges are softened.
6. **Output:** the files are rewritten (`big_*.rcb` block by block, or `body_*.0m` through the importer) and
   re-read, giving `out\carmod\<car>\clean\<car>.jmd` and the package `out\package\car_<car>\`.

**After cleaning:**
- The workshop shows the **cleaned copy** of the car everywhere (the car info line says "cleaned copy").
- Reshape saves build on top of it. Clean first, then reshape: cleaning always starts again from the original car.
- **Undo clean** goes back to the original.

**Tested on aventadorlb:** the speckles on the splitter, door jambs and headlight surrounds are gone. The hood vents
keep a slightly stepped outline, because that's the model's own triangle edges and the picture holds no finer outline.

### Set effect

1. Pick a set effect. The info line shows its **set-item option** (e.g. `US_LegendHorus`), where it sits (car, lamp or
   wheels) and its files.
2. **Start / End (fade out) / Repeat / Speed / Glow** play it on the car. Legend effects play fade-in → loop → fade-out,
   like the game.
3. **Make a new one from it:** for each texture, keep it, recolour it (hue / tint) or replace it with your picture.
4. **Make effect**, then **Build package**.

What the preview can't show yet:
- **Particle effects:** 13 of the 41 effects use ReFx emitters (the thunder/skull wheel sparks, and the eagle and venom
  lamps). They are listed but not drawn.
- **Fades and blend modes:** these can't be read from the files, so every plane is drawn as additive glow.
- **Speed:** speed-dependent effects (Legend Wind / Booster) are shown at any speed.

How the game links them (`Data\effect\effect.jmd`). A set item names an option, and the chain is:
1. `relement\effectlink.xml`: `<option name='US_…' effect='…' [legend='true']/>`.
2. `relement\relementeffect.xml`: the `<effectGroup>`, then its `<effectItem>`s. Each item has:
   - `fileName`, or a `<seq>` of files;
   - `attatchType`: none (the car), `kAttatchLamp` or `kAttatchWheel0-3`;
   - `posOffset`.
3. `relement\<file>.0m`: a "rootRelement" scene of textured planes with position/rotation/scale and visibility keys
   (JMDReader `OmResource` / `OmSceneNode`).
4. Its textures: `relement\<tex>.dds/.tga`.

A new effect is a copy of the template's `.0m` files that use a changed texture:
- **Renaming:** texture names are stored as `0x27AA` string records (u16 id, u32 length, UTF-16 text). The copy uses new
  names **of the same length**, so no other byte moves.
- **Check:** the copy is re-parsed and must have the same objects, planes and transforms.
- **Textures:** new textures are encoded like the originals (same size and DDS format/mips, or TGA layout).
- **Names:** it gets the effect group `EffectType_SetItem_WS_<name>` and the option `US_WS_<name>`. **The server's set
  item must use that option name.**

### Map

- **Loading:** pick a map and click a tile; the 8 tiles around it load too (shift-click adds tiles). Every area in
  `Data\field` is listed, including `sm`, the Samui island. The first time, each tile takes about 2 s; it is exported
  into `cache\map\<area>\`.
- **Show:** one of three views:
  - textures × render map, as the game draws the ground;
  - textures only;
  - the render maps (lightmaps, `<tile>_*_completemap.dds`) only.

  You can also show the placed props, and the car from the 3D Preview at street level for scale.
- **Render maps:** the selected tile's render maps are listed under the view. Click one to open it full size.
- **Read-only:** this is a viewer only.
- **Tile coordinates:** tiles are 512 m. Tile `XXXX_YYYY` starts at x = (XXXX − 1000) × 512 m, and the same for y.
- **How it reads tiles:**
  - JMDReader `OmFieldMesh`: tile mesh, UV and lightmap UV, materials.
  - JMDReader `OmFieldObjects`: props from `xref.jmd`, shown untextured.
  - The client's texture lookup order: `<tile>_tex.jmd`, then `common_<area>\tex.jmd`, then `common\tex.jmd`.

### Import & ask Claude

1. Pick what it's for, write what you want in your own words (any language), and drop in any files.
2. **Save request** writes `inbox\<time>_<title>\request.md` + the files + what the 3D Preview shows.
3. Copy the line it shows (e.g. `Workshop request: please read Ray\workshop\inbox\…\request.md and do it.`) and paste
   it into the Claude Code session.
4. Claude does the work and writes `reply.md` in the same folder. The request list shows it as answered.

For Claude: read `request.md` and the files next to it, do the work with the workshop tools where they fit, and write
the answer (what was made, where, what's left) to `reply.md` in that folder.

## For the developer

Each **Build package** writes the client folder layout. Copy it over a **test copy** of the client, never the real
`Data`:

| Tab | Package | Changes |
|---|---|---|
| Decal | `decal_tool\out\package\` | `decal4.jmd`, `decalinfo.jmd` list, `FileInfo.0m` |
| Plate | `workshop\out\package\plate\` | `Data\car\common\plate.jmd`: + `common_plate_<n>.png/_s.dds`, `icon/common_plate_<n>.png`; `list.xml` + `<part id name tex='common_plate_<n>'/>`; `FileInfo.0m` |
| Windshield | `workshop\out\package\glass\` | `glass.jmd`: + `<n>.png/_s.dds/.xml`, `icon/<n>.png`; `list.xml` + `<part id name tex/>`; `FileInfo.0m` |
| Roof accessory | `workshop\out\package\lamp\` | `lamp.jmd`: + `<n>_0/1/2.0m`, `lamp_<n>.png/_s.dds`, `<n>.xml` (lampEffect), `icon/common_lamp_<n>.png`; `list.xml` + `<part id name mesh tex/>`; `FileInfo.0m` |
| Wheels | `workshop\out\package\wheel\` | `wheel.jmd`: + `<n>.png/_s.dds`, `icon/common_wheel_<n>[wide].png`, (OBJ rims) `<n>_0/1/2.0m` and `<n>wide_0/1/2.0m`; `list.xml` + 2 rows `<part id name mesh tex/>`; `FileInfo.0m` |
| Set effect | `workshop\out\package\effect\` | `Data\effect\effect.jmd`: + `relement\ws_<n>[_i].0m` and the new textures; `relement\relementeffect.xml` + effectGroup/effectItems; `relement\effectlink.xml` + `<option name='US_WS_<n>' …/>`; `FileInfo.0m` |

How the packages are built:
- New ids continue after the highest id in that `list.xml`.
- Names that already exist are refused.
- Every new file is read back and must be byte-identical, and all old entries must still be there.
- `package_log.txt` lists everything.
- `FileInfo.0m` is a copy of the client folder's `FileInfo.0m` (read only) with that archive's new size and block hashes.

**Packages of the same kind overwrite each other.** Put everything for one archive in one build (tick several items).
The decal package and these packages touch different archives, but each has its own `FileInfo.0m`. Merge them before
shipping, or ship one at a time.

**Still needed (not in the packages):**
1. **Server/DB:**
   - a shop item for each new plate, windshield, accessory, wheel and decal id, the same way as the existing ones;
   - for a set effect, the set item's option must be `US_WS_<name>`.
2. **Launcher:** put the changed archives and `FileInfo.0m` in the patch manifest. The launcher re-downloads any listed
   file that differs.

## How the game stores these (findings, read-only)

All of these use the car's one 512×512 composed texture (`cartexture.fx`; slot rects from `Compose.SLOT` in
`web\compose.js`, which matches JMDReader's `PreviewTextureFinder`):

| Item | Archive | Texture | Composite rect (u0, v0, u1, v1; v from top) | Proof |
|---|---|---|---|---|
| Decal | decal*.jmd | 512² | paint rect (0, 0, 1, 0.75), 1:1 | `decal_tool\README.md` |
| Plate | plate.jmd | 128×64 | slot 13 (0.75, 0.875, 1, 1) | Clio: the only body faces in that rect are a 6-triangle quad at the rear plate (y 1.78, z 0.81); in the front bumper, one at y −1.91, z 0.47. JMDReader names this slot "hood" (part type 9); hood textures are 64×32 and mostly empty |
| Windshield | glass.jmd | 64×64 | slot 2 (0, 0.25, 0.125, 0.375) | every window part (draw group 1) maps here |
| Roof accessory | lamp.jmd | 64×64 | slot 7 (0, 0.375, 0.125, 0.5) = part type "lamp" | game lamp meshes' UVs: police_bar, taxi_box, roofcarrier, santa_cap all stay in this rect |

- **Windshield xml:** `<custom>yes</custom>`, `<color0..2>A R G B</color0..2>` and `<customCount>` (1 or 3).
  R/G/B of the texture pick colours 1/2/3 and alpha = tint strength (basic_k: R = 255 everywhere, alpha 61–255).
- **Roof mount:** the fitted roof part (`<car>\roof\<mesh>_<L>.0m`) has a mount in slot 7. On the Clio it is at
  (0, 0.41, 1.45), identity rotation. Accessory meshes are modelled around their own origin with the base at z ≈ 0.
- **Accessory effect:** `<name>.xml` = `<part><lampEffect name = 'EffectType_Lamp_…'/></part>`. 18 effects are
  used (`cache\catalog\lamp.json`, field `effect`).
- **Naming rules** (from the game's own list comments): plates `tex='common_plate_<name>'`; glass name = tex; lamps
  `tex='lamp_<name>'`, icon `icon/common_lamp_<name>.png`.
- **Far copies** (`_s.dds`): half size, same DXT format and mips as a game texture of the same kind (JMDReader
  `TextureCodec.EncodeDdsLike`).

## Files

| Path | What |
|---|---|
| `Start_Workshop.cmd` | Starts the server and opens the page (asks for the folders first when needed) |
| `Change_Folders.cmd` | Asks for the client folder and the JMDReader folder again |
| `workshop.config.json` | The two folders (+ optional Blender); made at the first start, not in git |
| `backend\setup_paths.ps1` | The folder questions (picker, or console with `-NoDialog`) |
| `backend\paths.ps1` | Reads `workshop.config.json` for every backend script (client folder, `JmdLibrary.dll`, Blender) |
| `decal_tool\` | Copy of the decal tool's scripts (the dev PC uses `Ray\decal_tool` next to the Workshop when it is there) |
| `release\` | `build_release.ps1` and the setup's `install.ps1` |
| `server.js` | Local server (Node, no packages): static files, catalog/car export, tool jobs, hand-offs |
| `web\index.html`, `app.css`, `app.js` | The page (night theme) and its logic |
| `web\viewer.js` | WebGL viewer (no libraries) |
| `web\compose.js` | The game's car-texture compositing: paint mask, decal (normal and 3-colour), part layers, plate, glass |
| `backend\common.ps1` | Archive access, mesh → JSON, PNG/DDS, UTF-16 xml, FileInfo update |
| `backend\export_car.ps1` | Car → `cache\cars\<car>\` (meshes of every part variant, textures, wheels at the body mounts) |
| `backend\catalog.ps1` | Game lists → `cache\catalog\` (cars, plates, windshields, decals, accessories, wheels, set effects) |
| `backend\export_lamp.ps1` | A game accessory's or wheel's mesh + texture for the preview (`-Kind lamp` or `wheel`) |
| `backend\make_wheel.ps1` | Wheel: a repaint (new texture on a game rim), or an OBJ rim → `.0m` ×3 for normal + wide (from copies of `j6a` / `j6awide`), texture, icons, `parts.txt` |
| `backend\export_effect.ps1` | One set-effect file → its planes, their matrices at 30 fps, textures (`cache\effects\`) |
| `backend\make_effect.ps1` | New set effect: copies of the template's `.0m` files with renamed textures, the new textures, xml lines |
| `backend\package_effect.ps1` | Made set effects → copy of `effect.jmd` + `FileInfo.0m` (`out\package\effect\`) |
| `backend\clean_texture.ps1` | Clean texture: detail triangles → solid palette swatches (split along colour edges), see-through kept, paint mask cleaned; cleaned car copy + package |
| `backend\reshape.ps1` | Reshape: saves sculpted meshes (all LODs; `.0m` through the importer, `.rcb` patched), new body-kit sets, and the car package |
| `backend\export_tile.ps1` | One map tile → mesh (UV + render-map UV), props, textures and render maps (`cache\map\<area>\`) |
| `backend\make_item.ps1` | Plate / windshield → game-named files in `out\<kind>\<name>\game\` |
| `backend\make_lamp.ps1` | Roof accessory OBJ → `.0m` ×3 (JMDReader `OmObjImport.ReplaceCarGeometry` on copies of `taxi_box_<L>.0m`) + texture, xml, icon |
| `backend\package_items.ps1` | Made items → `out\package\<kind>\` (archive copy + `FileInfo.0m`) |
| `cache\` | Exports of game data (safe to delete; rebuilt on demand) |
| `out\<kind>\<name>\` | Each made item: the page's inputs, `game\` files, `meta.json` |
| `inbox\` | Import requests (`request.md`, files, Claude's `reply.md`) |
