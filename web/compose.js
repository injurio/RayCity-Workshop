// Run-time car texture, as the game composes it (Data\etc\fx.jmd cartexture.fx; slot rects from 1.627 FUN_00e248c4).
// UV rects are (left, top, right, bottom) with v from the TOP.
'use strict';
const Compose = (() => {
  const SLOT = [
    [0, 0, 1, 0.75], [0.75, 0.75, 1, 0.875], [0, 0.25, 0.125, 0.375],
    [0, 0.75, 0.25, 1], [0, 0.625, 0.125, 0.75], [0, 0, 0.125, 0.125],
    [0, 0.5, 0.125, 0.625], [0, 0.375, 0.125, 0.5], [0, 0.125, 0.0625, 0.1875],
    [0.0625, 0.125, 0.125, 0.1875], [0.5, 0.75, 0.75, 0.875], [0.5, 0.875, 0.75, 1],
    [0.25, 0.75, 0.5, 1], [0.75, 0.875, 1, 1], [0, 0.1875, 0.125, 0.25],
  ];
  const PART_TYPES = ['frontbumper', 'rearbumper', 'mainspoiler', 'lamp', 'skirt', 'roof', 'headlight', 'grill', 'rearlight', 'hood', 'dooropen'];
  const GLASS_SLOT = 2, WHEEL_SLOT = 3, PLATE_SLOT = 13; // plate quads (body rear, front bumper) map slot 13
  const partSlot = f => { const i = PART_TYPES.indexOf(f); return i < 0 ? -1 : i + 4; };

  // image -> {w,h,d: Uint8ClampedArray RGBA}
  function pixels(img) {
    if (!img) return null;
    if (img.d) return img;
    const c = document.createElement('canvas');
    c.width = img.naturalWidth || img.width; c.height = img.naturalHeight || img.height;
    const g = c.getContext('2d'); g.drawImage(img, 0, 0);
    return { w: c.width, h: c.height, d: g.getImageData(0, 0, c.width, c.height).data };
  }
  const at = (p, u, v) => { const x = Math.min(p.w - 1, Math.max(0, (u * p.w) | 0)), y = Math.min(p.h - 1, Math.max(0, (v * p.h) | 0)); return (y * p.w + x) * 4; };

  // opts: {mask, paints:[[r,g,b]x3], decal:{img, custom, colors}, layers:[{img, slot}], plate:img, glass:{img, custom, colors}, size}
  function compose(opts) {
    const N = opts.size || 512;
    const out = new Float32Array(N * N * 3);
    const seam = new Float32Array(N * N).fill(1);
    const alpha = new Float32Array(N * N).fill(1); // glass slot keeps its texel alpha (tint strength) for the viewer
    const mask = pixels(opts.mask);
    const P = opts.paints;
    const dec = opts.decal && opts.decal.img ? pixels(opts.decal.img) : null;
    const dc = opts.decal && opts.decal.colors || [];
    const bodyRows = Math.round(N * 0.75);
    // PixCarBody + PixCarDecal / PixCarDecal3Color over the paint rect (mask and decal 1:1, rows 384..511 unused)
    for (let y = 0; y < bodyRows; y++) for (let x = 0; x < N; x++) {
      const u = (x + 0.5) / N, v = (y + 0.5) / N, o = y * N + x;
      let r = 0, g = 0, b = 0, a = 1;
      if (mask) {
        const i = at(mask, u, v), d = mask.d;
        const m0 = d[i] / 255, m1 = d[i + 1] / 255, m2 = d[i + 2] / 255; a = d[i + 3] / 255;
        r = (m0 * P[0][0] + m1 * P[1][0] + m2 * P[2][0]) * a;
        g = (m0 * P[0][1] + m1 * P[1][1] + m2 * P[2][1]) * a;
        b = (m0 * P[0][2] + m1 * P[1][2] + m2 * P[2][2]) * a;
      }
      seam[o] = a;
      if (dec) {
        const i = at(dec, u, v), d = dec.d;
        let cr, cg, cb, al;
        if (opts.decal.custom) {
          const dr = d[i] / 255 * a, dg = d[i + 1] / 255 * a, db = d[i + 2] / 255 * a;
          const c = k => dc[k] || [0, 0, 0];
          cr = dr * c(0)[0] + dg * c(1)[0] + db * c(2)[0];
          cg = dr * c(0)[1] + dg * c(1)[1] + db * c(2)[1];
          cb = dr * c(0)[2] + dg * c(1)[2] + db * c(2)[2];
          al = Math.min(1, (d[i] + d[i + 1] + d[i + 2]) / 255);
        } else { cr = d[i] * a; cg = d[i + 1] * a; cb = d[i + 2] * a; al = d[i + 3] / 255; }
        r += (cr - r) * al; g += (cg - g) * al; b += (cb - b) * al;
      }
      out[o * 3] = r; out[o * 3 + 1] = g; out[o * 3 + 2] = b;
    }
    // plain glass when no windshield item: dark grey-blue, light tint (slot 2)
    { const [l, t, rr, bb] = SLOT[GLASS_SLOT];
      for (let y = Math.round(t * N); y < Math.round(bb * N); y++) for (let x = Math.round(l * N); x < Math.round(rr * N); x++) {
        const o = y * N + x; out[o * 3] = 22; out[o * 3 + 1] = 28; out[o * 3 + 2] = 36; alpha[o] = 0.45; } }
    const layers = (opts.layers || []).slice();
    if (opts.glass && opts.glass.img) layers.push({ img: opts.glass.img, slot: GLASS_SLOT, tint: opts.glass.custom ? (opts.glass.colors || []) : null });
    if (opts.plate) layers.push({ img: opts.plate, slot: PLATE_SLOT });
    for (const L of layers) {
      const p = pixels(L.img); if (!p) continue;
      const [l, t, rr, bb] = SLOT[L.slot];
      const x0 = Math.round(l * N), x1 = Math.round(rr * N), y0 = Math.round(t * N), y1 = Math.round(bb * N);
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
        const i = at(p, (x + 0.5 - x0) / (x1 - x0), (y + 0.5 - y0) / (y1 - y0)), d = p.d, o = y * N + x;
        let tr = d[i], tg = d[i + 1], tb = d[i + 2], al = L.slot === WHEEL_SLOT ? 1 : d[i + 3] / 255;
        if (L.tint) { // custom glass: channels select colours 1..3
          const c = k => L.tint[k] || [0, 0, 0];
          const R = tr / 255, G = tg / 255, B = tb / 255;
          tr = R * c(0)[0] + G * c(1)[0] + B * c(2)[0]; tg = R * c(0)[1] + G * c(1)[1] + B * c(2)[1]; tb = R * c(0)[2] + G * c(1)[2] + B * c(2)[2];
        }
        const s = seam[o];
        if (L.slot === GLASS_SLOT) { alpha[o] = al; al = 1; }
        out[o * 3] += (tr * s - out[o * 3]) * al; out[o * 3 + 1] += (tg * s - out[o * 3 + 1]) * al; out[o * 3 + 2] += (tb * s - out[o * 3 + 2]) * al;
      }
    }
    const c = document.createElement('canvas'); c.width = c.height = N;
    const g = c.getContext('2d'); const im = g.createImageData(N, N);
    for (let o = 0; o < N * N; o++) { im.data[o * 4] = out[o * 3]; im.data[o * 4 + 1] = out[o * 3 + 1]; im.data[o * 4 + 2] = out[o * 3 + 2]; im.data[o * 4 + 3] = alpha[o] * 255; }
    g.putImageData(im, 0, 0);
    return c;
  }
  return { compose, SLOT, PART_TYPES, partSlot, GLASS_SLOT, WHEEL_SLOT, PLATE_SLOT, pixels };
})();
