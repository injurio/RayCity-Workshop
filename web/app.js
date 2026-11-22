// RayCity Workshop front end.
'use strict';
const $ = id => document.getElementById(id);
const qsa = (s, r = document) => [...r.querySelectorAll(s)];
const api = async (url, body) => {
  const r = await fetch(url, body ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) } : {});
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
};
const imgCache = new Map();
const loadImg = url => {
  if (!url) return Promise.resolve(null);
  if (imgCache.has(url)) return imgCache.get(url);
  const p = new Promise(res => { const i = new Image(); i.onload = () => res(i); i.onerror = () => res(null); i.src = url; });
  imgCache.set(url, p); return p;
};
const fileToDataURL = f => new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = rej; r.readAsDataURL(f); });
const fileToText = f => new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = rej; r.readAsText(f); });
const enc = encodeURIComponent;
const hex2rgb = h => [1, 3, 5].map(i => parseInt(h.substr(i, 2), 16));
const rgb2hex = c => '#' + c.map(v => Math.max(0, Math.min(255, v | 0)).toString(16).padStart(2, '0')).join('');
const debounce = (fn, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };
const status = s => { $('status').textContent = s; };
const busy = on => $('vBusy').classList.toggle('hidden', !on);

// ------------------------------------------------------------------ viewer + state
const viewer = new Viewer($('gl'));
const S = {
  car: null, model: null, variants: {}, geos: {}, tex: {}, carTex: null,
  decal: null, plate: null, plateDefault: null, glass: null, lamp: null,
};

function placeViewer(tab) {
  const slot = document.querySelector('#tab-' + tab + ' .viewer-slot');
  if (slot && $('viewerHost').parentElement !== slot) slot.appendChild($('viewerHost'));
}
qsa('#tabs button').forEach(b => b.onclick = () => {
  qsa('#tabs button').forEach(x => x.classList.toggle('on', x === b));
  qsa('.tab').forEach(t => t.classList.toggle('on', t.id === 'tab-' + b.dataset.tab));
  placeViewer(b.dataset.tab);
  const v = { plate: 'rear34', glass: 'front34', roof: 'front34', wheel: 'front34', effect: 'front34' }[b.dataset.tab];
  if (v) viewer.view(v);
  if (b.dataset.tab === 'import') refreshHandoffs();
  if (b.dataset.tab === 'wheel' && !WHEELS.length) fillWheelBase();
  if (b.dataset.tab === 'effect' && !$('fxList').options.length) fillFxList();
  if (b.dataset.tab === 'map') mapOpen();
  viewer.tool = b.dataset.tab === 'shape' ? rsTool : null;
  document.querySelector('#viewerHost .vhelp').textContent = b.dataset.tab === 'shape' ? 'left-drag = brush · right-drag = turn · shift-drag = move · wheel = zoom' : 'drag = turn · right-drag = move · wheel = zoom · double-click = reset';
  if (b.dataset.tab === 'shape') { rsFill(); rsStart(); clStatus(); } else if (RS.ring) RS.ring.hidden = true;
});
placeViewer('viewer');
qsa('[data-view]').forEach(b => b.onclick = () => viewer.view(b.dataset.view));
$('vSpin').onchange = e => { viewer.autoRotate = e.target.checked; };
$('vTex').onchange = e => { $('vTexImg').classList.toggle('hidden', !e.target.checked); showTexPeek(); };
$('vShot').onclick = () => { const a = document.createElement('a'); a.href = viewer.screenshot(); a.download = (S.car || 'car') + '_preview.png'; a.click(); };
function showTexPeek() { if ($('vTex').checked && S.carTex) $('vTexImg').src = S.carTex.toDataURL(); }

// ------------------------------------------------------------------ cars
let CARS = [];
async function initCars() {
  CARS = await api('/api/catalog?kind=cars');
  CARS.sort((a, b) => (!!b.project - !!a.project) || a.name.localeCompare(b.name));
  fillCarList('');
  const last = localStorage.getItem('ws.car') || 'clio';
  $('carSelect').value = last;
  await loadCar(CARS.some(c => c.name === last) ? last : CARS[0].name);
}
function fillCarList(q) {
  q = q.toLowerCase();
  $('carSelect').innerHTML = CARS.filter(c => !q || c.name.includes(q) || (c.display || '').toLowerCase().includes(q) || String(c.id) === q)
    .map(c => `<option value="${c.name}">${c.project ? '★ ' : ''}${c.display ? c.display + ' · ' : ''}${c.name} (${c.id})${c.project ? (c.path ? ' · new, ' + c.project : ' · added by hand, ' + c.project) : ''}</option>`).join('');
  if (S.car) $('carSelect').value = S.car;
}
$('carSearch').oninput = e => fillCarList(e.target.value);
$('carSelect').onchange = e => loadCar(e.target.value);

async function loadCar(name) {
  S.loading = true;
  busy(true); status('loading ' + name + ' (first time takes ~10 s)…');
  try {
    const model = await api('/api/car?name=' + encodeURIComponent(name));
    S.car = name; S.model = model; localStorage.setItem('ws.car', name);
    if ($('carSelect').value !== name) $('carSelect').value = name;
    const info = CARS.find(c => c.name === name);
    $('carInfo').textContent = (model.cleaned ? 'cleaned copy · ' : '') + (info ? `CarID ${info.id} · class ${info.classId}` + (info.project ? (info.path ? ` · from ${info.project} package, not in the game yet` : ` · added by hand to Data/car (${info.project})`) : '') : '');
    for (const g of Object.values(S.geos)) viewer.free(g);
    S.geos = {}; S.variants = {}; S.partVar = {};
    RS.data = {}; RS.key = null; RS.sets = {}; RS.undo = []; RS.redo = []; if (RS.marks) { viewer.free(RS.marks.geo); RS.marks = null; }
    for (const f of model.folders) S.variants[f.folder] = f.default;
    const base = '/cache/cars/' + name + '/';
    for (const k of [...imgCache.keys()]) if (k.startsWith(base)) imgCache.delete(k); // re-exported (cleaned / rebuilt) cars bring new textures
    S.tex.mask = await loadImg(base + 'tex/' + model.base);
    S.tex.color = await loadImg(base + 'tex/' + model.color);
    S.tex.wheel = await loadImg(base + 'tex/wheel.png');
    S.meshes = { body: await api(base + 'meshes/body.json') };
    S.geos.body = viewer.upload(S.meshes.body);
    { const [lo, hi] = S.geos.body.bounds, len = Math.max(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]);
      viewer.dist = Math.max(4.5, len * 1.75); viewer.target = [0, (lo[1] + hi[1]) / 2, Math.max(0.5, (hi[2] + lo[2]) / 2)]; }
    try { S.geos.wheels = viewer.upload(await api(base + 'meshes/wheels.json')); } catch { /* no wheels */ }
    fillParts();
    await loadParts();
    await updateLamp();
    await updateWheels();
    status(name + ' ready');
    S.loading = false;
    if (document.querySelector('#tab-shape.on')) { rsFill(); await rsStart(); clStatus(); }
  } catch (e) { status('error: ' + e.message); console.error(e); }
  S.loading = false;
  busy(false);
}

function fillParts() {
  $('partsList').innerHTML = S.model.folders.filter(f => f.variants.some(v => v.mesh || v.tex)).map(f => `
    <label class="col small">${f.folder}<select data-folder="${f.folder}">
      <option value="">(none)</option>
      ${f.variants.map(v => `<option value="${v.id}" ${v.id === S.variants[f.folder] ? 'selected' : ''}>${v.id} · ${v.name}</option>`).join('')}
    </select></label>`).join('');
  qsa('#partsList select').forEach(s => s.onchange = async () => { S.variants[s.dataset.folder] = s.value; await loadParts(); });
}

async function loadParts() {
  const base = '/cache/cars/' + S.car + '/';
  S.partLayers = [];
  for (const f of S.model.folders) {
    const v = f.variants.find(x => x.id === S.variants[f.folder]);
    const key = 'part:' + f.folder;
    const same = S.geos[key] && S.partVar[key] === (v && v.id); // keep a fitted part (and its reshaping) when it didn't change
    if (S.geos[key] && !same) { viewer.free(S.geos[key]); delete S.geos[key]; delete RS.data[key]; }
    S.partVar[key] = v && v.id;
    if (!v) { delete S.meshes[key]; continue; }
    if (same) { const slot = Compose.partSlot(f.folder); if (v.tex && slot >= 0) S.partLayers.push({ img: await loadImg(base + 'tex/' + v.tex), slot }); continue; }
    if (v.mesh) { S.meshes[key] = await api(base + 'meshes/' + v.mesh + '.json'); S.meshes[key].file = v.mesh; S.geos[key] = viewer.upload(S.meshes[key]); } else delete S.meshes[key];
    const slot = Compose.partSlot(f.folder);
    if (v.tex && slot >= 0) S.partLayers.push({ img: await loadImg(base + 'tex/' + v.tex), slot });
  }
  buildDoors();
  recompose();
}

// ------------------------------------------------------------------ compose + objects
function paints() { return [0, 1, 2].map(i => hex2rgb($('paint' + i).value)); }
const recompose = debounce(() => {
  if (!S.model) return;
  const layers = [{ img: S.tex.color, slot: 1 }, { img: S.wheelTex || S.tex.wheel, slot: Compose.WHEEL_SLOT }, ...(S.partLayers || [])];
  if (S.lamp && S.lamp.tex) layers.push({ img: S.lamp.tex, slot: 7 });
  const old = S.carTex;
  S.carTex = Compose.compose({
    mask: S.tex.mask, paints: paints(), layers,
    decal: S.decal, plate: S.plate || S.plateDefault, glass: S.glass,
  });
  if (old) viewer.dropTexture(old);
  const objs = [];
  for (const k in S.geos) {
    if (k !== 'body' && !k.startsWith('part:')) continue;
    const d = S.doors && S.doors[k];
    objs.push({ geo: d ? d.rest : S.geos[k], tex: S.carTex, kind: 'car' });
    if (d) for (const door of d.doors) objs.push({ geo: door.view, tex: S.carTex, kind: 'car', model: door.model });
  }
  if (S.wheelObjs && S.wheelObjs.length) for (const o of S.wheelObjs) { o.tex = S.carTex; objs.push(o); }
  else if (S.geos.wheels) objs.push({ geo: S.geos.wheels, tex: S.carTex, kind: 'wheels' });
  objs.push(...lightPools());
  if (typeof rsObjects === 'function') objs.push(...rsObjects());
  if (typeof extraObjects === 'function') objs.push(...extraObjects());
  if (S.lamp && S.lamp.geo) objs.push({ geo: S.lamp.geo, tex: S.carTex, kind: S.lamp.glow ? 'own' : 'car', glow: S.lamp.glow ? 0.8 : 0 });
  viewer.setObjects(objs);
  showTexPeek();
}, 30);
['paint0', 'paint1', 'paint2'].forEach(id => $(id).oninput = () => { localStorage.setItem('ws.' + id, $(id).value); recompose(); });
['paint0', 'paint1', 'paint2'].forEach(id => { const v = localStorage.getItem('ws.' + id); if (v) $(id).value = v; });
const PRESETS = [['#3a6ea5', '#e8e8e8', '#1d2230'], ['#b3262e', '#f0f0f0', '#202020'], ['#1f1f22', '#d9a24f', '#3a3a40'], ['#f2f2f2', '#2a5db0', '#c43030'],
  ['#2f7d4f', '#f5d76e', '#14301f'], ['#e07b21', '#262626', '#ffffff'], ['#6a3fa0', '#40c0e0', '#151520'], ['#c9c9c9', '#7a7a7a', '#303030']];
$('paintPresets').innerHTML = PRESETS.map((p, i) => `<button data-p="${i}" title="preset" style="background:linear-gradient(135deg,${p[0]} 50%,${p[1]} 50%)"></button>`).join('');
qsa('#paintPresets button').forEach(b => b.onclick = () => { PRESETS[b.dataset.p].forEach((c, i) => { $('paint' + i).value = c; localStorage.setItem('ws.paint' + i, c); }); recompose(); });

// ------------------------------------------------------------------ catalog pickers (decal / plate / glass / lamp)
const CAT = {};
let MINE = [];
async function refreshMine() { MINE = await api('/api/outputs'); fillPkgLists(); }

function picker(kind, onPick) {
  const src = $(kind + 'Source'), search = $(kind + 'Search'), list = $(kind + 'List');
  const fill = async () => {
    const mode = src.value;
    search.classList.toggle('hidden', mode === 'none'); list.classList.toggle('hidden', mode === 'none');
    if (mode === 'none') { onPick(null); return; }
    let rows;
    if (mode === 'game') {
      if (!CAT[kind]) { status('loading game ' + kind + ' list…'); CAT[kind] = await api('/api/catalog?kind=' + kind); status('ready'); }
      rows = (kind === 'effect' ? CAT[kind].effects : CAT[kind]).map(r => ({ value: JSON.stringify(r), label: kind === 'effect' ? fxLabel(r) : (r.id !== undefined ? r.id + ' · ' : '') + r.name }));
    } else {
      await refreshMine();
      rows = MINE.filter(m => m.kind === kind).map(m => ({ value: JSON.stringify(m), label: m.name }));
    }
    const q = search.value.toLowerCase();
    list.innerHTML = rows.filter(r => !q || r.label.toLowerCase().includes(q)).slice(0, 800).map(r => `<option value='${r.value.replace(/'/g, '&#39;')}'>${r.label}</option>`).join('');
  };
  src.onchange = fill; search.oninput = debounce(fill, 150);
  list.onchange = async () => { if (list.value) { busy(true); try { await onPick(JSON.parse(list.value), src.value); } catch (e) { status('error: ' + e.message); } busy(false); } };
  return fill;
}

function setColorInputs(prefix, box, settings) {
  const cols = settings && settings.custom ? settings.colors || [] : [];
  $(box).classList.toggle('hidden', !(settings && settings.custom));
  for (let i = 0; i < 3; i++) { $(prefix + i).value = rgb2hex(cols[i] || [0, 0, 0]); $(prefix + i).classList.toggle('hidden', settings && settings.custom && i >= Math.max(1, cols.length)); }
}

picker('decal', async (r, mode) => {
  if (!r) { S.decal = null; recompose(); return; }
  let url, settings;
  if (mode === 'game') { const d = await api('/api/decaltex?tex=' + encodeURIComponent(r.tex) + '&name=' + encodeURIComponent(r.name)); url = d.png; settings = d.settings; }
  else { url = r.url + '?t=' + Date.now(); settings = r.settings; }
  S.decal = { img: await loadImg(url), custom: settings.custom, colors: settings.colors || [] };
  setColorInputs('dcol', 'decalColors', settings);
  recompose();
});
['dcol0', 'dcol1', 'dcol2'].forEach((id, i) => $(id).oninput = () => { if (S.decal) { S.decal.colors[i] = hex2rgb($(id).value); recompose(); } });

picker('plate', async (r, mode) => {
  if (!r) { S.plate = null; recompose(); return; }
  S.plate = await loadImg(mode === 'game' ? '/cache/catalog/plate/' + encodeURIComponent(r.tex) + '.png' : r.url + '?t=' + Date.now());
  recompose();
});
picker('glass', async (r, mode) => {
  if (!r) { S.glass = null; setColorInputs('gcol', 'glassColors', null); recompose(); return; }
  const url = mode === 'game' ? '/cache/catalog/glass/' + encodeURIComponent(r.name) + '.png' : r.url + '?t=' + Date.now();
  S.glass = { img: await loadImg(url), custom: r.settings.custom, colors: (r.settings.colors || []).slice() };
  setColorInputs('gcol', 'glassColors', r.settings);
  recompose();
});
['gcol0', 'gcol1', 'gcol2'].forEach((id, i) => $(id).oninput = () => { if (S.glass) { S.glass.colors[i] = hex2rgb($(id).value); recompose(); } });

