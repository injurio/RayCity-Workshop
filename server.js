// RayCity Workshop - local server (no dependencies). Listens on 127.0.0.1 only.
//   node server.js [port]      then open http://127.0.0.1:8765/
// Game files are only read (backend\*.ps1). Everything written goes to workshop\cache, workshop\inbox, workshop\out.
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const ROOT = __dirname;
const PROJECTS = path.resolve(ROOT, '..');   // scanned for <project>\package\Data\car (our own new cars)
const CONFIG = path.join(ROOT, 'workshop.config.json');

// ---- Folders: the client folder (Data\, FileInfo.0m; only read) and JMDReader (JmdLibrary.dll), from workshop.config.json.
// Asked for at every start when not set or gone (backend\setup_paths.ps1); Change_Folders.cmd asks again on purpose.
const readConfig = () => { try { return JSON.parse(fs.readFileSync(CONFIG, 'utf8').replace(/^\uFEFF/, '')); } catch { return {}; } };
const jmdDll = d => d ? ['JmdLibrary.dll', path.join('dist', 'JMDReader', 'JmdLibrary.dll')].map(p => path.join(d, p)).find(p => fs.existsSync(p)) : null;
const folderProblem = c => !c.client || !fs.existsSync(path.join(c.client, 'Data', 'car')) ? 'The client folder is gone: ' + (c.client || '(not set)')
  : !jmdDll(c.jmdreader) ? 'JmdLibrary.dll is gone from: ' + (c.jmdreader || '(not set)') : null;
let CFG = readConfig();
if (folderProblem(CFG)) {
  const r = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'backend', 'setup_paths.ps1')], { stdio: 'inherit' });
  CFG = readConfig();
  if (r.status !== 0 || folderProblem(CFG)) { console.error('RayCity Workshop needs the client folder and the JMDReader folder. Start it again to choose them.'); process.exit(1); }
}
const GAME = path.resolve(CFG.client);
// Decal tool: Ray\decal_tool next to the Workshop when there is one (the original), else the copy inside the Workshop.
const DECAL = fs.existsSync(path.join(PROJECTS, 'decal_tool', 'make_decal.ps1')) ? path.join(PROJECTS, 'decal_tool') : path.join(ROOT, 'decal_tool');
const PORT = Number(process.argv[2]) || Number(process.env.PORT) || 8765;
const CACHE = path.join(ROOT, 'cache');
const INBOX = path.join(ROOT, 'inbox');
const OUT = path.join(ROOT, 'out');
for (const d of [CACHE, INBOX, OUT]) fs.mkdirSync(d, { recursive: true });
// Lists made from another client folder are out of date: rebuild them.
{ const t = path.join(CACHE, 'client.txt'), was = fs.existsSync(t) ? fs.readFileSync(t, 'utf8') : '';
  if (was !== GAME) { fs.rmSync(path.join(CACHE, 'catalog'), { recursive: true, force: true }); fs.writeFileSync(t, GAME); } }

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.png': 'image/png', '.gif': 'image/gif', '.jpg': 'image/jpeg', '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/plain; charset=utf-8', '.svg': 'image/svg+xml', '.dds': 'application/octet-stream' };

const SAFE = /^[\w\-. ]+$/;

// ---- PowerShell runner (one at a time per key, results cached by the scripts themselves)
const running = new Map();
function ps(script, args, key) {
  if (key && running.has(key)) return running.get(key);
  const p = new Promise((resolve, reject) => {
    const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...args], { cwd: ROOT, windowsHide: true });
    let out = '';
    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => { out += d; });
    child.on('close', code => { if (key) running.delete(key); code === 0 ? resolve(out) : reject(new Error(out.trim() || ('exit ' + code))); });
  });
  if (key) running.set(key, p);
  return p;
}
const backend = n => path.join(ROOT, 'backend', n);
const cleanJmd = car => { const p = path.join(OUT, 'carmod', car, 'clean', car + '.jmd'); return fs.existsSync(p) ? p : null; };