// Roof accessory: game lamp (mesh exported by the server) or one of ours; sits on the roof part's slot-7 mount.
S.lampPick = null;
picker('lamp', async (r, mode) => { S.lampPick = r ? { r, mode } : null; await updateLamp(); });
function roofMount() {
  // the fitted roof part's mount (slot 7), else the top of the body
  const m = S.model && S.model.roofMount;
  if (m) return m;
  const b = S.geos.body && S.geos.body.bounds;
  return [1, 0, 0, 0, 0, 1, 0, 0.3, 0, 0, 1, b ? b[1][2] : 1.4];
}
async function updateLamp() {
  if (S.lamp && S.lamp.geo) viewer.free(S.lamp.geo);
  S.lamp = null;
  const p = S.lampPick;
  if (S.model) S.model.roofMount = await currentRoofMount();
  if (p) {
    let mesh, tex;
    if (p.mode === 'game') {
      const d = await api('/api/lampmesh?mesh=' + encodeURIComponent(p.r.mesh) + '&tex=' + encodeURIComponent(p.r.tex));
      mesh = await api(d.mesh); tex = await loadImg(d.png);
    } else { mesh = await api(p.r.mesh + '?t=' + Date.now()); tex = await loadImg(p.r.url + '?t=' + Date.now()); }
    S.lamp = { geo: viewer.upload(mesh, roofMount()), tex, glow: !!(p.r.effect) };
  }
  if (RF.preview) S.lamp = Object.assign(S.lamp || {}, RF.preview());
  recompose();
}
async function currentRoofMount() {
  const v = S.model.folders.find(f => f.folder === 'roof');
  const id = v && S.variants.roof;
  const vv = v && v.variants.find(x => x.id === id);
  if (!vv || !vv.mesh) return null;
  const mesh = await api('/cache/cars/' + S.car + '/meshes/' + vv.mesh + '.json');
  return mesh.mounts && mesh.mounts.find(m => m.slot === 7) ? mesh.mounts.find(m => m.slot === 7).m : null;
}

// Wheels: a game rim (wheel.jmd) or one of ours at the body's wheel mounts (slots 0 and 1), its texture in the wheel slot.
S.wheelPick = null; S.wheelGeos = []; S.wheelTex = null;
picker('wheel', async (r, mode) => { S.wheelPick = r ? { r, mode } : null; WH.active = false; await updateWheels(); });
function tyreMesh() { // the same stand-in tyre as the car export: 0.34 m radius, 0.24 m wide, axle = X
  const n = 28, P = [], U = [], N = [], I = [];
  for (let i = 0; i <= n; i++) {
    const a = i / n * 2 * Math.PI, c = Math.cos(a), s = Math.sin(a);
    for (const x of [-0.12, 0.12]) { P.push(x, 0.34 * c, 0.34 * s); N.push(0, c, s); U.push(0.01, 0.99); }
  }
  for (let i = 0; i < n; i++) { const a = i * 2; I.push(a, a + 1, a + 3, a, a + 3, a + 2); }
  return { positions: P, uvs: U, normals: N, parts: [{ name: 'tyre', group: 0, cat: 0, indices: I }] };
}
function wheelMounts() { return ((S.model && S.model.mounts) || []).filter(m => m.slot <= 1).map(m => m.m); }
async function updateWheels() {
  for (const g of S.wheelGeos) viewer.free(g);
  S.wheelGeos = []; S.wheelObjs = []; S.wheelTex = null;
  let w = null;
  try {
    if (WH.active && WH.preview) w = WH.preview();
    else if (!S.wheelPick) { // the car's default: wheel.jmd 'default' rim with the car export's wheel texture
      const d = await api('/api/lampmesh?kind=wheel&mesh=default&tex=default');
      w = { mesh: await api(d.mesh), tex: null };
    }
    else if (S.wheelPick) {
      const p = S.wheelPick;
      if (p.mode === 'game') {
        const d = await api('/api/lampmesh?kind=wheel&mesh=' + enc(p.r.mesh) + '&tex=' + enc(p.r.tex));
        w = { mesh: await api(d.mesh), tex: await loadImg(d.png) };
      } else w = { mesh: await api(p.r.mesh + '?t=' + Date.now()), tex: await loadImg(p.r.url + '?t=' + Date.now()) };
    }
  } catch (e) { status('error: ' + e.message); }
  if (w && w.mesh) {
    // rim and tyre uploaded once in wheel space; each mount gets its own model matrix (mount x spin), see animFrame
    const rim = viewer.upload(w.mesh, w.tm || null), tyre = viewer.upload(tyreMesh());
    S.wheelGeos.push(rim, tyre);
    for (const m of wheelMounts()) for (const g of [rim, tyre]) S.wheelObjs.push({ geo: g, kind: 'wheels', mount: m, model: m44(m) });
    S.wheelTex = w.tex;
  }
  recompose();
}

// ------------------------------------------------------------------ viewer toggles: wheels turn, game look, lights, doors, effects
// 3x4 row-major (game mount) -> 4x4 column-major (viewer uModel)
function m44(W, M) {
  M = M || new Float32Array(16);
  M[0] = W[0]; M[1] = W[4]; M[2] = W[8]; M[3] = 0; M[4] = W[1]; M[5] = W[5]; M[6] = W[9]; M[7] = 0;
  M[8] = W[2]; M[9] = W[6]; M[10] = W[10]; M[11] = 0; M[12] = W[3]; M[13] = W[7]; M[14] = W[11]; M[15] = 1;
  return M;
}
const rotX = a => { const c = Math.cos(a), s = Math.sin(a); return [1, 0, 0, 0, 0, c, -s, 0, 0, s, c, 0]; };
const rotZ = a => { const c = Math.cos(a), s = Math.sin(a); return [c, -s, 0, 0, s, c, 0, 0, 0, 0, 1, 0]; };
const about = (p, R) => mul34([1, 0, 0, p[0], 0, 1, 0, p[1], 0, 0, 1, p[2]], mul34(R, [1, 0, 0, -p[0], 0, 1, 0, -p[1], 0, 0, 1, -p[2]]));

// Doors: draw parts of category 1 (the game's "door" parts: in the body for ordinary doors, in the roof file for the
// scissor-door cars like sparta) or the big_door* meshes of RCB cars. Split per side into views that share the geo's
// buffers, so sculpting still updates them. The real swing comes from controllers in the .0m that the workshop can't
// read yet; the preview uses a hinge at the door's front edge: ordinary doors turn out about a vertical axis,
// roof-file and big-car doors swing up (scissor).
function buildDoors() {
  S.doors = {};
  for (const key in S.geos) {
    if (key !== 'body' && key !== 'part:roof') continue; // doors live in the body or (scissor cars) the roof file
    const g = S.geos[key], m = S.meshes && S.meshes[key];
    if (!g || !m) continue;
    const mp = m.parts.filter(p => p.indices.length); // the geo's parts, same order
    const isDoor = (p, i) => p.cat === 1 || /^big_door/.test(mp[i] ? mp[i].name : '');
    if (!g.parts.some(isDoor)) continue;
    const scissor = key === 'part:roof' || g.parts.some(p => /^big_door/.test(p.name));
    // each door part: its side (x) and its length along the car (y); parts that overlap along y belong to one door,
    // so a four/five-door car gets a front and a rear door per side
    const items = [], rest = [];
    g.parts.forEach((p, i) => {
      if (!isDoor(p, i)) { rest.push(p); return; }
      const I = mp[i].indices, P = m.positions, lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9]; let sx = 0;
      for (const v of I) { sx += P[v * 3]; for (let k = 0; k < 3; k++) { lo[k] = Math.min(lo[k], P[v * 3 + k]); hi[k] = Math.max(hi[k], P[v * 3 + k]); } }
      items.push({ p, side: sx >= 0 ? 1 : -1, lo, hi });
    });
    const groups = [];
    for (const it of items.sort((x, y) => x.lo[1] - y.lo[1])) {
      const len = it.hi[1] - it.lo[1];
      const gr = groups.find(q => q.side === it.side && Math.min(q.hi[1], it.hi[1]) - Math.max(q.lo[1], it.lo[1]) > 0.3 * Math.min(len, q.hi[1] - q.lo[1]));
      if (gr) { gr.parts.push(it.p); for (let k = 0; k < 3; k++) { gr.lo[k] = Math.min(gr.lo[k], it.lo[k]); gr.hi[k] = Math.max(gr.hi[k], it.hi[k]); } }
      else groups.push({ side: it.side, parts: [it.p], lo: it.lo.slice(), hi: it.hi.slice() });
    }
    const doors = [], [blo, bhi] = S.geos.body.bounds, blen = bhi[1] - blo[1];
    for (const sd of groups) {
      const side = sd.side, cy = (sd.lo[1] + sd.hi[1]) / 2, outer = Math.max(Math.abs(sd.lo[0]), Math.abs(sd.hi[0]));
      // a door sits on the side (outer edge near the body's width) and in the middle of the car; anything else
      // (hatch pieces, trims) stays with the body
      if (Math.abs(cy - (blo[1] + bhi[1]) / 2) > 0.3 * blen || outer < 0.6 * Math.max(-blo[0], bhi[0])) { rest.push(...sd.parts); continue; }
      const hinge = scissor ? [(sd.lo[0] + sd.hi[0]) / 2, sd.lo[1], (sd.lo[2] + sd.hi[2]) / 2] : [side > 0 ? sd.hi[0] : sd.lo[0], sd.lo[1], (sd.lo[2] + sd.hi[2]) / 2];
      doors.push({ side, scissor, hinge, view: Object.assign({}, g, { parts: sd.parts }), model: new Float32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]) });
    }
    S.doors[key] = { rest: Object.assign({}, g, { parts: rest }), doors };
  }
}
S.doorP = 0; S.wheelA = 0; S.lastT = 0;
function animFrame(t) {
  const dt = Math.min(0.1, Math.max(0, t - S.lastT)); S.lastT = t;
  // wheels turn (forward roll: the top of the tyre moves to -Y); a mirrored mount turns its own way
  if ($('vWheels').checked) S.wheelA += dt * 9;
  for (const o of S.wheelObjs || []) {
    const m = o.mount, sgn = (m[5] * m[10] - m[6] * m[9]) < 0 ? -1 : 1;
    m44(mul34(m, rotX(S.wheelA * sgn)), o.model);
  }
  // doors: ease towards open / closed in about a second (the game's dooropen takes 1.17 s)
  const want = $('vDoors').checked ? 1 : 0;
  S.doorP += Math.sign(want - S.doorP) * Math.min(Math.abs(want - S.doorP), dt / 1.1);
  const e = S.doorP * S.doorP * (3 - 2 * S.doorP);
  for (const k in S.doors || {}) for (const d of S.doors[k].doors) {
    const R = d.scissor ? rotX(e * 1.18) : rotZ(e * 1.13 * (d.side > 0 ? -1 : 1)); // 67.5 deg up (sparta's track) / 65 deg out
    m44(about(d.hinge, R), d.model);
  }
  fxFrame();
}
viewer.onFrame = animFrame;
$('vLook').onchange = e => { viewer.look = e.target.checked ? 1 : 0; localStorage.setItem('ws.look', viewer.look); };
if (localStorage.getItem('ws.look') === '1') { $('vLook').checked = true; viewer.look = 1; }
$('vLights').onchange = e => { viewer.lights = e.target.checked ? 1 : 0; recompose(); };
$('vFx').onchange = e => fxPause(!e.target.checked);

// Light pools on the ground when the lights are on: white in front of the headlights, red behind (preview only)
let POOL = null;
function lightPools() {
  if (!viewer.lights || !S.geos.body) return [];
  const [lo, hi] = S.geos.body.bounds, key = S.car;
  if (!POOL || POOL.key !== key) {
    if (POOL) POOL.geos.forEach(g => viewer.free(g));
    const pool = (rgb) => { const c = document.createElement('canvas'); c.width = c.height = 128; const g = c.getContext('2d');
      const gr = g.createRadialGradient(64, 64, 2, 64, 64, 64); gr.addColorStop(0, `rgba(${rgb},0.9)`); gr.addColorStop(0.5, `rgba(${rgb},0.35)`); gr.addColorStop(1, `rgba(${rgb},0)`);
      g.fillStyle = gr; g.fillRect(0, 0, 128, 128); return c; };
    const quad = (cx, cy, sx, sy) => viewer.upload({ positions: [cx - sx, cy - sy, 0.02, cx + sx, cy - sy, 0.02, cx + sx, cy + sy, 0.02, cx - sx, cy + sy, 0.02], uvs: [0, 0, 1, 0, 1, 1, 0, 1], normals: [], parts: [{ name: 'pool', group: 0, cat: 0, indices: [0, 1, 2, 0, 2, 3] }] });
    const w = (hi[0] - lo[0]) / 2;
    POOL = { key, geos: [quad(0, lo[1] - 3.2, w * 1.5, 3.4), quad(0, hi[1] + 0.9, w * 1.1, 1.0)], tex: [pool('255,236,200'), pool('255,40,30')] };
  }
  return POOL.geos.map((g, i) => ({ geo: g, tex: POOL.tex[i], kind: 'fx', alpha: i ? 0.55 : 0.7 }));
}

// ------------------------------------------------------------------ jobs
async function runJob(job, logEl, done) {
  logEl.textContent = '';
  for (;;) {
    const j = await api('/api/job?id=' + job.id);
    logEl.textContent = j.log; logEl.scrollTop = logEl.scrollHeight;
    if (j.done) { logEl.textContent += j.ok ? '\n✔ done' : '\n✖ failed (exit ' + j.code + ')'; if (done) await done(j); return j; }
    await new Promise(r => setTimeout(r, 700));
  }
}
function fillPkgLists() {
  for (const kind of ['decal', 'plate', 'glass', 'lamp', 'wheel', 'effect']) {
    const el = $(kind + 'PkgList'); if (!el) continue;
    const keep = new Set(qsa('input:checked', el).map(i => i.value));
    const rows = MINE.filter(m => m.kind === kind);
    el.innerHTML = rows.length ? rows.map(m => `<label class="check"><input type="checkbox" value="${m.name}" ${keep.has(m.name) ? 'checked' : ''}> ${m.name}</label>`).join('') : '<span class="muted small">Nothing made yet.</span>';
  }
}
const checked = kind => qsa('#' + kind + 'PkgList input:checked').map(i => i.value);

// drop zones
function dropZone(zone, input, onFiles) {
  const z = $(zone), inp = $(input);
  z.onclick = () => inp.click();
  inp.onchange = () => { if (inp.files.length) onFiles([...inp.files]); inp.value = ''; };
  z.ondragover = e => { e.preventDefault(); z.classList.add('over'); };
  z.ondragleave = () => z.classList.remove('over');
  z.ondrop = e => { e.preventDefault(); z.classList.remove('over'); if (e.dataTransfer.files.length) onFiles([...e.dataTransfer.files]); };
}