// ---- jobs (long tool runs with a live log)
const jobs = new Map();
let jobSeq = 0;
function startJob(title, cmd, args, opts = {}) {
  const id = String(++jobSeq);
  const job = { id, title, log: '', done: false, ok: false, started: Date.now(), result: opts.result || null };
  jobs.set(id, job);
  const child = spawn(cmd, args, { cwd: opts.cwd || ROOT, windowsHide: true });
  const add = d => { job.log += d.toString(); if (job.log.length > 200000) job.log = job.log.slice(-200000); };
  child.stdout.on('data', add); child.stderr.on('data', add);
  child.on('error', e => { add('\n' + e.message); job.done = true; });
  child.on('close', code => { job.done = true; job.ok = code === 0; job.code = code; if (opts.after) try { opts.after(job); } catch (e) { add('\n' + e.message); } });
  return job;
}

// ---- helpers
function send(res, code, body, type) {
  res.writeHead(code, { 'Content-Type': type || 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
}
function sendFile(res, file) {
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) return send(res, 404, { error: 'not found' });
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream', 'Content-Length': st.size, 'Cache-Control': 'no-cache' });
    fs.createReadStream(file).pipe(res);
  });
}
function inside(base, rel) {
  const p = path.resolve(base, rel);
  return p.startsWith(path.resolve(base) + path.sep) || p === path.resolve(base) ? p : null;
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []; let n = 0;
    req.on('data', c => { n += c.length; if (n > 60e6) { reject(new Error('too large')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => { try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); } catch (e) { reject(e); } });
  });
}
function dataUrlToBuffer(s) {
  const m = /^data:[^;]+;base64,(.*)$/s.exec(s || '');
  if (!m) throw new Error('expected a data: URL');
  return Buffer.from(m[1], 'base64');
}
const stamp = () => { const d = new Date(), p = n => String(n).padStart(2, '0'); return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '_' + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds()); };