// ------------------------------------------------------------------ DECAL tab
let decalImage = null;
dropZone('decalDrop', 'decalFile', async files => {
  decalImage = await fileToDataURL(files[0]);
  $('decalThumb').src = decalImage; $('decalThumb').classList.remove('hidden');
  if (!$('decalName').value) $('decalName').value = files[0].name.replace(/\.[^.]+$/, '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 40) || 'my_decal';
});
$('decalScale').oninput = e => { $('decalScaleOut').textContent = e.target.value; };
$('decalPos').oninput = e => { $('decalPosOut').textContent = e.target.value; };
$('decalMake').onclick = async () => {
  if (!decalImage) { $('decalMsg').textContent = 'Choose a picture first.'; return; }
  $('decalMake').disabled = true; $('decalMsg').textContent = 'working…'; $('decalShots').innerHTML = '';
  const name = $('decalName').value.trim();
  try {
    const job = await api('/api/decal', { name, image: decalImage, options: {
      layout: $('decalLayout').value, scale: +$('decalScale').value, pos: +$('decalPos').value, mirror: $('decalMirror').checked,
      removeBg: $('decalRemoveBg').checked, recolor: $('decalRecolor').checked, frame: +$('decalFrame').value, cars: S.car || 'clio' } });
    const j = await runJob(job, $('decalLog'));
    if (j.ok) {
      $('decalMsg').innerHTML = '<span class="ok">Made. Shown on the car.</span>';
      await refreshMine();
      const m = MINE.find(x => x.kind === 'decal' && x.name === name);
      if (m) { S.decal = { img: await loadImg(m.url + '?t=' + Date.now()), custom: m.settings.custom, colors: m.settings.colors }; setColorInputs('dcol', 'decalColors', m.settings); recompose(); }
      const shots = ['layout_' + name + '.png', 'icon_' + name + '.png', ...['left', 'right', 'top', 'front34'].map(v => 'preview/' + (S.car || 'clio') + '_' + v + '.png')];
      $('decalShots').innerHTML = shots.map(s => `<a href="/decalout/${name}/${s}" target="_blank"><img src="/decalout/${name}/${s}?t=${Date.now()}" onerror="this.parentElement.remove()"></a>`).join('');
    } else $('decalMsg').innerHTML = '<span class="bad">Failed, see the log.</span>';
  } catch (e) { $('decalMsg').innerHTML = '<span class="bad">' + e.message + '</span>'; }
  $('decalMake').disabled = false;
};
$('decalPkg').onclick = async () => {
  const names = checked('decal'); if (!names.length) { $('decalLog').textContent = 'Tick the decals to package first.'; return; }
  await runJob(await api('/api/decal/package', { names }), $('decalLog'));
};

// ------------------------------------------------------------------ PLATE tab (128 x 64 editor)
const FONTS = ['Segoe UI', 'Arial Black', 'Impact', 'Consolas', 'Tahoma', 'Leelawadee UI', 'Bahnschrift', 'Georgia', 'Courier New'];
$('plFont').innerHTML = FONTS.map(f => `<option>${f}</option>`).join('');
$('plFont').value = 'Bahnschrift';
const PL = { img: null, ix: 0.5, iy: 0.5, tx: 0.5, ty: 0.55 };
function drawPlate(c) {
  const g = c.getContext('2d'), W = 128, H = 64;
  g.setTransform(c.width / W, 0, 0, c.height / H, 0, 0);
  g.clearRect(0, 0, W, H);
  const r = $('plRound').checked ? 7 : 0;
  g.save(); g.beginPath(); g.roundRect(0.5, 0.5, W - 1, H - 1, r); g.clip();
  const gr = g.createLinearGradient(0, 0, 0, H); gr.addColorStop(0, $('plBg').value); gr.addColorStop(1, $('plBg2').value);
  g.fillStyle = gr; g.fillRect(0, 0, W, H);
  if (PL.img) {
    const s = +$('plImgScale').value, iw = PL.img.naturalWidth, ih = PL.img.naturalHeight;
    let w, h;
    if ($('plImgFill').checked) { const k = Math.max(W / iw, H / ih) * s; w = iw * k; h = ih * k; }
    else { const k = Math.min(W / iw, H / ih) * s; w = iw * k; h = ih * k; }
    g.drawImage(PL.img, PL.ix * W - w / 2, PL.iy * H - h / 2, w, h);
  }
  const t1 = $('plText').value, t2 = $('plText2').value, size = +$('plSize').value;
  g.textAlign = 'center'; g.textBaseline = 'middle'; g.lineJoin = 'round';
  const text = (t, y, sz) => {
    g.font = `bold ${sz}px "${$('plFont').value}"`;
    const ow = +$('plOutlineW').value;
    if (ow > 0) { g.strokeStyle = $('plOutline').value; g.lineWidth = ow; g.strokeText(t, PL.tx * W, y, W - 6); }
    g.fillStyle = $('plColor').value; g.fillText(t, PL.tx * W, y, W - 6);
  };
  if (t1) text(t1, PL.ty * H - (t2 ? 5 : 0), size);
  if (t2) text(t2, PL.ty * H + size / 2 + 2, Math.max(6, Math.round(size * 0.36)));
  g.restore();
  const bw = +$('plBorderW').value;
  if (bw > 0) { g.strokeStyle = $('plBorder').value; g.lineWidth = bw; g.beginPath(); g.roundRect(bw / 2 + 0.5, bw / 2 + 0.5, W - bw - 1, H - bw - 1, Math.max(0, r - bw / 2)); g.stroke(); }
  if ($('plBolts').checked) { g.fillStyle = 'rgba(40,44,52,.75)'; for (const x of [14, W - 14]) { g.beginPath(); g.arc(x, 7, 2, 0, 7); g.fill(); } }
}
const plateCanvas = $('plateCanvas');
plateCanvas.width = 512; plateCanvas.height = 256;
const plateTex = document.createElement('canvas'); plateTex.width = 128; plateTex.height = 64;
const redrawPlate = () => {
  drawPlate(plateCanvas); drawPlate(plateTex);
  if (document.querySelector('#tab-plate.on')) { S.plate = plateTex; recompose(); }
};
qsa('#tab-plate input, #tab-plate select').forEach(e => { if (!e.closest('.checklist') && e.type !== 'file') e.addEventListener('input', redrawPlate); });
dropZone('plateDrop', 'plateFile', async files => { PL.img = await loadImg(await fileToDataURL(files[0])); redrawPlate(); });
$('plImgClear').onclick = () => { PL.img = null; redrawPlate(); };
dragOn(plateCanvas, (fx, fy, start) => {
  // grab whichever is nearer: text or picture
  if (start) PL.drag = PL.img && Math.hypot(fx - PL.ix, fy - PL.iy) < Math.hypot(fx - PL.tx, fy - PL.ty) ? 'img' : 'text';
  if (PL.drag === 'img') { PL.ix = fx; PL.iy = fy; } else { PL.tx = fx; PL.ty = fy; }
  redrawPlate();
});
function dragOn(c, fn) {
  let down = false;
  const pos = e => { const r = c.getBoundingClientRect(); return [(e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height]; };
  c.addEventListener('pointerdown', e => { down = true; c.setPointerCapture(e.pointerId); fn(...pos(e), true); });
  c.addEventListener('pointermove', e => { if (down) fn(...pos(e), false); });
  c.addEventListener('pointerup', () => { down = false; });
}
function iconFrom(src, w, h) {
  const c = document.createElement('canvas'); c.width = 64; c.height = 64;
  const g = c.getContext('2d'); g.imageSmoothingQuality = 'high';
  const k = Math.min(60 / w, 60 / h); g.drawImage(src, 32 - w * k / 2, 32 - h * k / 2, w * k, h * k);
  return c.toDataURL('image/png');
}
$('plSave').onclick = async () => {
  const name = $('plName').value.trim();
  drawPlate(plateTex);
  try {
    const job = await api('/api/item', { kind: 'plate', name, texture: plateTex.toDataURL('image/png'), icon: iconFrom(plateTex, 128, 64) });
    const j = await runJob(job, $('plateLog'));
    $('plMsg').innerHTML = j.ok ? '<span class="ok">Saved.</span>' : '<span class="bad">Failed, see the log.</span>';
    await refreshMine();
  } catch (e) { $('plMsg').innerHTML = '<span class="bad">' + e.message + '</span>'; }
};
$('platePkg').onclick = async () => {
  const names = checked('plate'); if (!names.length) { $('plateLog').textContent = 'Tick the plates to package first.'; return; }
  await runJob(await api('/api/item/package', { kind: 'plate', names }), $('plateLog'));
};

// ------------------------------------------------------------------ WINDSHIELD tab (64 x 64)
const GL = { img: null };
const glassTex = $('glassCanvas');
function glMode() { return document.querySelector('input[name=glMode]:checked').value; }
function drawGlass() {
  const g = glassTex.getContext('2d'), N = 64, mode = glMode();
  g.clearRect(0, 0, N, N);
  const im = g.createImageData(N, N);
  // picture -> its own colours; tint1 -> R = colour 1; tint3 -> picture's R/G/B choose colours 1-3
  let pic = null;
  if (GL.img) {
    const c = document.createElement('canvas'); c.width = c.height = N; const cg = c.getContext('2d');
    const s = +$('glImgScale').value, w = N * s, h = N * s * GL.img.naturalHeight / GL.img.naturalWidth;
    cg.drawImage(GL.img, (N - w) / 2, (N - h) / 2, w, h); pic = cg.getImageData(0, 0, N, N).data;
  }
  const top = +$('glTop').value, bot = +$('glBottom').value, str = +$('glImgAlpha').value;
  const base = mode === 'picture' ? hex2rgb($('glc0').value) : mode === 'tint1' ? [255, 0, 0] : [255, 0, 0];
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    const o = (y * N + x) * 4, a = top + (bot - top) * (y / (N - 1));
    let r = base[0], gg = base[1], b = base[2], al = a;
    if (pic && mode !== 'tint1') {
      const pa = pic[o + 3] / 255 * str;
      r += (pic[o] - r) * pa; gg += (pic[o + 1] - gg) * pa; b += (pic[o + 2] - b) * pa;
      al = Math.min(1, a + pa * (1 - a));
    }
    im.data[o] = r; im.data[o + 1] = gg; im.data[o + 2] = b; im.data[o + 3] = al * 255;
  }
  g.putImageData(im, 0, 0);
  if (document.querySelector('#tab-glass.on')) {
    const custom = mode !== 'picture';
    S.glass = { img: glassTex, custom, colors: custom ? [0, 1, 2].map(i => hex2rgb($('glc' + i).value)) : [] };
    recompose();
  }
}
qsa('#tab-glass input').forEach(e => { if (!e.closest('.checklist') && e.type !== 'file') e.addEventListener('input', drawGlass); });
dropZone('glassDrop', 'glassFile', async files => { GL.img = await loadImg(await fileToDataURL(files[0])); drawGlass(); });
$('glImgClear').onclick = () => { GL.img = null; drawGlass(); };
$('glSave').onclick = async () => {
  drawGlass();
  const mode = glMode(), custom = mode !== 'picture';
  const settings = { custom, colors: custom ? [0, 1, 2].slice(0, mode === 'tint1' ? 1 : 3).map(i => hex2rgb($('glc' + i).value)) : [] };
  try {
    const job = await api('/api/item', { kind: 'glass', name: $('glName').value.trim(), texture: glassTex.toDataURL('image/png'), icon: iconFrom(glassTex, 64, 64), settings });
    const j = await runJob(job, $('glassLog'));
    $('glMsg').innerHTML = j.ok ? '<span class="ok">Saved.</span>' : '<span class="bad">Failed, see the log.</span>';
    await refreshMine();
  } catch (e) { $('glMsg').innerHTML = '<span class="bad">' + e.message + '</span>'; }
};
$('glassPkg').onclick = async () => {
  const names = checked('glass'); if (!names.length) { $('glassLog').textContent = 'Tick the windshields to package first.'; return; }
  await runJob(await api('/api/item/package', { kind: 'glass', names }), $('glassLog'));
};

// ------------------------------------------------------------------ ROOF ACCESSORY tab
const RF = { obj: null, tex: null, mesh: null, preview: null };
function parseObj(text) {
  const v = [], vt = [], vn = [], P = [], U = [], N = [], parts = []; const map = new Map();
  let cur = null;
  const newPart = n => { cur = { name: n, indices: [], group: 0, cat: 0 }; parts.push(cur); };
  for (const line of text.split('\n')) {
    const a = line.trim().split(/\s+/);
    if (a[0] === 'v') v.push([+a[1], +a[2], +a[3]]);
    else if (a[0] === 'vt') vt.push([+a[1], +a[2]]);
    else if (a[0] === 'vn') vn.push([+a[1], +a[2], +a[3]]);
    else if (a[0] === 'o' || a[0] === 'g') newPart(a[1] || 'part');
    else if (a[0] === 'f') {
      if (!cur) newPart('part');
      const idx = a.slice(1).map(s => {
        if (map.has(s)) return map.get(s);
        const [pi, ti, ni] = s.split('/').map(x => x ? parseInt(x, 10) : 0);
        const p = v[pi < 0 ? v.length + pi : pi - 1], t = ti ? vt[ti < 0 ? vt.length + ti : ti - 1] : [0, 0], n = ni ? vn[ni < 0 ? vn.length + ni : ni - 1] : [0, 0, 0];
        P.push(...p); U.push(t[0], 1 - t[1]); N.push(...n);
        map.set(s, P.length / 3 - 1); return P.length / 3 - 1;
      });
      for (let i = 1; i + 1 < idx.length; i++) cur.indices.push(idx[0], idx[i], idx[i + 1]);
    }
  }
  return { positions: P, uvs: U, normals: N, parts: parts.filter(p => p.indices.length) };
}
function roofTransform() {
  const s = +$('rfScale').value, r = +$('rfRot').value * Math.PI / 180, c = Math.cos(r) * s, sn = Math.sin(r) * s;
  return [c, -sn, 0, 0, sn, c, 0, +$('rfY').value, 0, 0, s, +$('rfZ').value];
}
function mul34(a, b) { // a * b, both 3x4 row-major affine
  const o = new Array(12);
  for (let r = 0; r < 3; r++) { for (let c = 0; c < 3; c++) o[r * 4 + c] = a[r * 4] * b[c] + a[r * 4 + 1] * b[4 + c] + a[r * 4 + 2] * b[8 + c]; o[r * 4 + 3] = a[r * 4] * b[3] + a[r * 4 + 1] * b[7] + a[r * 4 + 2] * b[11] + a[r * 4 + 3]; }
  return o;
}
// Our model in the composite: UVs squeezed into the lamp slot (0, 0.375, 0.125, 0.5), texture 64 x 64.
function lampMeshForPreview() {
  if (!RF.mesh) return null;
  const m = JSON.parse(JSON.stringify(RF.mesh));
  for (let i = 0; i < m.uvs.length; i += 2) { m.uvs[i] = 0.125 * Math.min(1, Math.max(0, m.uvs[i])); m.uvs[i + 1] = 0.375 + 0.125 * Math.min(1, Math.max(0, m.uvs[i + 1])); }
  return m;
}
RF.preview = null;
const updateRoof = debounce(() => {
  $('rfScaleOut').textContent = $('rfScale').value; $('rfRotOut').textContent = $('rfRot').value + '°';
  if (!RF.mesh) { RF.preview = null; updateLamp(); return; }
  const tm = mul34(roofMount(), roofTransform());
  RF.preview = () => ({ geo: viewer.upload(lampMeshForPreview(), tm), tex: RF.tex64, glow: !!$('rfEffect').value });
  S.lampPick = null; $('lampSource').value = 'none';
  updateLamp();
}, 60);
qsa('#tab-roof input[type=range], #rfEffect').forEach(e => e.addEventListener('input', updateRoof));
dropZone('roofDrop', 'roofFile', async files => {
  for (const f of files) {
    if (/\.obj$/i.test(f.name)) { RF.obj = await fileToText(f); RF.mesh = parseObj(RF.obj); RF.objName = f.name; }
    else { RF.tex = await loadImg(await fileToDataURL(f)); }
  }
  if (!RF.tex) { const c = document.createElement('canvas'); c.width = c.height = 8; const g = c.getContext('2d'); g.fillStyle = '#c8c8c8'; g.fillRect(0, 0, 8, 8); RF.tex = c; }
  const c = document.createElement('canvas'); c.width = c.height = 64; const g = c.getContext('2d'); g.imageSmoothingQuality = 'high'; g.drawImage(RF.tex, 0, 0, 64, 64); RF.tex64 = c;
  if (RF.mesh) {
    const tris = RF.mesh.parts.reduce((s, p) => s + p.indices.length / 3, 0), vc = RF.mesh.positions.length / 3;
    let lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9];
    for (let i = 0; i < RF.mesh.positions.length; i += 3) for (let k = 0; k < 3; k++) { lo[k] = Math.min(lo[k], RF.mesh.positions[i + k]); hi[k] = Math.max(hi[k], RF.mesh.positions[i + k]); }
    RF.bounds = [lo, hi];
    $('roofInfo').innerHTML = `${RF.objName}: ${vc} vertices, ${tris} triangles · size ${(hi[0] - lo[0]).toFixed(2)} × ${(hi[1] - lo[1]).toFixed(2)} × ${(hi[2] - lo[2]).toFixed(2)} m` +
      (vc > 65000 ? ' <span class="bad">too many vertices (max 65 000)</span>' : tris > 3000 ? ' <span class="bad">heavy: game accessories use 200–2 000 triangles</span>' : '');
    if (!$('rfName').value) $('rfName').value = RF.objName.replace(/\.obj$/i, '').toLowerCase().replace(/[^a-z0-9]+/g, '_').slice(0, 40);
    autoSit();
  }
});
function autoSit() {
  if (!RF.bounds) return;
  const [lo, hi] = RF.bounds, s = +$('rfScale').value;
  $('rfZ').value = (-lo[2] * s).toFixed(2); $('rfY').value = (-(lo[1] + hi[1]) / 2 * s).toFixed(2);
  updateRoof();
}
$('rfAuto').onclick = autoSit;
$('rfSave').onclick = async () => {
  if (!RF.obj) { $('rfMsg').textContent = 'Drop an OBJ first.'; return; }
  try {
    const job = await api('/api/lamp', { name: $('rfName').value.trim(), obj: RF.obj, texture: RF.tex64.toDataURL('image/png'), icon: iconFrom(RF.tex64, 64, 64),
      effect: $('rfEffect').value, transform: roofTransform() });
    const j = await runJob(job, $('roofLog'));
    $('rfMsg').innerHTML = j.ok ? '<span class="ok">Saved.</span>' : '<span class="bad">Failed, see the log.</span>';
    await refreshMine();
  } catch (e) { $('rfMsg').innerHTML = '<span class="bad">' + e.message + '</span>'; }
};
$('lampPkg').onclick = async () => {
  const names = checked('lamp'); if (!names.length) { $('roofLog').textContent = 'Tick the accessories to package first.'; return; }
  await runJob(await api('/api/item/package', { kind: 'lamp', names }), $('roofLog'));
};
async function initEffects() {
  const lamps = await api('/api/catalog?kind=lamp');
  const fx = [...new Map(lamps.filter(l => l.effect).map(l => [l.effect, l.name])).entries()];
  $('rfEffect').innerHTML = '<option value="">No glow</option>' + fx.map(([e, n]) => `<option value="${e}">${e.replace('EffectType_Lamp_', '')} (as on “${n}”)</option>`).join('');
}