// ---- API
const api = {
  async 'GET /api/status'() { return { ok: true, client: GAME, jmdreader: CFG.jmdreader, problem: folderProblem(CFG), time: new Date().toISOString() }; },

  async 'GET /api/catalog'(q) {
    const kind = q.get('kind');
    if (!['cars', 'plate', 'glass', 'decal', 'lamp', 'wheel', 'effect'].includes(kind)) throw new Error('bad kind');
    const f = path.join(CACHE, 'catalog', kind + '.json');
    if (!fs.existsSync(f)) await ps(backend('catalog.ps1'), ['-Kind', kind], 'cat:' + kind);
    return JSON.parse(fs.readFileSync(f, 'utf8'));
  },

  async 'GET /api/decaltex'(q) {
    const tex = q.get('tex'), name = q.get('name') || tex;
    if (!SAFE.test(tex) || !SAFE.test(name)) throw new Error('bad name');
    const png = path.join(CACHE, 'catalog', 'decal', tex + '.png');
    if (!fs.existsSync(png)) await ps(backend('catalog.ps1'), ['-Kind', 'decal', '-Tex', tex, '-Name', name], 'dt:' + tex);
    const js = path.join(CACHE, 'catalog', 'decal', tex + '.json');
    return { png: '/cache/catalog/decal/' + encodeURIComponent(tex) + '.png', settings: fs.existsSync(js) ? JSON.parse(fs.readFileSync(js, 'utf8')) : { custom: false } };
  },

  // A game roof accessory's or wheel's mesh + texture (kind=lamp|wheel).
  async 'GET /api/lampmesh'(q) {
    const mesh = q.get('mesh'), tex = q.get('tex'), kind = q.get('kind') || 'lamp';
    if (!SAFE.test(mesh) || !SAFE.test(tex) || !['lamp', 'wheel'].includes(kind)) throw new Error('bad name');
    const d = path.join(CACHE, 'catalog', kind + 'mesh');
    if (!fs.existsSync(path.join(d, mesh + '.json')) || !fs.existsSync(path.join(d, tex + '.png')))
      await ps(backend('export_lamp.ps1'), ['-Mesh', mesh, '-Tex', tex, '-Kind', kind], 'lm:' + kind + ':' + mesh + ':' + tex);
    return { mesh: '/cache/catalog/' + kind + 'mesh/' + encodeURIComponent(mesh) + '.json', png: '/cache/catalog/' + kind + 'mesh/' + encodeURIComponent(tex) + '.png' };
  },

  async 'GET /api/car'(q) {
    const car = q.get('name');
    if (!/^[\w\-]+$/.test(car)) throw new Error('bad car');
    const f = path.join(CACHE, 'cars', car, 'model.json');
    const cars = JSON.parse(fs.readFileSync(path.join(CACHE, 'catalog', 'cars.json'), 'utf8'));
    const row = cars.find(r => r.name === car) || {};
    // a cleaned copy (Reshape > Clean texture) replaces the car everywhere in the workshop until it is undone
    const clean = cleanJmd(car), src = clean || row.path || path.join(GAME, 'Data', 'car', car + '.jmd');
    const tagFile = path.join(CACHE, 'cars', car, 'source.txt'), tag = src + '|' + fs.statSync(src).mtimeMs;
    const stale = fs.existsSync(f) && (!fs.existsSync(tagFile) || fs.readFileSync(tagFile, 'utf8') !== tag); // rebuilt package, cleaned / uncleaned
    if (!fs.existsSync(f) || stale || q.get('refresh')) {
      fs.rmSync(path.join(CACHE, 'cars', car), { recursive: true, force: true });
      await ps(backend('export_car.ps1'), ['-Car', car, ...(src !== path.join(GAME, 'Data', 'car', car + '.jmd') ? ['-Path', src] : [])], 'car:' + car);
      fs.writeFileSync(tagFile, tag);
    }
    const model = JSON.parse(fs.readFileSync(f, 'utf8'));
    model.cleaned = !!clean;
    return model;
  },

  // Files made by the tools (decal_tool\out, workshop\out) for the viewer's "my files" lists.
  async 'GET /api/outputs'() {
    const list = [];
    const dt = path.join(DECAL, 'out');
    if (fs.existsSync(dt)) for (const n of fs.readdirSync(dt)) {
      const png = path.join(dt, n, 'decal_' + n + '.png');
      if (fs.existsSync(png)) {
        const xml = path.join(dt, n, n + '.xml');
        let custom = false; let colors = [];
        if (fs.existsSync(xml)) {
          const x = fs.readFileSync(xml).toString('utf16le');
          custom = /<custom>\s*yes/.test(x);
          colors = [...x.matchAll(/<color\d>\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*<\/color\d>/g)].map(m => [+m[2], +m[3], +m[4]]);
        }
        list.push({ kind: 'decal', name: n, url: '/decalout/' + encodeURIComponent(n) + '/decal_' + encodeURIComponent(n) + '.png', settings: { custom, colors } });
      }
    }
    for (const kind of ['plate', 'glass', 'lamp', 'wheel', 'effect']) {
      const d = path.join(OUT, kind);
      if (!fs.existsSync(d)) continue;
      for (const n of fs.readdirSync(d)) {
        const meta = path.join(d, n, 'meta.json');
        if (fs.existsSync(meta)) list.push(Object.assign({ kind, name: n }, JSON.parse(fs.readFileSync(meta, 'utf8'))));
      }
    }
    return list;
  },

  // Run decal_tool\make_decal.ps1 on an uploaded picture.
  async 'POST /api/decal'(q, body) {
    const name = String(body.name || '');
    if (!/^[a-z0-9_]{2,40}$/.test(name)) throw new Error('Name: 2-40 lowercase letters, digits or _');
    const ext = (/^data:image\/(png|jpeg|gif|bmp)/.exec(body.image || '') || [])[1];
    if (!ext) throw new Error('Picture must be PNG, JPG, GIF or BMP');
    const upDir = path.join(INBOX, 'uploads'); fs.mkdirSync(upDir, { recursive: true });
    const img = path.join(upDir, name + '_' + stamp() + '.' + (ext === 'jpeg' ? 'jpg' : ext));
    fs.writeFileSync(img, dataUrlToBuffer(body.image));
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(DECAL, 'make_decal.ps1'), '-Image', img, '-Name', name];
    const o = body.options || {};
    if (['sides', 'top', 'sides+top', 'wrap', 'raw'].includes(o.layout)) args.push('-Layout', o.layout);
    if (o.scale !== undefined) args.push('-Scale', String(Math.max(0.05, Math.min(1, +o.scale))));
    if (o.pos !== undefined) args.push('-Pos', String(Math.max(0, Math.min(1, +o.pos))));
    if (o.mirror) args.push('-Mirror');
    if (o.removeBg) args.push('-RemoveBg');
    if (o.recolor) args.push('-Recolor');
    if (o.recolor && /^\d+,\d+,\d+;\d+,\d+,\d+;\d+,\d+,\d+$/.test(o.colors || '')) args.push('-Colors', o.colors);
    if (Number.isInteger(o.frame) && o.frame > 0) args.push('-Frame', String(o.frame));
    if (o.preview === false) args.push('-NoPreview');
    else if (/^[\w,\-]+$/.test(o.cars || '')) args.push('-Cars', o.cars);
    return startJob('decal ' + name, 'powershell.exe', args, { cwd: DECAL });
  },

  async 'POST /api/decal/package'(q, body) {
    const names = (body.names || []).filter(n => /^[a-z0-9_]{2,40}$/.test(n));
    if (!names.length) throw new Error('No decals chosen');
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(DECAL, 'make_package.ps1'), '-Names', names.join(',')];
    return startJob('decal package', 'powershell.exe', args, { cwd: DECAL });
  },

  // Plate / glass maker: the browser sends the finished textures; backend\make_item.ps1 writes game files.
  async 'POST /api/item'(q, body) {
    const kind = body.kind;
    if (!['plate', 'glass'].includes(kind)) throw new Error('bad kind');
    const name = String(body.name || '');
    if (!/^[a-z0-9_]{2,40}$/.test(name)) throw new Error('Name: 2-40 lowercase letters, digits or _');
    const dir = path.join(OUT, kind, name); fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'texture.png'), dataUrlToBuffer(body.texture));
    fs.writeFileSync(path.join(dir, 'icon.png'), dataUrlToBuffer(body.icon));
    if (body.source) fs.writeFileSync(path.join(dir, 'source.png'), dataUrlToBuffer(body.source));
    const settings = body.settings || { custom: false };
    fs.writeFileSync(path.join(dir, 'request.json'), JSON.stringify({ kind, name, settings }, null, 2));
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', backend('make_item.ps1'), '-Kind', kind, '-Name', name];
    return startJob(kind + ' ' + name, 'powershell.exe', args);
  },

  async 'POST /api/item/package'(q, body) {
    const kind = body.kind;
    if (!['plate', 'glass', 'lamp', 'wheel'].includes(kind)) throw new Error('bad kind');
    const names = (body.names || []).filter(n => /^[a-z0-9_]{2,40}$/.test(n));
    if (!names.length) throw new Error('Nothing chosen');
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', backend('package_items.ps1'), '-Kind', kind, '-Names', names.join(',')];
    return startJob(kind + ' package', 'powershell.exe', args);
  },

  // Roof accessory: OBJ + texture -> out\lamp\<name>\ (backend\make_lamp.ps1).
  async 'POST /api/lamp'(q, body) {
    const name = String(body.name || '');
    if (!/^[a-z0-9_]{2,40}$/.test(name)) throw new Error('Name: 2-40 lowercase letters, digits or _');
    const dir = path.join(OUT, 'lamp', name); fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'model.obj'), String(body.obj || ''), 'utf8');
    fs.writeFileSync(path.join(dir, 'texture.png'), dataUrlToBuffer(body.texture));
    fs.writeFileSync(path.join(dir, 'icon.png'), dataUrlToBuffer(body.icon));
    fs.writeFileSync(path.join(dir, 'request.json'), JSON.stringify({ name, effect: body.effect || '', transform: body.transform || null }, null, 2));
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', backend('make_lamp.ps1'), '-Name', name];
    return startJob('roof ' + name, 'powershell.exe', args);
  },

  // Wheel: repaint of a game rim or an OBJ rim + 128x128 texture -> out\wheel\<name>\ (backend\make_wheel.ps1).
  async 'POST /api/wheel'(q, body) {
    const name = String(body.name || '');
    if (!/^[a-z0-9_]{2,36}$/.test(name)) throw new Error('Name: 2-36 lowercase letters, digits or _');
    const mode = body.mode === 'obj' ? 'obj' : 'repaint';
    if (mode === 'repaint' && !SAFE.test(body.baseMesh || '')) throw new Error('Pick the game wheel to repaint');
    if (mode === 'obj' && !body.obj) throw new Error('Drop an OBJ first');
    const dir = path.join(OUT, 'wheel', name);
    fs.rmSync(dir, { recursive: true, force: true }); fs.mkdirSync(dir, { recursive: true });
    if (mode === 'obj') fs.writeFileSync(path.join(dir, 'model.obj'), String(body.obj), 'utf8');
    fs.writeFileSync(path.join(dir, 'texture.png'), dataUrlToBuffer(body.texture));
    fs.writeFileSync(path.join(dir, 'icon.png'), dataUrlToBuffer(body.icon));
    fs.writeFileSync(path.join(dir, 'request.json'), JSON.stringify({ name, mode, baseMesh: body.baseMesh || '', transform: body.transform || null }, null, 2));
    return startJob('wheel ' + name, 'powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', backend('make_wheel.ps1'), '-Name', name]);
  },

  // Set effects: one relement file of the game (cache\effects\) or of one of ours (out\effect\<name>\preview\) for the viewer.
  async 'GET /api/effectfile'(q) {
    const file = q.get('file'), mine = q.get('mine');
    if (!/^[\w\-]+$/.test(file || '') || (mine && !/^[a-z0-9_]{2,30}$/.test(mine))) throw new Error('bad name');
    const key = file.toLowerCase();
    if (mine) {
      const f = path.join(OUT, 'effect', mine, 'preview', key + '.json');
      if (fs.existsSync(f)) return { url: '/out/effect/' + mine + '/preview/' + key + '.json', tex: '/out/effect/' + mine + '/preview/tex/' };
    }
    const f = path.join(CACHE, 'effects', key + '.json');
    if (!fs.existsSync(f)) await ps(backend('export_effect.ps1'), ['-File', file], 'fx:' + key);
    return { url: '/cache/effects/' + key + '.json', tex: '/cache/effects/tex/' };
  },

  // New set effect: a game scene effect with some textures replaced -> out\effect\<name>\ (backend\make_effect.ps1).
  async 'POST /api/effect'(q, body) {
    const name = String(body.name || '');
    if (!/^[a-z0-9_]{2,30}$/.test(name)) throw new Error('Name: 2-30 lowercase letters, digits or _');
    if (!/^[\w\-]+$/.test(body.template || '')) throw new Error('Pick the effect to start from');
    const tex = body.textures || {};
    if (!Object.keys(tex).length) throw new Error('Change at least one texture (recolour or picture)');
    const dir = path.join(OUT, 'effect', name);
    fs.rmSync(dir, { recursive: true, force: true }); fs.mkdirSync(path.join(dir, 'tex'), { recursive: true });
    const map = {};
    for (const [t, data] of Object.entries(tex)) {
      if (!/^[\w\-]+$/.test(t)) throw new Error('bad texture name ' + t);
      fs.writeFileSync(path.join(dir, 'tex', t + '.png'), dataUrlToBuffer(data)); map[t] = t + '.png';
    }
    fs.writeFileSync(path.join(dir, 'request.json'), JSON.stringify({ name, template: body.template, textures: map }, null, 2));
    return startJob('effect ' + name, 'powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', backend('make_effect.ps1'), '-Name', name]);
  },

  async 'POST /api/effect/package'(q, body) {
    const names = (body.names || []).filter(n => /^[a-z0-9_]{2,30}$/.test(n));
    if (!names.length) throw new Error('Nothing chosen');
    return startJob('effect package', 'powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', backend('package_effect.ps1'), '-Names', names.join(',')]);
  },

  // Map tiles: Data\field\<area>\<area>_XXXX_YYYY.jmd (tile XXXX covers x = (XXXX - 1000) * 512 m ... + 512 m).
  async 'GET /api/maps'() {
    const field = path.join(GAME, 'Data', 'field');
    return fs.readdirSync(field).filter(a => !a.startsWith('common') && fs.statSync(path.join(field, a)).isDirectory()).map(area => {
      const re = /^([a-z0-9]+)_([0-9]{4})_([0-9]{4})[.]jmd$/i;
      const tiles = fs.readdirSync(path.join(field, area)).map(f => re.exec(f)).filter(m => m && m[1].toLowerCase() === area.toLowerCase()).map(m => [+m[2], +m[3]]);
      return { area, tiles };
    }).filter(a => a.tiles.length);
  },

  async 'GET /api/tile'(q) {
    const area = q.get('area'), tile = q.get('tile');
    if (!/^[a-z0-9_]+$/.test(area || '') || !/^[a-z0-9_]+$/.test(tile || '')) throw new Error('bad tile');
    const f = path.join(CACHE, 'map', area, tile + '.json');
    if (!fs.existsSync(f)) await ps(backend('export_tile.ps1'), ['-Area', area, '-Tile', tile], 'tile:' + tile);
    const base = '/cache/map/' + area + '/';
    return { mesh: base + tile + '.json', objects: base + tile + '_objects.json', tex: base + 'tex/' };
  },

  // Reshape: sculpted LOD-2 positions (base64 float32) -> backend\reshape.ps1 (all LODs, package). Saved request stays in
  // out\carmod\<car>\request.json so the page can load the edits again.
  async 'POST /api/reshape'(q, body) {
    const car = String(body.car || '');
    if (!/^[\w\-]+$/.test(car)) throw new Error('bad car');
    const cars = JSON.parse(fs.readFileSync(path.join(CACHE, 'catalog', 'cars.json'), 'utf8'));
    const row = cars.find(r => r.name === car) || {};
    const edits = (body.edits || []).filter(e => /^(body|big|[\w\-]+\/[\w\-.]+)$/.test(e.file || '') && typeof e.pos === 'string');
    const sets = (body.sets || []).filter(s => /^[\w\-]+$/.test(s.folder || '') && /^[a-z0-9_]{2,30}$/.test(s.name || '') && typeof s.pos === 'string');
    if (!edits.length && !sets.length) throw new Error('Nothing changed yet');
    const dir = path.join(OUT, 'carmod', car); fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'request.json'), JSON.stringify({ car, source: cleanJmd(car) || row.path || '', edits, sets }));
    return startJob('reshape ' + car, 'powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', backend('reshape.ps1'), '-Car', car]);
  },

  // Clean texture ("broken pixel" cars): backend\clean_texture.ps1 -> out\carmod\<car>\clean\<car>.jmd + package.
  async 'POST /api/clean'(q, body) {
    const car = String(body.car || '');
    if (!/^[\w\-]+$/.test(car)) throw new Error('bad car');
    const cars = JSON.parse(fs.readFileSync(path.join(CACHE, 'catalog', 'cars.json'), 'utf8'));
    const row = cars.find(r => r.name === car) || {};
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', backend('clean_texture.ps1'), '-Car', car,
      '-Colors', String(Math.max(4, Math.min(32, body.colors | 0 || 16))), '-Mask', body.mask ? '1' : '0', '-Specks', body.specks === false ? '0' : '1', '-Detail', String(Math.max(0, Math.min(3, body.detail === undefined ? 2 : body.detail | 0)))];
    if (row.path) args.push('-Source', row.path);
    return startJob('clean ' + car, 'powershell.exe', args);
  },
  async 'POST /api/clean/undo'(q, body) {
    const car = String(body.car || '');
    if (!/^[\w\-]+$/.test(car)) throw new Error('bad car');
    fs.rmSync(path.join(OUT, 'carmod', car, 'clean'), { recursive: true, force: true });
    return { ok: true };
  },
  async 'GET /api/clean'(q) {
    const car = q.get('car');
    if (!/^[\w\-]+$/.test(car || '')) throw new Error('bad car');
    const r = path.join(OUT, 'carmod', car, 'clean', 'report.json');
    return cleanJmd(car) && fs.existsSync(r) ? Object.assign({ cleaned: true }, JSON.parse(fs.readFileSync(r, 'utf8'))) : { cleaned: false };
  },

  async 'GET /api/job'(q) {
    const j = jobs.get(q.get('id'));
    if (!j) throw new Error('no such job');
    return j;
  },

  // Import / hand-off: save the request + files for Claude, return the line to paste.
  async 'POST /api/handoff'(q, body) {
    const text = String(body.text || '').trim();
    if (!text) throw new Error('Write what you want done');
    const id = stamp() + '_' + (String(body.title || 'request').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 30) || 'request');
    const dir = path.join(INBOX, id); fs.mkdirSync(dir, { recursive: true });
    const saved = [];
    for (const f of body.files || []) {
      const n = path.basename(String(f.name || 'file')).replace(/[^\w\-. ]/g, '_');
      fs.writeFileSync(path.join(dir, n), dataUrlToBuffer(f.data));
      saved.push({ name: n, size: f.size || 0 });
    }
    const md = ['# Workshop request ' + id, '', '- Type: ' + (body.type || 'other'), '- Created: ' + new Date().toString(), '',
      '## What I want', '', text, '', '## Files', '', ...(saved.length ? saved.map(f => '- `' + f.name + '`') : ['(none)']), '',
      '## Context from the workshop', '', '```json', JSON.stringify(body.context || {}, null, 2), '```', ''].join('\n');
    fs.writeFileSync(path.join(dir, 'request.md'), md, 'utf8');
    const rel = path.join(path.basename(PROJECTS), path.relative(PROJECTS, dir));
    return { id, folder: dir, message: 'Workshop request: please read ' + path.join(rel, 'request.md') + ' and do it.' };
  },

  async 'GET /api/handoffs'() {
    return fs.readdirSync(INBOX).filter(n => fs.existsSync(path.join(INBOX, n, 'request.md'))).sort().reverse().map(n => {
      const done = fs.existsSync(path.join(INBOX, n, 'reply.md'));
      return { id: n, done, reply: done ? fs.readFileSync(path.join(INBOX, n, 'reply.md'), 'utf8') : '' };
    });
  },
};