// ------------------------------------------------------------------ WHEELS tab
// Wheel space (game meshes): axle = X, rim face looks to -X, radius ~0.35 m with the tyre. Texture 128 x 128 in the
// car texture's wheel slot (0, 0.75, 0.25, 1).
const WH = { active: false, base: null, baseMesh: null, baseImg: null, logo: null, lx: 0.5, ly: 0.5, obj: null, mesh: null, objTex: null, preview: null };
const wheelCanvas = $('wheelCanvas');
const whMode = () => document.querySelector('input[name=whMode]:checked').value;
let WHEELS = [];
async function fillWheelBase() {
  if (!WHEELS.length) { status('loading game wheel list…'); WHEELS = await api('/api/catalog?kind=wheel'); status('ready'); }
  const q = $('whSearch').value.toLowerCase();
  $('whBase').innerHTML = WHEELS.filter(r => !q || r.name.toLowerCase().includes(q) || String(r.id) === q).slice(0, 800)
    .map(r => `<option value='${JSON.stringify(r)}'>${r.id} · ${r.name}${r.mesh !== r.name ? ' (shape ' + r.mesh + ')' : ''}</option>`).join('');
}
$('whSearch').oninput = debounce(fillWheelBase, 150);
$('whBase').onchange = async () => {
  const r = JSON.parse($('whBase').value); busy(true);
  try {
    const d = await api('/api/lampmesh?kind=wheel&mesh=' + enc(r.mesh) + '&tex=' + enc(r.tex));
    WH.base = r; WH.baseMesh = await api(d.mesh); WH.baseImg = await loadImg(d.png);
    $('whBaseInfo').textContent = `Shape ${r.mesh} · texture ${r.tex}. The new wheel keeps this shape.`;
    if (!$('whName').value) $('whName').value = 'my_' + r.name.replace(/[^a-z0-9_]/g, '_').slice(0, 30);
    drawWheel();
  } catch (e) { status('error: ' + e.message); }
  busy(false);
};
qsa('input[name=whMode]').forEach(r => r.onchange = () => {
  $('whRepaintBox').classList.toggle('hidden', whMode() !== 'repaint'); $('whObjBox').classList.toggle('hidden', whMode() !== 'obj'); drawWheel();
});
function hueRotate(r, g, b, deg) {
  const a = deg * Math.PI / 180, c = Math.cos(a), s = Math.sin(a);
  return [r * (0.213 + c * 0.787 - s * 0.213) + g * (0.715 - c * 0.715 - s * 0.715) + b * (0.072 - c * 0.072 + s * 0.928),
    r * (0.213 - c * 0.213 + s * 0.143) + g * (0.715 + c * 0.285 + s * 0.140) + b * (0.072 - c * 0.072 - s * 0.283),
    r * (0.213 - c * 0.213 - s * 0.787) + g * (0.715 - c * 0.715 + s * 0.715) + b * (0.072 + c * 0.928 + s * 0.072)];
}
function drawWheel() {
  const N = 128, g = wheelCanvas.getContext('2d');
  g.globalCompositeOperation = 'source-over'; g.clearRect(0, 0, N, N);
  const src = whMode() === 'obj' ? WH.objTex : WH.baseImg;
  if (src) g.drawImage(src, 0, 0, N, N); else { g.fillStyle = '#a0a6ae'; g.fillRect(0, 0, N, N); }
  const im = g.getImageData(0, 0, N, N), d = im.data;
  const tint = hex2rgb($('whTint').value), amt = +$('whTintAmt').value, hue = +$('whHue').value, br = +$('whBright').value;
  for (let i = 0; i < d.length; i += 4) {
    let r = d[i], gg = d[i + 1], b = d[i + 2];
    if (hue) [r, gg, b] = hueRotate(r, gg, b, hue);
    if (amt) { const l = Math.min(1.6, (0.299 * r + 0.587 * gg + 0.114 * b) / 160); r += (tint[0] * l - r) * amt; gg += (tint[1] * l - gg) * amt; b += (tint[2] * l - b) * amt; }
    d[i] = r * br; d[i + 1] = gg * br; d[i + 2] = b * br;
  }
  g.putImageData(im, 0, 0);
  if (WH.logo) {
    const s = +$('whLogoScale').value * N, iw = WH.logo.naturalWidth, ih = WH.logo.naturalHeight, k = s / Math.max(iw, ih);
    g.save(); g.globalCompositeOperation = 'source-atop'; // keep the base's alpha (the game uses it as shading)
    if ($('whLogoRound').checked) { g.beginPath(); g.arc(WH.lx * N, WH.ly * N, s / 2, 0, 7); g.clip(); }
    g.drawImage(WH.logo, WH.lx * N - iw * k / 2, WH.ly * N - ih * k / 2, iw * k, ih * k); g.restore();
  }
  updateWheelPreview();
}
// OBJ rim -> wheel space: axle onto X, optional flip, size, centred on the hub.
function wheelTransform() {
  const A = { x: [1, 0, 0, 0, 1, 0, 0, 0, 1], y: [0, 1, 0, -1, 0, 0, 0, 0, 1], z: [0, 0, 1, 0, 1, 0, -1, 0, 0] }[$('whAxle').value];
  const f = $('whFlip').checked ? -1 : 1, s = +$('whScale').value;
  const R = [A[0] * f * s, A[1] * f * s, A[2] * f * s, A[3] * f * s, A[4] * f * s, A[5] * f * s, A[6] * s, A[7] * s, A[8] * s];
  const c = WH.bounds ? [0, 1, 2].map(k => (WH.bounds[0][k] + WH.bounds[1][k]) / 2) : [0, 0, 0];
  return [R[0], R[1], R[2], -(R[0] * c[0] + R[1] * c[1] + R[2] * c[2]), R[3], R[4], R[5], -(R[3] * c[0] + R[4] * c[1] + R[5] * c[2]), R[6], R[7], R[8], -(R[6] * c[0] + R[7] * c[1] + R[8] * c[2])];
}
function wheelFit() {
  if (!WH.mesh) return;
  const ax = { x: 0, y: 1, z: 2 }[$('whAxle').value], c = [0, 1, 2].map(k => (WH.bounds[0][k] + WH.bounds[1][k]) / 2);
  let r = 0; const P = WH.mesh.positions;
  for (let i = 0; i < P.length; i += 3) { let q = 0; for (let k = 0; k < 3; k++) if (k !== ax) q += (P[i + k] - c[k]) ** 2; r = Math.max(r, q); }
  $('whScale').value = (0.35 / Math.sqrt(r || 1)).toFixed(2); updateWheelPreview();
}
const updateWheelPreview = debounce(() => {
  $('whScaleOut').textContent = $('whScale').value;
  const obj = whMode() === 'obj';
  if (obj ? !WH.mesh : !WH.baseMesh) return;
  let mesh = WH.baseMesh, tm = null;
  if (obj) {
    mesh = JSON.parse(JSON.stringify(WH.mesh));
    for (let i = 0; i < mesh.uvs.length; i += 2) { mesh.uvs[i] = 0.25 * Math.min(1, Math.max(0, mesh.uvs[i])); mesh.uvs[i + 1] = 0.75 + 0.25 * Math.min(1, Math.max(0, mesh.uvs[i + 1])); }
    tm = wheelTransform();
  }
  WH.preview = () => ({ mesh, tm, tex: wheelCanvas });
  WH.active = true; $('wheelSource').value = 'none'; S.wheelPick = null;
  updateWheels();
}, 80);
qsa('#tab-wheel input[type=range], #tab-wheel input[type=color], #whLogoRound').forEach(e => e.addEventListener('input', drawWheel));
['whAxle', 'whFlip'].forEach(id => $(id).addEventListener('change', updateWheelPreview));
$('whFit').onclick = wheelFit;
dropZone('whLogoDrop', 'whLogoFile', async files => { WH.logo = await loadImg(await fileToDataURL(files[0])); drawWheel(); });
$('whLogoClear').onclick = () => { WH.logo = null; drawWheel(); };
dragOn(wheelCanvas, (fx, fy) => { if (WH.logo) { WH.lx = fx; WH.ly = fy; drawWheel(); } });
dropZone('wheelDrop', 'wheelFile', async files => {
  for (const f of files) {
    if (/\.obj$/i.test(f.name)) { WH.obj = await fileToText(f); WH.mesh = parseObj(WH.obj); WH.objName = f.name; }
    else WH.objTex = await loadImg(await fileToDataURL(f));
  }
  if (WH.mesh) {
    const P = WH.mesh.positions, lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9];
    for (let i = 0; i < P.length; i += 3) for (let k = 0; k < 3; k++) { lo[k] = Math.min(lo[k], P[i + k]); hi[k] = Math.max(hi[k], P[i + k]); }
    WH.bounds = [lo, hi];
    const vc = P.length / 3, tris = WH.mesh.parts.reduce((s, p) => s + p.indices.length / 3, 0);
    $('wheelInfo').innerHTML = `${WH.objName}: ${vc} vertices, ${tris} triangles · size ${(hi[0] - lo[0]).toFixed(2)} × ${(hi[1] - lo[1]).toFixed(2)} × ${(hi[2] - lo[2]).toFixed(2)}` +
      (vc > 65000 ? ' <span class="bad">too many vertices (max 65 000)</span>' : tris > 4000 ? ' <span class="bad">heavy: game rims use 100–600 triangles</span>' : '');
    // the thinnest side is the axle
    const ext = [0, 1, 2].map(k => hi[k] - lo[k]); $('whAxle').value = 'xyz'[ext.indexOf(Math.min(...ext))];
    if (!$('whName').value) $('whName').value = WH.objName.replace(/\.obj$/i, '').toLowerCase().replace(/[^a-z0-9]+/g, '_').slice(0, 36);
    wheelFit();
  }
  drawWheel();
});
$('whSave').onclick = async () => {
  const mode = whMode();
  if (mode === 'repaint' && !WH.base) { $('whMsg').textContent = 'Pick the game rim to repaint first.'; return; }
  if (mode === 'obj' && !WH.obj) { $('whMsg').textContent = 'Drop an OBJ first.'; return; }
  drawWheel();
  try {
    const job = await api('/api/wheel', { name: $('whName').value.trim(), mode, baseMesh: WH.base ? WH.base.mesh : '', obj: mode === 'obj' ? WH.obj : '',
      texture: wheelCanvas.toDataURL('image/png'), icon: iconFrom(wheelCanvas, 128, 128), transform: mode === 'obj' ? wheelTransform() : null });
    const j = await runJob(job, $('wheelLog'));
    $('whMsg').innerHTML = j.ok ? '<span class="ok">Saved.</span>' : '<span class="bad">Failed, see the log.</span>';
    await refreshMine();
  } catch (e) { $('whMsg').innerHTML = '<span class="bad">' + e.message + '</span>'; }
};
$('wheelPkg').onclick = async () => {
  const names = checked('wheel'); if (!names.length) { $('wheelLog').textContent = 'Tick the wheels to package first.'; return; }
  await runJob(await api('/api/item/package', { kind: 'wheel', names }), $('wheelLog'));
};

// ------------------------------------------------------------------ SET EFFECTS (player for the 3D Preview and the Set effect tab)
// A set effect = effectGroup items; each item plays relement files (one, or a seq: fade-in -> loop -> fade-out) at the car's
// origin, its lamp mount or a wheel mount. Node matrices come pre-sampled at 30 fps from backend\export_effect.ps1.
let FXCAT = null;
async function fxCatalog() { if (!FXCAT) FXCAT = await api('/api/catalog?kind=effect'); return FXCAT; }
const FX = { row: null, mine: null, items: [], objs: [], ending: false, tex: new Map(), glow: 1, speed: 1 };
const fxLabel = r => r.name.replace(/^EffectType_/, '') + (r.legend ? ' · legend' : '');
function fxClear() {
  for (const o of FX.objs) viewer.free(o.geo);
  FX.objs = []; FX.items = []; FX.row = null; FX.mine = null;
}
async function fxLoadFile(file, mine) {
  const d = await api('/api/effectfile?file=' + enc(file) + (mine ? '&mine=' + enc(mine) : ''));
  const j = await api(d.url);
  for (const n of j.nodes) {
    n.img = n.tex ? await loadImg(d.tex + n.tex) : null;
    n.obj = { geo: viewer.upload({ positions: n.positions, uvs: n.uvs, normals: [], parts: [{ name: n.name, group: 0, cat: 0, indices: n.indices }] }), kind: 'fx', hidden: true, model: new Float32Array(16) };
    FX.objs.push(n.obj);
  }
  return j;
}
// row: catalog effect; mine: {name, files: {templateFile: ourFile}} for one of ours
async function fxShow(row, mine) {
  fxClear();
  FX.row = row; FX.mine = mine || null;
  if (!row) { recompose(); return; }
  busy(true);
  try {
    const cat = await fxCatalog(), map = (mine && mine.files) || {};
    for (const it of row.items) {
      const chain = (it.seq.length ? it.seq : [{ file: it.file, loop: it.loop, next: false }]).map(s => ({ ...s }));
      for (const s of chain) {
        s.kind = map[s.file] ? 'scene' : cat.files[s.file.toLowerCase()] || 'missing';
        s.data = s.kind === 'scene' ? await fxLoadFile(map[s.file] || s.file, map[s.file] ? mine.name : null).catch(e => { console.warn(e); return null; }) : null;
      }
      FX.items.push({ it, chain, idx: 0, t0: fxNow(), wait: 0 });
    }
  } catch (e) { status('error: ' + e.message); }
  busy(false);
  fxRestart(); recompose();
}
function fxRestart() { FX.ending = false; const now = fxNow(); for (const s of FX.items) { s.idx = 0; s.t0 = now; s.wait = 0; } }
function fxEnd() { // jump past the looping part to the fade-out, as the game does when the set item comes off
  FX.ending = true; const now = fxNow();
  for (const s of FX.items) {
    const li = s.chain.findIndex(c => c.loop);
    if (li >= 0 && s.idx <= li) { s.idx = li + 1; s.t0 = now; }
  }
}
function fxAttach(it) {
  let base = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0];
  if (it.attach === 'kAttatchLamp') base = roofMount();
  else { const m = /^kAttatchWheel(\d)/.exec(it.attach || ''); if (m) base = wheelMounts()[+m[1]] || base; }
  const o = it.offset || [0, 0, 0];
  return mul34(base, [1, 0, 0, o[0], 0, 1, 0, o[1], 0, 0, 1, o[2]]);
}
function fxFrame() {
  if (!FX.items.length) return;
  const now = fxNow(), repeat = $('fxRepeat') ? $('fxRepeat').checked : true;
  for (const o of FX.objs) o.hidden = true;
  const vm = viewer.viewM;
  for (const s of FX.items) {
    if (s.wait) { if (now < s.wait) continue; s.wait = 0; s.idx = 0; s.t0 = now; FX.ending = false; }
    let c = s.chain[s.idx];
    if (!c) { if (repeat) s.wait = now + 700; continue; }
    const len = c.data ? Math.max(1, c.data.length) : 1000;
    let el = (now - s.t0) * FX.speed;
    if (c.loop && !FX.ending) el %= len;
    else if (el > len) {
      s.idx++; s.t0 = now; c = s.chain[s.idx];
      if (!c) { if (repeat) s.wait = now + 700; continue; }
      el = 0;
    }
    if (!c.data) continue;
    const d = c.data, f = Math.min(d.frames - 1, Math.floor(el / d.step)), A = fxAttach(s.it);
    for (const n of d.nodes) {
      if (!n.vis[f]) continue;
      const W = mul34(A, n.m.slice(f * 12, f * 12 + 12));
      if (n.billboard && vm) { // face the camera, keep the node's scale
        const sx = Math.hypot(W[0], W[4], W[8]), sy = Math.hypot(W[1], W[5], W[9]), sz = Math.hypot(W[2], W[6], W[10]);
        W[0] = vm[0] * sx; W[4] = vm[4] * sx; W[8] = vm[8] * sx; W[1] = vm[1] * sy; W[5] = vm[5] * sy; W[9] = vm[9] * sy; W[2] = vm[2] * sz; W[6] = vm[6] * sz; W[10] = vm[10] * sz;
      }
      const M = n.obj.model;
      M[0] = W[0]; M[1] = W[4]; M[2] = W[8]; M[3] = 0; M[4] = W[1]; M[5] = W[5]; M[6] = W[9]; M[7] = 0;
      M[8] = W[2]; M[9] = W[6]; M[10] = W[10]; M[11] = 0; M[12] = W[3]; M[13] = W[7]; M[14] = W[11]; M[15] = 1;
      n.obj.tex = FX.tex.get(n.texName) || n.img; n.obj.alpha = FX.glow; n.obj.hidden = !n.obj.tex;
    }
  }
}
// effect clock: pausing (the toolbar's Effects box) freezes every effect and the lamp glow
FX.off = 0; FX.pausedAt = 0;
function fxNow() { return (FX.pausedAt || performance.now()) - FX.off; }
function fxPause(on) {
  if (on && !FX.pausedAt) FX.pausedAt = performance.now();
  if (!on && FX.pausedAt) { FX.off += performance.now() - FX.pausedAt; FX.pausedAt = 0; }
  viewer.freezeGlow = on;
}
function extraObjects() { return FX.objs; }
picker('effect', async (r, mode) => {
  if (!r) { await fxShow(null); return; }
  if (mode === 'game') await fxShow(r);
  else { const cat = await fxCatalog(); await fxShow(cat.effects.find(e => e.name === r.template), { name: r.name, files: r.files }); }
});

// ------------------------------------------------------------------ SET EFFECT tab: list, player controls, maker
const FXM = { rows: [] }; // texture rows of the maker
async function fillFxList() {
  const cat = await fxCatalog(), q = $('fxSearch').value.toLowerCase();
  $('fxList').innerHTML = cat.effects.filter(r => !q || (r.name + r.option).toLowerCase().includes(q)).map(r => {
    const kinds = new Set(r.items.flatMap(it => (it.seq.length ? it.seq.map(s => s.file) : [it.file]).map(f => cat.files[f.toLowerCase()])));
    return `<option value="${r.name}">${fxLabel(r)}${kinds.has('scene') ? '' : ' · particles (no preview)'}</option>`;
  }).join('');
}
$('fxSearch').oninput = debounce(fillFxList, 150);
$('fxList').onchange = async () => {
  const cat = await fxCatalog(), r = cat.effects.find(e => e.name === $('fxList').value);
  if (!r) return;
  FX.tex.clear();
  await fxShow(r);
  const att = [...new Set(r.items.map(it => (it.attach || 'car').replace('kAttatch', '').replace(/Wheel\d/, 'wheels').toLowerCase()))];
  const files = [...new Set(FX.items.flatMap(s => s.chain.map(c => c.file + (c.kind === 'scene' ? '' : ' (' + c.kind + ')'))))];
  $('fxInfo').innerHTML = `Set-item option <code>${r.option}</code> · ${r.items.length} part${r.items.length > 1 ? 's' : ''} at the ${att.join(', ')}<br>Files: ${files.join(', ')}`;
  if (!$('fxName').value) $('fxName').value = 'my_' + r.name.replace(/^EffectType_(SetItem_)?/, '').toLowerCase().replace(/[^a-z0-9]+/g, '_').slice(0, 24);
  fillFxTextures();
};
$('fxPlay').onclick = fxRestart;
$('fxEnd').onclick = fxEnd;
$('fxSpeed').oninput = e => { FX.speed = +e.target.value; $('fxSpeedOut').textContent = FX.speed + '×'; };
$('fxGlow').oninput = e => { FX.glow = +e.target.value; };
function fillFxTextures() {
  const seen = new Map();
  for (const s of FX.items) for (const c of s.chain) if (c.data) for (const n of c.data.nodes) if (n.texName && n.img && !seen.has(n.texName)) seen.set(n.texName, n.img);
  FXM.rows = [...seen].map(([name, img]) => ({ name, img, mode: 'keep', hue: 0, tint: '#ffffff', amt: 0, pic: null, canvas: null }));
  $('fxTexList').innerHTML = FXM.rows.length ? FXM.rows.map((r, i) => `<div class="fxtex" data-i="${i}"><canvas width="${r.img.naturalWidth}" height="${r.img.naturalHeight}"></canvas>
    <div><b class="small">${r.name}</b> <span class="muted small">${r.img.naturalWidth}×${r.img.naturalHeight}</span>
    <div class="ctl"><select class="m"><option value="keep">Keep</option><option value="recolor">Recolour</option><option value="picture">My picture</option></select>
    <label>Hue <input type="range" class="h" min="-180" max="180" step="5" value="0"></label>
    <label>Tint <input type="color" class="t" value="#ffffff"><input type="range" class="a" min="0" max="1" step="0.05" value="0"></label>
    <span class="drop small">Drop picture<input type="file" accept="image/*" hidden></span></div></div></div>`).join('')
    : '<span class="muted small">This effect has no textures that can be previewed (particle effects can\'t be read yet).</span>';
  qsa('#fxTexList .fxtex').forEach(el => {
    const r = FXM.rows[+el.dataset.i]; r.canvas = el.querySelector('canvas');
    const upd = () => {
      r.mode = el.querySelector('.m').value; r.hue = +el.querySelector('.h').value; r.tint = el.querySelector('.t').value; r.amt = +el.querySelector('.a').value;
      if (r.mode === 'keep' && (r.hue || r.amt)) { r.mode = 'recolor'; el.querySelector('.m').value = 'recolor'; }
      drawFxTex(r);
    };
    el.querySelectorAll('select, input[type=range], input[type=color]').forEach(c => c.addEventListener('input', upd));
    const dz = el.querySelector('.drop'), inp = dz.querySelector('input');
    const take = async f => { r.pic = await loadImg(await fileToDataURL(f)); el.querySelector('.m').value = 'picture'; upd(); };
    dz.onclick = () => inp.click(); inp.onchange = () => inp.files[0] && take(inp.files[0]);
    dz.ondragover = e => { e.preventDefault(); dz.classList.add('over'); }; dz.ondragleave = () => dz.classList.remove('over');
    dz.ondrop = e => { e.preventDefault(); dz.classList.remove('over'); if (e.dataTransfer.files[0]) take(e.dataTransfer.files[0]); };
    drawFxTex(r);
  });
}
function drawFxTex(r) {
  const c = r.canvas, g = c.getContext('2d'), W = c.width, H = c.height;
  g.clearRect(0, 0, W, H);
  g.drawImage(r.mode === 'picture' && r.pic ? r.pic : r.img, 0, 0, W, H);
  if (r.mode !== 'keep' && (r.hue || r.amt)) {
    const im = g.getImageData(0, 0, W, H), d = im.data, t = hex2rgb(r.tint);
    for (let i = 0; i < d.length; i += 4) {
      let R = d[i], G = d[i + 1], B = d[i + 2];
      if (r.hue) [R, G, B] = hueRotate(R, G, B, r.hue);
      if (r.amt) { const l = Math.max(R, G, B) / 255; R += (t[0] * l - R) * r.amt; G += (t[1] * l - G) * r.amt; B += (t[2] * l - B) * r.amt; }
      d[i] = R; d[i + 1] = G; d[i + 2] = B;
    }
    g.putImageData(im, 0, 0);
  }
  if (r.mode === 'keep') FX.tex.delete(r.name); else { FX.tex.set(r.name, c); viewer.texture(c); }
}
$('fxSave').onclick = async () => {
  if (!FX.row) { $('fxMsg').textContent = 'Pick a set effect first.'; return; }
  const textures = {};
  for (const r of FXM.rows) if (r.mode !== 'keep') textures[r.name] = r.canvas.toDataURL('image/png');
  if (!Object.keys(textures).length) { $('fxMsg').textContent = 'Recolour or replace at least one texture.'; return; }
  try {
    const job = await api('/api/effect', { name: $('fxName').value.trim(), template: FX.row.name, textures });
    const j = await runJob(job, $('effectLog'));
    $('fxMsg').innerHTML = j.ok ? '<span class="ok">Saved.</span>' : '<span class="bad">Failed, see the log.</span>';
    await refreshMine();
  } catch (e) { $('fxMsg').innerHTML = '<span class="bad">' + e.message + '</span>'; }
};
$('effectPkg').onclick = async () => {
  const names = checked('effect'); if (!names.length) { $('effectLog').textContent = 'Tick the effects to package first.'; return; }
  await runJob(await api('/api/effect/package', { names }), $('effectLog'));
};