// ---- static routes
function staticRoute(p, res) {
  if (p === '/') p = '/index.html';
  if (p.startsWith('/cache/')) { const f = inside(CACHE, decodeURIComponent(p.slice(7))); return f ? sendFile(res, f) : send(res, 403, {}); }
  if (p.startsWith('/out/')) { const f = inside(OUT, decodeURIComponent(p.slice(5))); return f ? sendFile(res, f) : send(res, 403, {}); }
  if (p.startsWith('/decalout/')) { const f = inside(path.join(DECAL, 'out'), decodeURIComponent(p.slice(10))); return f ? sendFile(res, f) : send(res, 403, {}); }
  if (p.startsWith('/decaltool/')) { const f = inside(DECAL, decodeURIComponent(p.slice(11))); return f ? sendFile(res, f) : send(res, 403, {}); }
  const f = inside(path.join(ROOT, 'web'), decodeURIComponent(p.slice(1)));
  return f ? sendFile(res, f) : send(res, 403, {});
}

// The car list is rebuilt at every start so new project cars (<project>\package\Data\car) show up.
ps(backend('catalog.ps1'), ['-Kind', 'cars'], 'cat:cars').then(() => console.log('car list ready'), e => console.error('car list: ' + e.message));

http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1');
  const h = api[req.method + ' ' + u.pathname];
  const gone = u.pathname.startsWith('/api/') && u.pathname !== '/api/status' && folderProblem(CFG);
  if (gone) return send(res, 503, { error: gone + '. Close the Workshop window and start it again to choose it.' });
  if (!h) return req.method === 'GET' ? staticRoute(u.pathname, res) : send(res, 404, { error: 'no route' });
  try {
    const body = req.method === 'POST' ? await readBody(req) : null;
    send(res, 200, await h(u.searchParams, body));
  } catch (e) {
    send(res, 400, { error: e.message });
  }
}).listen(PORT, '127.0.0.1', () => (process.argv.includes('--open') && spawn('cmd.exe', ['/c', 'start', '', 'http://127.0.0.1:' + PORT + '/'], { detached: true, stdio: 'ignore' }).unref(), console.log('RayCity Workshop: http://127.0.0.1:' + PORT + '/\nClient folder: ' + GAME + '\nJMDReader: ' + CFG.jmdreader)));