// ------------------------------------------------------------------ MAP tab: city map tiles with their textures and render maps
// Tiles are Data\field\<area>\<area>_XXXX_YYYY.jmd, 512 m square: tile XXXX starts at x = (XXXX - 1000) * 512 (same for Y).
// The map has its own viewer (far camera, no grid); textures x render map (lightmap, UV2) as the game draws the ground.
const MAP = { viewer: null, areas: [], area: null, loaded: new Map(), sel: null, car: null, cell: 1 };
function mapViewer() {
  if (MAP.viewer) return MAP.viewer;
  const v = new Viewer($('mapGl'));
  v.showGrid = false; v.far = 30000; v.minDist = 5; v.maxDist = 8000; v.fog = [3000, 12000];
  v.pitch = 0.7; v.dist = 950; v.yaw = -2.2;
  MAP.viewer = v; return v;
}
async function mapOpen() {
  mapViewer();
  if (MAP.areas.length) return;
  MAP.areas = await api('/api/maps');
  $('mapArea').innerHTML = MAP.areas.map(a => `<option value="${a.area}">${a.area} · ${a.tiles.length} tile${a.tiles.length > 1 ? 's' : ''}</option>`).join('');
  const last = localStorage.getItem('ws.maparea');
  if (last && MAP.areas.some(a => a.area === last)) $('mapArea').value = last;
  mapArea();
}
$('mapArea').onchange = () => mapArea();
const tileName = (area, t) => `${area}_${String(t[0]).padStart(4, '0')}_${String(t[1]).padStart(4, '0')}`;
function mapArea() {
  const a = MAP.areas.find(x => x.area === $('mapArea').value); if (!a) return;
  localStorage.setItem('ws.maparea', a.area);
  mapClear(); MAP.area = a;
  const xs = a.tiles.map(t => t[0]), ys = a.tiles.map(t => t[1]);
  a.box = [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
  $('mapAreaInfo').textContent = `${a.tiles.length} tiles · area ${((a.box[2] - a.box[0] + 1) * 0.512).toFixed(1)} × ${((a.box[3] - a.box[1] + 1) * 0.512).toFixed(1)} km`;
  const cx = (a.box[0] + a.box[2]) / 2, cy = (a.box[1] + a.box[3]) / 2;
  const t = a.tiles.slice().sort((p, q) => Math.hypot(p[0] - cx, p[1] - cy) - Math.hypot(q[0] - cx, q[1] - cy))[0];
  mapPick(t, false);
}
function drawMapGrid() {
  const a = MAP.area, c = $('mapGrid'), g = c.getContext('2d');
  if (!a) return;
  const [x0, , , y1] = a.box, n = Math.max(a.box[2] - a.box[0] + 1, a.box[3] - a.box[1] + 1);
  c.width = c.height = Math.max(240, Math.ceil(240 / n) * n);
  const k = MAP.cell = c.width / n, gap = k > 5 ? 1 : 0;
  g.fillStyle = '#0b0d12'; g.fillRect(0, 0, c.width, c.height);
  for (const t of a.tiles) {
    const key = tileName(a.area, t);
    g.fillStyle = MAP.sel === key ? '#d9a24f' : MAP.loaded.has(key) ? '#7a5d2e' : '#2a3140';
    g.fillRect((t[0] - x0) * k, (y1 - t[1]) * k, k - gap, k - gap);
  }
}
function gridTile(e) {
  const a = MAP.area; if (!a) return null;
  const c = $('mapGrid'), r = c.getBoundingClientRect(), k = MAP.cell * r.width / c.width;
  const tx = a.box[0] + Math.floor((e.clientX - r.left) / k), ty = a.box[3] - Math.floor((e.clientY - r.top) / k);
  return a.tiles.find(p => p[0] === tx && p[1] === ty) || null;
}
$('mapGrid').onclick = e => { const t = gridTile(e); if (t) mapPick(t, e.shiftKey); };
$('mapGrid').onmousemove = e => { const t = gridTile(e); $('mapTileInfo').textContent = t ? tileName(MAP.area.area, t) + ` · x ${(t[0] - 1000) * 512} … ${(t[0] - 999) * 512} m, y ${(t[1] - 1000) * 512} … ${(t[1] - 999) * 512} m` : 'Click a tile to load it. Shift-click adds tiles.'; };
function mapClear() {
  for (const L of MAP.loaded.values()) { MAP.viewer.free(L.geo); if (L.objGeo) MAP.viewer.free(L.objGeo); }
  MAP.loaded.clear();
  if (MAP.car) { MAP.car.geos.forEach(g => MAP.viewer.free(g.geo)); MAP.car = null; }
  if (MAP.viewer) MAP.viewer.setObjects([]);
}
function smoothNormals(m) {
  const P = m.positions, N = new Float32Array(P.length);
  for (const p of m.parts) {
    const I = p.indices;
    for (let i = 0; i < I.length; i += 3) {
      const a = I[i] * 3, b = I[i + 1] * 3, c = I[i + 2] * 3;
      const ux = P[b] - P[a], uy = P[b + 1] - P[a + 1], uz = P[b + 2] - P[a + 2], vx = P[c] - P[a], vy = P[c + 1] - P[a + 1], vz = P[c + 2] - P[a + 2];
      const nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      for (const k of [a, b, c]) { N[k] += nx; N[k + 1] += ny; N[k + 2] += nz; }
    }
  }
  for (let i = 0; i < N.length; i += 3) { const l = Math.hypot(N[i], N[i + 1], N[i + 2]) || 1; N[i] /= l; N[i + 1] /= l; N[i + 2] /= l; }
  m.normals = N;
}
async function mapLoad(t) {
  const a = MAP.area, key = tileName(a.area, t);
  if (MAP.loaded.has(key)) return MAP.loaded.get(key);
  const d = await api('/api/tile?area=' + enc(a.area) + '&tile=' + enc(key));
  const mesh = await api(d.mesh);
  smoothNormals(mesh);
  const v = MAP.viewer, L = { key, t, geo: v.upload(mesh), mats: [], lms: new Set(), missing: mesh.missing || [] };
  await Promise.all(mesh.materials.map(async (m, i) => {
    L.mats[i + 1] = { tex: m.tex ? await loadImg(d.tex + m.tex) : null, lm: m.lm ? await loadImg(d.tex + m.lm) : null };
    if (m.lm) L.lms.add(m.lm);
  }));
  L.texBase = d.tex;
  const objs = await api(d.objects);
  if (objs.positions.length) { if (!objs.normals.length) smoothNormals(objs); L.objGeo = v.upload(objs); L.objCount = objs.parts.length; }
  L.z = mesh.positions.length ? (() => { let s = 0, n = 0; for (let i = 2; i < mesh.positions.length; i += 30) { s += mesh.positions[i]; n++; } return s / n; })() : 0;
  L.ground = mesh; // kept for the car's height
  MAP.loaded.set(key, L);
  drawMapGrid();
  return L;
}
async function mapPick(t, add) {
  const a = MAP.area, v = mapViewer();
  if (!add) mapClear();
  const want = [t];
  if ($('mapNeighbours').checked && !add) for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) {
    if (!dx && !dy) continue;
    const n = a.tiles.find(p => p[0] === t[0] + dx && p[1] === t[1] + dy); if (n) want.push(n);
  }
  MAP.sel = tileName(a.area, t); drawMapGrid();
  $('mapBusy').classList.remove('hidden'); status('loading map tiles (first time ~2 s per tile)…');
  try {
    const sel = await mapLoad(t);
    v.target = [(t[0] - 1000) * 512 + 256, (t[1] - 1000) * 512 + 256, sel.z];
    v.home = { target: v.target.slice(), dist: 950 };
    if (!add) v.dist = 950;
    mapObjects();
    await Promise.all(want.slice(1).map(p => mapLoad(p).then(mapObjects)));
    status(MAP.sel + ' ready' + (sel.missing.length ? ` · ${sel.missing.length} texture(s) not found in the game files` : ''));
  } catch (e) { status('error: ' + e.message); }
  $('mapBusy').classList.add('hidden');
  mapObjects(); showLmList();
}
async function mapObjects() {
  const v = MAP.viewer, lm = +document.querySelector('input[name=mapLm]:checked').value, objs = [];
  for (const L of MAP.loaded.values()) {
    objs.push({ geo: L.geo, kind: 'map', mats: L.mats, lmMode: lm });
    if (L.objGeo && $('mapObjects').checked) objs.push({ geo: L.objGeo, kind: 'car', tex: null });
  }
  if ($('mapCar').checked && S.geos.body && MAP.sel) {
    if (!MAP.car || MAP.car.sel !== MAP.sel || MAP.car.name !== S.car) {
      if (MAP.car) MAP.car.geos.forEach(g => v.free(g.geo));
      const L = MAP.loaded.get(MAP.sel), cx = v.home.target[0], cy = v.home.target[1];
      // street level: the most common ground height within 100 m of the tile centre (roads and pavements share it),
      // then the vertex at that height nearest the centre
      let x = cx, y = cy, z = L ? L.z : 0;
      if (L) {
        const P = L.ground.positions, bins = new Map();
        for (let i = 0; i < P.length; i += 3) if ((P[i] - cx) ** 2 + (P[i + 1] - cy) ** 2 < 1e4) { const k = Math.round(P[i + 2] * 2); bins.set(k, (bins.get(k) || 0) + 1); }
        const top = [...bins].sort((p, q) => q[1] - p[1])[0];
        if (top) { let best = 1e18; for (let i = 0; i < P.length; i += 3) { if (Math.round(P[i + 2] * 2) !== top[0]) continue; const d = (P[i] - cx) ** 2 + (P[i + 1] - cy) ** 2; if (d < best) { best = d; x = P[i]; y = P[i + 1]; z = P[i + 2]; } } }
      }
      // the car as the 3D Preview shows it: body, chosen kit parts, wheels
      const base = '/cache/cars/' + S.car + '/meshes/', tm = [1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, z], geos = [];
      const urls = [['body', 'car'], ['wheels', 'wheels'], ...S.model.folders.map(f => [(f.variants.find(q => q.id === S.variants[f.folder]) || {}).mesh, 'car']).filter(u => u[0])];
      for (const [u, kind] of urls) { try { geos.push({ geo: v.upload(await api(base + u + '.json'), tm), kind }); } catch { /* none */ } }
      MAP.car = { sel: MAP.sel, name: S.car, pos: [x, y, z + 0.6], geos };
    }
    for (const g of MAP.car.geos) objs.push({ geo: g.geo, tex: S.carTex, kind: g.kind });
  }
  v.setObjects(objs);
}
qsa('input[name=mapLm]').forEach(r => r.onchange = mapObjects);
$('mapObjects').onchange = mapObjects;
$('mapCar').onchange = async () => { await mapObjects(); if ($('mapCar').checked && MAP.car) { MAP.viewer.dist = 18; MAP.viewer.pitch = 0.3; MAP.viewer.target = MAP.car.pos.slice(); } };
$('mapTop').onclick = () => { const v = MAP.viewer; v.pitch = 1.5; v.dist = 1100; v.target = v.home.target.slice(); };
$('mapLow').onclick = () => { const v = MAP.viewer; v.pitch = 0.22; v.dist = 300; };
function showLmList() {
  const L = MAP.loaded.get(MAP.sel);
  if (!L) { $('mapLmList').innerHTML = ''; return; }
  const info = `<div class="muted small" style="width:100%">${L.key}: ${L.mats.length - 1} materials${L.objCount ? ', ' + L.objCount + ' placed objects' : ''}</div>`;
  $('mapLmList').innerHTML = info + ([...L.lms].map(n => `<a href="${L.texBase + n}" target="_blank" title="${n}"><img src="${L.texBase + n}"></a>`).join('') || '<span class="muted small">No render maps.</span>');
}

// ------------------------------------------------------------------ RESHAPE tab: sculpt the body or a part, find broken spots
// Works on the LOD-2 meshes the 3D Preview shows (S.meshes / S.geos). Positions change in place, so doors and the
// other tabs see the new shape; backend\reshape.ps1 writes all LODs and the package.
const RS = { data: {}, key: null, tool: 'move', stroke: null, spots: [], spotI: -1, marks: null, ring: null, sets: {} };
const rsMode = () => document.querySelector('input[name=rsMode]:checked').value;
const fileOf = key => key === 'body' ? (S.meshes.body.parts.some(p => /^big_/.test(p.name)) ? 'big' : 'body') : S.meshes[key].file.replace('__', '/');

function rsPrepare(key) {
  if (RS.data[key] && RS.data[key].geo === S.geos[key]) return RS.data[key];
  const m = S.meshes && S.meshes[key], g = S.geos[key];
  if (!m || !g || S.loading) return null; // (a car is still loading)
  const n = m.positions.length / 3;
  const pos = Float32Array.from(m.positions), orig = Float32Array.from(m.positions);
  const nor0 = m.normals.length === pos.length ? Float32Array.from(m.normals) : new Float32Array(pos.length);
  const tl = []; for (const p of m.parts) for (const i of p.indices) tl.push(i);
  const tris = Uint32Array.from(tl);
  // welded copies: vertices at the same spot (UV seams) move together
  const wkey = (x, y, z) => Math.round(x * 1e4) + ',' + Math.round(y * 1e4) + ',' + Math.round(z * 1e4);
  const wmap = new Map(), weldOf = new Int32Array(n).fill(-1), welds = [];
  for (let i = 0; i < n; i++) { const k = wkey(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]); const l = wmap.get(k); if (l) l.push(i); else wmap.set(k, [i]); }
  for (const l of wmap.values()) if (l.length > 1) { for (const i of l) weldOf[i] = welds.length; welds.push(l); }
  // neighbours (through welds) and vertex -> triangles
  const nb = Array.from({ length: n }, () => new Set()), vt = Array.from({ length: n }, () => []);
  for (let t = 0; t < tris.length; t += 3) for (let c = 0; c < 3; c++) { const a = tris[t + c]; vt[a].push(t); nb[a].add(tris[t + (c + 1) % 3]); nb[a].add(tris[t + (c + 2) % 3]); }
  const root = i => weldOf[i] >= 0 ? welds[weldOf[i]][0] : i;
  const nbr = new Array(n);
  for (let i = 0; i < n; i++) { const s = new Set(); const grp = weldOf[i] >= 0 ? welds[weldOf[i]] : [i]; for (const j of grp) for (const q of nb[j]) { const r = root(q); if (r !== root(i)) s.add(r); } nbr[i] = [...s]; }
  // mirror partner (x -> -x) within 2 mm
  const mkey = (x, y, z) => Math.round(x * 500) + ',' + Math.round(y * 500) + ',' + Math.round(z * 500);
  const mm = new Map(); for (let i = 0; i < n; i++) mm.set(mkey(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]), i);
  const mirror = new Int32Array(n).fill(-1); for (let i = 0; i < n; i++) { const j = mm.get(mkey(-pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2])); if (j !== undefined) mirror[i] = j; }
  const d = { key, mesh: m, geo: g, n, pos, orig, nor0, nor: Float32Array.from(nor0), tris, weldOf, welds, nbr, vt, mirror, undo: [], redo: [] };
  d.fn0 = new Float32Array(n * 3); for (let i = 0; i < n; i++) d.fn0.set(faceAvg(d, i, orig), i * 3);
  m.positions = pos; m.normals = d.nor;
  return (RS.data[key] = d);
}
function faceAvg(d, i, P) { // area-weighted average normal of the vertex's triangles
  let x = 0, y = 0, z = 0;
  for (const t of d.vt[i]) {
    const a = d.tris[t] * 3, b = d.tris[t + 1] * 3, c = d.tris[t + 2] * 3;
    const ux = P[b] - P[a], uy = P[b + 1] - P[a + 1], uz = P[b + 2] - P[a + 2], vx = P[c] - P[a], vy = P[c + 1] - P[a + 1], vz = P[c + 2] - P[a + 2];
    x += uy * vz - uz * vy; y += uz * vx - ux * vz; z += ux * vy - uy * vx;
  }
  const l = Math.hypot(x, y, z) || 1; return [x / l, y / l, z / l];
}
// after moving vertices: mirror, keep welded copies together, update normals (old normal + change of face normal), upload
function rsCommit(d, moved, side) {
  const A = new Set(moved);
  if ($('rsMirror').checked && side) for (const i of moved) { // brush strokes only (whole-piece changes are already symmetric)
    const ox = d.orig[i * 3];
    if (Math.abs(ox) < 1e-3) { d.pos[i * 3] = 0; continue; }
    if (side && Math.sign(ox) !== side) continue;
    const j = d.mirror[i]; if (j < 0 || j === i) continue;
    d.pos[j * 3] = -d.pos[i * 3]; d.pos[j * 3 + 1] = d.pos[i * 3 + 1]; d.pos[j * 3 + 2] = d.pos[i * 3 + 2]; A.add(j);
  }
  const done = new Set();
  for (const i of [...A]) {
    const w = d.weldOf[i]; if (w < 0 || done.has(w)) continue; done.add(w);
    const g = d.welds[w]; let x = 0, y = 0, z = 0;
    for (const j of g) { x += d.pos[j * 3]; y += d.pos[j * 3 + 1]; z += d.pos[j * 3 + 2]; }
    for (const j of g) { d.pos[j * 3] = x / g.length; d.pos[j * 3 + 1] = y / g.length; d.pos[j * 3 + 2] = z / g.length; A.add(j); }
  }
  const ring = new Set(A); for (const i of A) for (const t of d.vt[i]) for (let c = 0; c < 3; c++) ring.add(d.tris[t + c]);
  for (const i of ring) {
    const fn = faceAvg(d, i, d.pos);
    let x = d.nor0[i * 3] + fn[0] - d.fn0[i * 3], y = d.nor0[i * 3 + 1] + fn[1] - d.fn0[i * 3 + 1], z = d.nor0[i * 3 + 2] + fn[2] - d.fn0[i * 3 + 2];
    const l = Math.hypot(x, y, z) || 1; d.nor[i * 3] = x / l; d.nor[i * 3 + 1] = y / l; d.nor[i * 3 + 2] = z / l;
  }
  viewer.updateGeo(d.geo, d.pos, d.nor);
}

function rsHit(d, ray) { // nearest triangle hit: {t, p, n}
  const P = d.pos, T = d.tris, o = ray.o, dir = ray.d; let best = 1e9, bi = -1;
  for (let k = 0; k < T.length; k += 3) {
    const a = T[k] * 3, b = T[k + 1] * 3, c = T[k + 2] * 3;
    const e1x = P[b] - P[a], e1y = P[b + 1] - P[a + 1], e1z = P[b + 2] - P[a + 2], e2x = P[c] - P[a], e2y = P[c + 1] - P[a + 1], e2z = P[c + 2] - P[a + 2];
    const px = dir[1] * e2z - dir[2] * e2y, py = dir[2] * e2x - dir[0] * e2z, pz = dir[0] * e2y - dir[1] * e2x;
    const det = e1x * px + e1y * py + e1z * pz; if (Math.abs(det) < 1e-12) continue;
    const inv = 1 / det, tx = o[0] - P[a], ty = o[1] - P[a + 1], tz = o[2] - P[a + 2];
    const u = (tx * px + ty * py + tz * pz) * inv; if (u < 0 || u > 1) continue;
    const qx = ty * e1z - tz * e1y, qy = tz * e1x - tx * e1z, qz = tx * e1y - ty * e1x;
    const v = (dir[0] * qx + dir[1] * qy + dir[2] * qz) * inv; if (v < 0 || u + v > 1) continue;
    const t = (e2x * qx + e2y * qy + e2z * qz) * inv; if (t > 0.01 && t < best) { best = t; bi = k; }
  }
  if (bi < 0) return null;
  const a = T[bi] * 3, b = T[bi + 1] * 3, c = T[bi + 2] * 3;
  let nx = (P[b + 1] - P[a + 1]) * (P[c + 2] - P[a + 2]) - (P[b + 2] - P[a + 2]) * (P[c + 1] - P[a + 1]),
    ny = (P[b + 2] - P[a + 2]) * (P[c] - P[a]) - (P[b] - P[a]) * (P[c + 2] - P[a + 2]),
    nz = (P[b] - P[a]) * (P[c + 1] - P[a + 1]) - (P[b + 1] - P[a + 1]) * (P[c] - P[a]);
  const l = Math.hypot(nx, ny, nz) || 1; nx /= l; ny /= l; nz /= l;
  if (nx * dir[0] + ny * dir[1] + nz * dir[2] > 0) { nx = -nx; ny = -ny; nz = -nz; }
  return { t: best, p: [o[0] + dir[0] * best, o[1] + dir[1] * best, o[2] + dir[2] * best], n: [nx, ny, nz] };
}
function rsNear(d, p, R) { // vertices within R: [indices], [weights]
  const I = [], W = [], P = d.pos, R2 = R * R;
  for (let i = 0; i < d.n; i++) {
    const dx = P[i * 3] - p[0], dy = P[i * 3 + 1] - p[1], dz = P[i * 3 + 2] - p[2], q = dx * dx + dy * dy + dz * dz;
    if (q < R2) { const f = 1 - q / R2; I.push(i); W.push(f * f); }
  }
  return { I, W };
}
// undo steps cover every piece a stroke touched: [[d, positions before], ...]
RS.undo = []; RS.redo = [];
function rsPush(list) { RS.undo.push(list.map(d => [d, Float32Array.from(d.pos)])); if (RS.undo.length > 30) RS.undo.shift(); RS.redo = []; }
// the pieces the brush works on: in Edit car with "All pieces together", the body and every fitted part (so a roof part
// and the body's roof edge move as one); otherwise the chosen piece only
function rsTargets() {
  if (rsMode() === 'edit' && $('rsAllPieces').checked) return rsPieces().map(([k]) => S.meshes[k] && rsPrepare(k)).filter(Boolean);
  return RS.data[RS.key] ? [RS.data[RS.key]] : [];
}
function rsHitAll(list, ray) { let best = null; for (const d of list) { const h = rsHit(d, ray); if (h && (!best || h.t < best.t)) best = h; } return best; }

// brush on the viewer: left-drag
const rsTool = {
  down(e) {
    const list = rsTargets(); if (!list.length) return;
    const h = rsHitAll(list, viewer.ray(e.clientX, e.clientY)); if (!h) { RS.stroke = null; return; }
    const R = +$('rsRadius').value;
    const parts = list.map(d => { const near = rsNear(d, h.p, R); return { d, near, grab: Float32Array.from(near.I.flatMap(i => [d.pos[i * 3], d.pos[i * 3 + 1], d.pos[i * 3 + 2]])) }; }).filter(p => p.near.I.length || RS.tool !== 'move');
    rsPush(list);
    RS.stroke = { h, parts, list, x: e.clientX, y: e.clientY, side: Math.sign(h.p[0]) };
    if (RS.tool !== 'move' && RS.tool !== 'push') rsRub(list, h);
  },
  move(e) {
    const s = RS.stroke; if (!s) return;
    const st = +$('rsStrength').value;
    if (RS.tool === 'move' || RS.tool === 'push') {
      const rect = viewer.canvas.getBoundingClientRect(), k = s.h.t * 2 * Math.tan(0.31) / rect.height;
      const dx = (e.clientX - s.x) * k, dy = (e.clientY - s.y) * k, v = viewer.viewM;
      const D = RS.tool === 'move' ? [0, 1, 2].map(c => (v[c * 4] * dx - v[c * 4 + 1] * dy) * (0.4 + st)) : s.h.n.map(c => -c * dy * (0.4 + st));
      for (const p of s.parts) {
        p.near.I.forEach((i, q) => { const w = p.near.W[q]; for (let c = 0; c < 3; c++) p.d.pos[i * 3 + c] = p.grab[q * 3 + c] + w * D[c]; });
        if (p.near.I.length) rsCommit(p.d, p.near.I, s.side);
      }
    } else {
      const h = rsHitAll(s.list, viewer.ray(e.clientX, e.clientY)); if (h) rsRub(s.list, h);
    }
    rsCursor(e);
  },
  up() { RS.stroke = null; rsInfo(); },
  hover(e) { rsCursor(e); },
};
function rsRub(list, h) {
  const R = +$('rsRadius').value, st = +$('rsStrength').value * 0.5;
  for (const d of list) {
    const near = rsNear(d, h.p, R), P = d.pos; if (!near.I.length) continue;
    near.I.forEach((i, q) => {
      const w = near.W[q] * st;
      if (RS.tool === 'smooth') {
        const nb = d.nbr[i]; if (!nb.length) return; let x = 0, y = 0, z = 0;
        for (const j of nb) { x += P[j * 3]; y += P[j * 3 + 1]; z += P[j * 3 + 2]; }
        P[i * 3] += (x / nb.length - P[i * 3]) * w; P[i * 3 + 1] += (y / nb.length - P[i * 3 + 1]) * w; P[i * 3 + 2] += (z / nb.length - P[i * 3 + 2]) * w;
      } else if (RS.tool === 'flatten') {
        const k = (P[i * 3] - h.p[0]) * h.n[0] + (P[i * 3 + 1] - h.p[1]) * h.n[1] + (P[i * 3 + 2] - h.p[2]) * h.n[2];
        for (let c = 0; c < 3; c++) P[i * 3 + c] -= h.n[c] * k * w;
      } else if (RS.tool === 'restore') for (let c = 0; c < 3; c++) P[i * 3 + c] += (d.orig[i * 3 + c] - P[i * 3 + c]) * w;
    });
    rsCommit(d, near.I, Math.sign(h.p[0]));
  }
}
// brush ring under the mouse
let rsRingTex = null;
function rsCursor(e) {
  const list = rsTargets(); if (!list.length) return;
  const h = rsHitAll(list, viewer.ray(e.clientX, e.clientY));
  if (!RS.ring) {
    rsRingTex = document.createElement('canvas'); rsRingTex.width = rsRingTex.height = 128; const g = rsRingTex.getContext('2d');
    g.strokeStyle = 'rgba(217,162,79,1)'; g.lineWidth = 5; g.beginPath(); g.arc(64, 64, 60, 0, 7); g.stroke(); g.fillStyle = 'rgba(217,162,79,0.12)'; g.fill();
    RS.ring = { geo: viewer.upload({ positions: [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0], uvs: [0, 0, 1, 0, 1, 1, 0, 1], normals: [], parts: [{ name: 'ring', group: 0, cat: 0, indices: [0, 1, 2, 0, 2, 3] }] }), kind: 'fx', tex: rsRingTex, model: new Float32Array(16), alpha: 1, hidden: true };
  }
  if (!h) { RS.ring.hidden = true; return; }
  const n = h.n, R = +$('rsRadius').value, a = Math.abs(n[2]) < 0.9 ? [0, 0, 1] : [1, 0, 0];
  let t = cross(a, n); t = norm(t); const b = cross(n, t);
  m44([t[0] * R, b[0] * R, n[0], h.p[0] + n[0] * 0.003, t[1] * R, b[1] * R, n[1], h.p[1] + n[1] * 0.003, t[2] * R, b[2] * R, n[2], h.p[2] + n[2] * 0.003], RS.ring.model);
  RS.ring.hidden = false;
}
qsa('#rsTools button').forEach(b => b.onclick = () => { qsa('#rsTools button').forEach(x => x.classList.toggle('on', x === b)); RS.tool = b.dataset.tool; });
$('rsRadius').oninput = e => { $('rsRadiusOut').textContent = (+e.target.value).toFixed(2) + ' m'; };

// pieces
function rsPieces() {
  const out = [['body', S.meshes.body.parts.some(p => /^big_/.test(p.name)) ? 'Body (big model, big_2.rcb)' : 'Body']];
  for (const k in S.meshes) if (k.startsWith('part:')) out.push([k, k.slice(5) + ': ' + S.meshes[k].file.split('__')[1]]);
  return out;
}
function rsFill() {
  if (!S.model) return;
  $('rsPiece').innerHTML = rsPieces().map(([k, l]) => `<option value="${k}">${l}${RS.data[k] && rsChanged(RS.data[k]) ? ' · edited' : ''}</option>`).join('');
  if (RS.key && rsPieces().some(p => p[0] === RS.key)) $('rsPiece').value = RS.key;
  const folders = S.model.folders.filter(f => f.variants.some(v => v.mesh));
  const cur = $('rsFolder').value;
  $('rsFolder').innerHTML = folders.map(f => `<option>${f.folder}</option>`).join('');
  if (cur && folders.some(f => f.folder === cur)) $('rsFolder').value = cur;
  rsFillBase();
}
function rsFillBase() {
  const f = S.model.folders.find(x => x.folder === $('rsFolder').value); if (!f) { $('rsBase').innerHTML = ''; return; }
  $('rsBase').innerHTML = f.variants.filter(v => v.mesh).map(v => `<option value="${v.id}">${v.id} · ${v.name}</option>`).join('');
  if (S.variants[f.folder] && f.variants.some(v => v.id === S.variants[f.folder] && v.mesh)) $('rsBase').value = S.variants[f.folder];
}
const rsChanged = d => { for (let i = 0; i < d.pos.length; i++) if (Math.abs(d.pos[i] - d.orig[i]) > 1e-4) return true; return false; };
async function rsStart() {
  if (!S.model) return;
  rsClearMarks();
  let key;
  if (rsMode() === 'edit') key = $('rsPiece').value || 'body';
  else {
    const folder = $('rsFolder').value, id = $('rsBase').value;
    if (!folder) return;
    if (S.variants[folder] !== id) {
      if (RS.data['part:' + folder]) delete RS.data['part:' + folder]; // another variant: its own mesh
      S.variants[folder] = id; fillParts(); await loadParts();
    }
    key = 'part:' + folder;
    const v = S.model.folders.find(f => f.folder === folder).variants.find(x => x.id === id);
    RS.sets[folder] = { folder, base: { name: v.name, mesh: v.mesh.split('__')[1], tex: (v.tex || '').replace(/^.*__/, '').replace(/\.png$/i, '') } };
    if (!$('rsName').value) $('rsName').value = ('my_' + v.name).toLowerCase().replace(/[^a-z0-9_]/g, '_').slice(0, 30);
  }
  if (!S.meshes[key]) { $('rsInfo').textContent = 'This piece has no mesh.'; return; }
  busy(true); await new Promise(r => setTimeout(r, 20));
  RS.key = key; const ok = rsPrepare(key); busy(false);
  if (!ok) { $('rsInfo').textContent = 'Still loading…'; return; }
  rsInfo();
}
function rsInfo() {
  const d = RS.data[RS.key]; if (!d) return;
  const edited = Object.values(RS.data).filter(rsChanged).length;
  let moved = 0; for (let i = 0; i < d.n; i++) if (Math.abs(d.pos[i * 3] - d.orig[i * 3]) + Math.abs(d.pos[i * 3 + 1] - d.orig[i * 3 + 1]) + Math.abs(d.pos[i * 3 + 2] - d.orig[i * 3 + 2]) > 1e-4) moved++;
  $('rsInfo').textContent = `${fileOf(RS.key)}: ${d.n} vertices, ${d.tris.length / 3} triangles · ${moved} moved` + (edited ? ` · ${edited} piece${edited > 1 ? 's' : ''} changed` : '') + (rsMode() === 'set' ? ' · saved as a new part, the original stays' : '');
}
qsa('input[name=rsMode]').forEach(r => r.onchange = () => { $('rsEditBox').classList.toggle('hidden', rsMode() !== 'edit'); $('rsSetBox').classList.toggle('hidden', rsMode() !== 'set'); rsStart(); });
$('rsPiece').onchange = rsStart;
$('rsFolder').onchange = () => { rsFillBase(); rsStart(); };
$('rsBase').onchange = rsStart;

// whole piece
$('rsApply').onclick = () => {
  const d = RS.data[RS.key]; if (!d) return;
  rsPush([d]);
  const lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9];
  for (let i = 0; i < d.n; i++) for (let k = 0; k < 3; k++) { lo[k] = Math.min(lo[k], d.pos[i * 3 + k]); hi[k] = Math.max(hi[k], d.pos[i * 3 + k]); }
  const c = [0, 1, 2].map(k => (lo[k] + hi[k]) / 2); if ($('rsMirror').checked) c[0] = 0;
  const s = ['rsSx', 'rsSy', 'rsSz'].map(id => (+$(id).value || 100) / 100), mv = ['rsMx', 'rsMy', 'rsMz'].map(id => (+$(id).value || 0) / 100), inf = (+$('rsInf').value || 0) / 100;
  const all = [];
  for (let i = 0; i < d.n; i++) { for (let k = 0; k < 3; k++) d.pos[i * 3 + k] = c[k] + (d.pos[i * 3 + k] - c[k]) * s[k] + mv[k] + d.nor[i * 3 + k] * inf; all.push(i); }
  rsCommit(d, all, 0);
  ['rsSx', 'rsSy', 'rsSz'].forEach(id => $(id).value = 100); ['rsMx', 'rsMy', 'rsMz', 'rsInf'].forEach(id => $(id).value = 0);
  rsInfo();
};

// broken spots: spikes (a point far off the average of its neighbours, compared with its edge lengths) and stray
// stretched triangles (an edge longer than 1 m and 10x the mesh's usual edge)
function rsClearMarks() { if (RS.marks) { viewer.free(RS.marks.geo); RS.marks = null; } RS.spots = []; RS.spotI = -1; recompose(); }
$('rsFind').onclick = () => {
  const d = RS.data[RS.key]; if (!d) return;
  rsClearMarks();
  const P = d.pos, spots = new Set(), edges = [];
  for (let t = 0; t < d.tris.length; t += 3) for (let c = 0; c < 3; c++) { const a = d.tris[t + c] * 3, b = d.tris[t + (c + 1) % 3] * 3; edges.push(Math.hypot(P[a] - P[b], P[a + 1] - P[b + 1], P[a + 2] - P[b + 2])); }
  const med = edges.slice().sort((x, y) => x - y)[edges.length >> 1] || 0.05;
  // spike: the point sits more than 5 cm and 2x the neighbours' own spread away from their middle (open panel edges skipped:
  // their neighbours are all on one side). Tuned on clio / sparta / aventadorlb: 0-10 hits clean, a 25 cm pulled point found.
  const root = i => d.weldOf[i] >= 0 ? d.welds[d.weldOf[i]][0] : i, ec = new Map(), K = (a, b) => a < b ? a + '_' + b : b + '_' + a;
  for (let t = 0; t < d.tris.length; t += 3) for (let c = 0; c < 3; c++) { const k = K(root(d.tris[t + c]), root(d.tris[t + (c + 1) % 3])); ec.set(k, (ec.get(k) || 0) + 1); }
  const bnd = new Uint8Array(d.n); for (const [k, v] of ec) if (v === 1) { const [a, b] = k.split('_'); bnd[a] = 1; bnd[b] = 1; }
  for (let i = 0; i < d.n; i++) {
    if (root(i) !== i || bnd[i]) continue;
    const nb = d.nbr[i]; if (nb.length < 3) continue;
    let x = 0, y = 0, z = 0;
    for (const j of nb) { x += P[j * 3]; y += P[j * 3 + 1]; z += P[j * 3 + 2]; }
    x /= nb.length; y /= nb.length; z /= nb.length;
    let sp = 0; for (const j of nb) sp += Math.hypot(P[j * 3] - x, P[j * 3 + 1] - y, P[j * 3 + 2] - z); sp /= nb.length;
    const lap = Math.hypot(x - P[i * 3], y - P[i * 3 + 1], z - P[i * 3 + 2]);
    if (lap > 0.05 && lap > 2 * sp) spots.add(i);
  }
  let k = 0;
  // stray triangle: an edge over 1 m and 15x the usual edge, on a needle-thin triangle (height under 4% of that edge)
  const thin = t => { const a = d.tris[t] * 3, b = d.tris[t + 1] * 3, c = d.tris[t + 2] * 3;
    const ux = P[b] - P[a], uy = P[b + 1] - P[a + 1], uz = P[b + 2] - P[a + 2], vx = P[c] - P[a], vy = P[c + 1] - P[a + 1], vz = P[c + 2] - P[a + 2];
    const area2 = Math.hypot(uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx), L = Math.max(edges[t], edges[t + 1], edges[t + 2]);
    return area2 / L < 0.04 * L; };
  for (let t = 0; t < d.tris.length; t += 3) for (let c = 0; c < 3; c++, k++) if (edges[k] > Math.max(1.0, 15 * med) && thin(t)) {
    // the corner that is far from everything else is the stray one
    const a = d.tris[t + c], b = d.tris[t + (c + 1) % 3]; spots.add(d.nbr[a].length < d.nbr[b].length ? a : b);
  }
  RS.spots = [...spots];
  $('rsSpots').textContent = RS.spots.length ? `${RS.spots.length} spot${RS.spots.length > 1 ? 's' : ''} found (red). Next › shows them one by one; Fix all smooths them.` : 'No broken spots found on this piece.';
  if (RS.spots.length) {
    const pos = [], idx = [], s = 0.025;
    for (const i of RS.spots.slice(0, 3000)) {
      const b = pos.length / 3, x = P[i * 3], y = P[i * 3 + 1], z = P[i * 3 + 2];
      pos.push(x + s, y, z, x - s, y, z, x, y + s, z, x, y - s, z, x, y, z + s, x, y, z - s);
      idx.push(b, b + 2, b + 4, b + 2, b + 1, b + 4, b + 1, b + 3, b + 4, b + 3, b, b + 4, b + 2, b, b + 5, b + 1, b + 2, b + 5, b + 3, b + 1, b + 5, b, b + 3, b + 5);
    }
    const red = document.createElement('canvas'); red.width = red.height = 4; const g = red.getContext('2d'); g.fillStyle = '#ff3030'; g.fillRect(0, 0, 4, 4);
    RS.marks = { geo: viewer.upload({ positions: pos, uvs: new Array(pos.length / 3 * 2).fill(0.5), normals: [], parts: [{ name: 'marks', group: 0, cat: 0, indices: idx }] }), kind: 'fx', tex: red, alpha: 1 };
  }
  recompose();
};
$('rsNext').onclick = () => {
  const d = RS.data[RS.key]; if (!d || !RS.spots.length) return;
  RS.spotI = (RS.spotI + 1) % RS.spots.length; const i = RS.spots[RS.spotI];
  viewer.target = [d.pos[i * 3], d.pos[i * 3 + 1], d.pos[i * 3 + 2]]; viewer.dist = 1.4;
  $('rsSpots').textContent = `Spot ${RS.spotI + 1} of ${RS.spots.length}`;
};
$('rsFix').onclick = () => {
  const d = RS.data[RS.key]; if (!d || !RS.spots.length) return;
  rsPush([d]);
  const set = new Set(); for (const i of RS.spots) { set.add(i); if (d.weldOf[i] >= 0) d.welds[d.weldOf[i]].forEach(j => set.add(j)); }
  for (let it = 0; it < 8; it++) for (const i of set) {
    const nb = d.nbr[i]; if (!nb.length) continue; let x = 0, y = 0, z = 0;
    for (const j of nb) { x += d.pos[j * 3]; y += d.pos[j * 3 + 1]; z += d.pos[j * 3 + 2]; }
    d.pos[i * 3] += (x / nb.length - d.pos[i * 3]) * 0.7; d.pos[i * 3 + 1] += (y / nb.length - d.pos[i * 3 + 1]) * 0.7; d.pos[i * 3 + 2] += (z / nb.length - d.pos[i * 3 + 2]) * 0.7;
  }
  rsCommit(d, [...set], 0);
  const n = RS.spots.length; rsClearMarks(); $('rsSpots').textContent = `Smoothed ${n} spot${n > 1 ? 's' : ''}. Press Find again to check.`; rsInfo();
};
// undo / reset
$('rsUndo').onclick = () => { const st = RS.undo.pop(); if (!st) return; RS.redo.push(st.map(([d]) => [d, Float32Array.from(d.pos)])); for (const [d, p] of st) { d.pos.set(p); rsAll(d); } };
$('rsRedo').onclick = () => { const st = RS.redo.pop(); if (!st) return; RS.undo.push(st.map(([d]) => [d, Float32Array.from(d.pos)])); for (const [d, p] of st) { d.pos.set(p); rsAll(d); } };
$('rsReset').onclick = () => { const list = rsTargets(); if (!list.length) return; rsPush(list); for (const d of list) { d.pos.set(d.orig); rsAll(d); } };
function rsAll(d) { const all = []; for (let i = 0; i < d.n; i++) all.push(i); const m = $('rsMirror').checked; $('rsMirror').checked = false; rsCommit(d, all, 0); $('rsMirror').checked = m; rsInfo(); }

// save: every edited piece (Edit car) and the new set (Shape new set) -> backend\reshape.ps1
const f32b64 = a => { const u = new Uint8Array(a.buffer, a.byteOffset, a.byteLength); let s = ''; for (let i = 0; i < u.length; i += 32768) s += String.fromCharCode.apply(null, u.subarray(i, i + 32768)); return btoa(s); };
$('rsSave').onclick = async () => {
  const edits = [], sets = [];
  for (const k in RS.data) {
    const d = RS.data[k]; if (!rsChanged(d)) continue;
    const folder = k.startsWith('part:') ? k.slice(5) : null;
    if (folder && RS.sets[folder] && rsMode() === 'set' && RS.key === k) {
      const name = $('rsName').value.trim();
      if (!/^[a-z0-9_]{2,30}$/.test(name)) { $('rsMsg').innerHTML = '<span class="bad">New part name: 2-30 lowercase letters, digits or _</span>'; return; }
      sets.push(Object.assign({}, RS.sets[folder], { name, pos: f32b64(d.pos) }));
    } else edits.push({ file: fileOf(k), pos: f32b64(d.pos) });
  }
  if (!edits.length && !sets.length) { $('rsMsg').textContent = 'Nothing changed yet.'; return; }
  $('rsMsg').textContent = 'saving…';
  try {
    const j = await runJob(await api('/api/reshape', { car: S.car, edits, sets }), $('shapeLog'));
    $('rsMsg').innerHTML = j.ok ? `<span class="ok">Saved: ${edits.length} edited piece${edits.length === 1 ? '' : 's'}${sets.length ? ', new part ' + sets[0].name : ''}. Package in out\\package\\car_${S.car}\\</span>` : '<span class="bad">Failed, see the log.</span>';
  } catch (e) { $('rsMsg').innerHTML = '<span class="bad">' + e.message + '</span>'; }
};
$('rsLoad').onclick = async () => {
  try {
    const r = await (await fetch('/out/carmod/' + enc(S.car) + '/request.json?t=' + Date.now())).json();
    const b64f32 = s => { const b = atob(s), u = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i); return new Float32Array(u.buffer); };
    let n = 0;
    for (const e of r.edits || []) {
      const key = e.file === 'body' || e.file === 'big' ? 'body' : Object.keys(S.meshes).find(k => k.startsWith('part:') && S.meshes[k].file.replace('__', '/') === e.file);
      if (!key) continue;
      const d = rsPrepare(key), p = b64f32(e.pos); if (p.length !== d.pos.length) continue;
      rsPush([d]); d.pos.set(p); rsAll(d); n++;
    }
    $('rsMsg').textContent = `Loaded ${n} saved piece${n === 1 ? '' : 's'}` + ((r.sets || []).length ? ` (new parts are in the car's part lists after the package is used: ${(r.sets || []).map(s => s.folder + '/' + s.name).join(', ')})` : '') + '.';
    rsFill();
  } catch { $('rsMsg').textContent = 'No saved edits for this car.'; }
};
function rsObjects() { const o = []; if (RS.ring && document.querySelector('#tab-shape.on')) o.push(RS.ring); if (RS.marks) o.push(RS.marks); return o; }

// ------------------------------------------------------------------ RESHAPE: Clean texture ("broken pixels")
// Triangles whose UV centre lies in the car texture's _color slot (0.75..1 x 0.75..0.875) take their colour from a
// 128 x 64 pixel strip; backend\clean_texture.ps1 turns each into one solid swatch colour.
function clCount() {
  const m = S.meshes && S.meshes.body; if (!m) return [0, 0];
  let det = 0, all = 0; const U = m.uvs;
  for (const p of m.parts) for (let k = 0; k + 2 < p.indices.length; k += 3) {
    all++;
    const u = (U[p.indices[k] * 2] + U[p.indices[k + 1] * 2] + U[p.indices[k + 2] * 2]) / 3, v = (U[p.indices[k] * 2 + 1] + U[p.indices[k + 1] * 2 + 1] + U[p.indices[k + 2] * 2 + 1]) / 3;
    if (u >= 0.75 && v >= 0.75 && v <= 0.875) det++;
  }
  return [det, all];
}
async function clStatus() {
  if (!S.car) return;
  const [det, all] = clCount();
  let r = { cleaned: false };
  try { r = await api('/api/clean?car=' + enc(S.car)); } catch { /* none */ }
  $('clInfo').innerHTML = (r.cleaned ? '<span class="ok">Cleaned copy in use</span> (' + r.colors + ' colours' + (r.mask ? ', paint mask cleaned' : '') + '). ' : '') +
    `${det.toLocaleString()} of ${all.toLocaleString()} body triangles (${all ? Math.round(det / all * 100) : 0}%) take their colour from the small _color picture` +
    (r.cleaned ? '.' : det / Math.max(1, all) > 0.25 ? ': this car is a good candidate.' : '.');
  $('clPalette').innerHTML = r.cleaned ? r.palette.map(c => `<span title="${c}" style="display:inline-block;width:18px;height:18px;border-radius:4px;border:1px solid var(--line);background:${c}"></span>`).join('') : '';
}
$('clColors').oninput = e => { $('clColorsOut').textContent = e.target.value; };
$('clRun').onclick = async () => {
  if (!S.car) return;
  $('clRun').disabled = true; $('clMsg').textContent = 'cleaning (a big car takes about 5 s)…';
  try {
    const j = await runJob(await api('/api/clean', { car: S.car, colors: +$('clColors').value, mask: $('clMask').checked, specks: $('clSpecks').checked }), $('shapeLog'));
    if (j.ok) {
      $('clMsg').innerHTML = '<span class="ok">Cleaned. The preview now shows the cleaned car; the package is in out\\package\\car_' + S.car + '\\</span>';
      await loadCar(S.car);
    } else $('clMsg').innerHTML = '<span class="bad">Failed, see the log.</span>';
  } catch (e) { $('clMsg').innerHTML = '<span class="bad">' + e.message + '</span>'; }
  $('clRun').disabled = false;
  clStatus();
};
$('clUndo').onclick = async () => {
  if (!S.car) return;
  await api('/api/clean/undo', { car: S.car });
  $('clMsg').textContent = 'Back to the original car (the package folder still holds the last cleaned build).';
  await loadCar(S.car); clStatus();
};

// ------------------------------------------------------------------ IMPORT / hand-off
let hoFiles = [];
dropZone('hoDrop', 'hoFile', files => { hoFiles.push(...files); $('hoFiles').innerHTML = hoFiles.map(f => `<li>${f.name} <span class="muted">${(f.size / 1024).toFixed(0)} KB</span></li>`).join(''); });
$('hoSend').onclick = async () => {
  $('hoSend').disabled = true; $('hoMsg').textContent = 'saving…';
  try {
    const files = [];
    for (const f of hoFiles) files.push({ name: f.name, size: f.size, data: await fileToDataURL(f) });
    const context = $('hoContext').checked ? { car: S.car, paints: paints().map(rgb2hex), variants: S.variants,
      decal: $('decalSource').value !== 'none' ? $('decalList').selectedOptions[0]?.textContent : null,
      plate: $('plateSource').value !== 'none' ? $('plateList').selectedOptions[0]?.textContent : null,
      glass: $('glassSource').value !== 'none' ? $('glassList').selectedOptions[0]?.textContent : null } : {};
    const r = await api('/api/handoff', { type: $('hoType').value, title: $('hoTitle').value, text: $('hoText').value, files, context });
    $('hoLine').textContent = r.message; $('hoResult').classList.remove('hidden');
    $('hoMsg').innerHTML = '<span class="ok">Saved in ' + r.folder + '</span>';
    hoFiles = []; $('hoFiles').innerHTML = ''; $('hoText').value = ''; $('hoTitle').value = '';
    refreshHandoffs();
  } catch (e) { $('hoMsg').innerHTML = '<span class="bad">' + e.message + '</span>'; }
  $('hoSend').disabled = false;
};
$('hoCopy').onclick = () => { navigator.clipboard.writeText($('hoLine').textContent); $('hoCopy').textContent = 'Copied'; setTimeout(() => { $('hoCopy').textContent = 'Copy'; }, 1500); };
async function refreshHandoffs() {
  const list = await api('/api/handoffs');
  $('hoList').innerHTML = list.length ? list.map(r => `<div class="req"><b>${r.id}</b> ${r.done ? '<span class="done">✔ answered</span>' : '<span class="wait">waiting for Claude</span>'}
    ${r.reply ? '<pre>' + r.reply.replace(/[<&]/g, c => c === '<' ? '&lt;' : '&amp;') + '</pre>' : ''}</div>`).join('') : '<span class="muted">No requests yet.</span>';
}

// ------------------------------------------------------------------ start
(async () => {
  try {
    await initCars();
    // default plate on the car
    const plates = await api('/api/catalog?kind=plate');
    if (plates.length) S.plateDefault = await loadImg('/cache/catalog/plate/' + encodeURIComponent(plates[0].tex) + '.png');
    recompose();
    redrawPlate(); drawGlass();
    await refreshMine();
    await initEffects();
  } catch (e) { status('error: ' + e.message); console.error(e); }
})();
