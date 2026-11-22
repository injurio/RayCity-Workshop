// Small WebGL1 viewer for RayCity car meshes (Z up, car front = -Y, 1 unit = 1 m). No libraries.
'use strict';
class Viewer {
  constructor(canvas) {
    this.canvas = canvas;
    const gl = canvas.getContext('webgl', { antialias: true, preserveDrawingBuffer: true, alpha: false });
    if (!gl) throw new Error('WebGL is not available');
    this.gl = gl;
    gl.getExtension('OES_element_index_uint');
    this.prog = this._program(Viewer.VS, Viewer.FS);
    this.loc = {};
    for (const n of ['aPos', 'aNor', 'aUv']) this.loc[n] = gl.getAttribLocation(this.prog, n);
    for (const n of ['uMvp', 'uModel', 'uTex', 'uMode', 'uTint', 'uEye', 'uAlpha', 'uGlow', 'uLm', 'uFog', 'uLook', 'uLights']) this.loc[n] = gl.getUniformLocation(this.prog, n);
    this.loc.aUv2 = gl.getAttribLocation(this.prog, 'aUv2');
    this.objects = [];
    this.textures = new Map();
    this.yaw = -2.35; this.pitch = 0.32; this.dist = 6.2; this.target = [0, 0, 0.62];
    this.autoRotate = false; this.glow = 0; this.showGrid = true;
    this.minDist = 1.5; this.maxDist = 25; this.far = 100; this.fog = [10, 30]; this.home = { target: [0, 0, 0.62], dist: 6.2 };
    this.onFrame = null; // (seconds) => void, before each draw (effect players)
    this.look = 0; this.lights = 0; this.freezeGlow = false; this._glowT = 0;
    this.tool = null; // {down(e), move(e), up(e), hover(e)}: left-drag goes to the tool instead of turning the view
    this._ident = new Float32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
    this._grid = this._makeGrid();
    this._input();
    this._t0 = performance.now();
    const loop = () => { this._frame(); requestAnimationFrame(loop); };
    requestAnimationFrame(loop);
  }

  _program(vs, fs) {
    const gl = this.gl;
    const sh = (t, s) => { const o = gl.createShader(t); gl.shaderSource(o, s); gl.compileShader(o); if (!gl.getShaderParameter(o, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(o)); return o; };
    const p = gl.createProgram();
    gl.attachShader(p, sh(gl.VERTEX_SHADER, vs)); gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    return p;
  }

  // source: canvas or image. Returns a GL texture (cached per source object).
  texture(src) {
    const gl = this.gl;
    let t = this.textures.get(src);
    if (!t) { t = gl.createTexture(); this.textures.set(src, t); }
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, src);
    const pot = (src.width & (src.width - 1)) === 0 && (src.height & (src.height - 1)) === 0;
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, pot ? gl.LINEAR_MIPMAP_LINEAR : gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    if (pot) gl.generateMipmap(gl.TEXTURE_2D);
    return t;
  }
  dropTexture(src) { const t = this.textures.get(src); if (t) { this.gl.deleteTexture(t); this.textures.delete(src); } }

  // mesh JSON from backend\common.ps1 -> GPU buffers. matrix: optional 3x4 row-major (game mount format).
  upload(mesh, matrix) {
    const gl = this.gl;
    let pos = mesh.positions, nor = mesh.normals;
    if (matrix) {
      const m = matrix; pos = new Array(pos.length); nor = new Array(mesh.normals.length);
      for (let i = 0; i < mesh.positions.length; i += 3) {
        const x = mesh.positions[i], y = mesh.positions[i + 1], z = mesh.positions[i + 2];
        pos[i] = m[0] * x + m[1] * y + m[2] * z + m[3]; pos[i + 1] = m[4] * x + m[5] * y + m[6] * z + m[7]; pos[i + 2] = m[8] * x + m[9] * y + m[10] * z + m[11];
      }
      for (let i = 0; i < mesh.normals.length; i += 3) {
        const x = mesh.normals[i], y = mesh.normals[i + 1], z = mesh.normals[i + 2];
        nor[i] = m[0] * x + m[1] * y + m[2] * z; nor[i + 1] = m[4] * x + m[5] * y + m[6] * z; nor[i + 2] = m[8] * x + m[9] * y + m[10] * z;
      }
    }
    const buf = (data, T) => { const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b); gl.bufferData(gl.ARRAY_BUFFER, new T(data), gl.STATIC_DRAW); return b; };
    const vcount = pos.length / 3;
    const g = { pos: buf(pos, Float32Array), nor: buf(nor.length === pos.length ? nor : new Array(pos.length).fill(0), Float32Array),
      uv: buf(mesh.uvs.length === vcount * 2 ? mesh.uvs : new Array(vcount * 2).fill(0), Float32Array), parts: [] };
    if (mesh.uvs2 && mesh.uvs2.length === vcount * 2) g.uv2 = buf(mesh.uvs2, Float32Array);
    let lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9];
    for (let i = 0; i < pos.length; i += 3) for (let k = 0; k < 3; k++) { lo[k] = Math.min(lo[k], pos[i + k]); hi[k] = Math.max(hi[k], pos[i + k]); }
    g.bounds = [lo, hi];
    for (const p of mesh.parts) {
      if (!p.indices.length) continue;
      const ib = gl.createBuffer(); gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ib);
      gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint32Array(p.indices), gl.STATIC_DRAW);
      g.parts.push({ ib, count: p.indices.length, group: p.group, cat: p.cat, name: p.name, mat: p.mat });
    }
    return g;
  }
  free(g) { const gl = this.gl; if (!g) return; if (g.uv2) gl.deleteBuffer(g.uv2); gl.deleteBuffer(g.pos); gl.deleteBuffer(g.nor); gl.deleteBuffer(g.uv); for (const p of g.parts) gl.deleteBuffer(p.ib); }

  // objects: [{geo, tex (canvas/img), kind: 'car'|'wheels'|'own', glow}]
  setObjects(list) { this.objects = list; }

  view(name) {
    const v = { front34: [-2.35, 0.3], rear34: [0.8, 0.3], side: [0, 0.05], front: [-1.5708, 0.08], rear: [1.5708, 0.08], top: [0, 1.45] }[name]; // eye at (cos yaw, sin yaw); car front = -Y
    if (v) { this.yaw = v[0]; this.pitch = v[1]; }
  }

  _input() {
    const c = this.canvas; let drag = null;
    c.addEventListener('pointerdown', e => {
      drag = { x: e.clientX, y: e.clientY, b: e.button, shift: e.shiftKey, tool: !!(this.tool && e.button === 0 && !e.shiftKey && !e.altKey) };
      c.setPointerCapture(e.pointerId);
      if (drag.tool) this.tool.down(e);
    });
    c.addEventListener('pointerup', e => { if (drag && drag.tool) this.tool.up(e); drag = null; });
    c.addEventListener('pointermove', e => {
      if (!drag) { if (this.tool && this.tool.hover) this.tool.hover(e); return; }
      if (drag.tool) { this.tool.move(e); return; }
      const dx = e.clientX - drag.x, dy = e.clientY - drag.y; drag.x = e.clientX; drag.y = e.clientY;
      if (drag.b === 1 || drag.shift || (drag.b === 2 && !this.tool)) { // with a tool active, right-drag turns and shift-drag moves
        const s = this.dist * 0.0016, cy = Math.cos(this.yaw), sy = Math.sin(this.yaw);
        this.target[0] -= (-sy * dx) * s; this.target[1] -= (cy * dx) * s; this.target[2] += dy * s;
      } else { this.yaw -= dx * 0.008; this.pitch = Math.max(-0.2, Math.min(1.5, this.pitch + dy * 0.006)); }
    });
    c.addEventListener('wheel', e => { e.preventDefault(); this.dist = Math.max(this.minDist, Math.min(this.maxDist, this.dist * Math.exp(e.deltaY * 0.001))); }, { passive: false });
    c.addEventListener('contextmenu', e => e.preventDefault());
    c.addEventListener('dblclick', () => { this.target = this.home.target.slice(); this.dist = this.home.dist; });
  }

  // World-space ray through a point of the canvas (client coordinates): {o, d}
  ray(clientX, clientY) {
    const r = this.canvas.getBoundingClientRect(), x = ((clientX - r.left) / r.width) * 2 - 1, y = 1 - ((clientY - r.top) / r.height) * 2;
    const v = this.viewM, t = Math.tan(0.62 / 2), asp = r.width / r.height;
    const right = [v[0], v[4], v[8]], up = [v[1], v[5], v[9]], back = [v[2], v[6], v[10]];
    const d = [0, 1, 2].map(k => right[k] * x * t * asp + up[k] * y * t - back[k]);
    const l = Math.hypot(d[0], d[1], d[2]);
    return { o: this.eye.slice(), d: d.map(q => q / l) };
  }
  // Replace a geo's positions / normals in place (same vertex count), e.g. while sculpting.
  updateGeo(g, positions, normals) {
    const gl = this.gl;
    gl.bindBuffer(gl.ARRAY_BUFFER, g.pos); gl.bufferSubData(gl.ARRAY_BUFFER, 0, positions instanceof Float32Array ? positions : new Float32Array(positions));
    if (normals) { gl.bindBuffer(gl.ARRAY_BUFFER, g.nor); gl.bufferSubData(gl.ARRAY_BUFFER, 0, normals instanceof Float32Array ? normals : new Float32Array(normals)); }
  }

  _makeGrid() {
    const gl = this.gl, L = [];
    for (let i = -6; i <= 6; i++) { L.push(i * 0.5, -3, 0, i * 0.5, 3, 0, -3, i * 0.5, 0, 3, i * 0.5, 0); }
    const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(L), gl.STATIC_DRAW);
    return { b, n: L.length / 3 };
  }

  _matrices() {
    const w = this.canvas.width, h = this.canvas.height;
    const cp = Math.cos(this.pitch), eye = [this.target[0] + this.dist * cp * Math.cos(this.yaw), this.target[1] + this.dist * cp * Math.sin(this.yaw), this.target[2] + this.dist * Math.sin(this.pitch)];
    const view = M4.lookAt(eye, this.target, [0, 0, 1]);
    const proj = M4.perspective(0.62, w / h, this.far > 1000 ? 1 : 0.05, this.far);
    this.eye = eye; this.viewM = view;
    return { mvp: M4.mul(proj, view), eye };
  }

  // Object kinds: 'car' / 'wheels' / 'own' (shaded, glass parts blended), 'fx' (effect plane: additive glow, o.model
  // 4x4 column-major, o.alpha), 'map' (map tile: o.mats[part.mat] = {tex, lm}, o.lmMode 0 base / 1 base x lightmap / 2 lightmap).
  _frame() {
    const gl = this.gl, c = this.canvas;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const W = Math.max(1, Math.round(c.clientWidth * dpr)), H = Math.max(1, Math.round(c.clientHeight * dpr));
    if (c.width !== W || c.height !== H) { c.width = W; c.height = H; }
    if (!c.clientWidth) return;
    if (this.autoRotate) this.yaw += 0.004;
    const t = (performance.now() - this._t0) / 1000;
    gl.viewport(0, 0, W, H);
    gl.clearColor(0.055, 0.063, 0.082, 1); gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.enable(gl.DEPTH_TEST); gl.disable(gl.CULL_FACE);
    gl.useProgram(this.prog);
    const { mvp, eye } = this._matrices();
    if (this.onFrame) try { this.onFrame(t); } catch (e) { console.error(e); this.onFrame = null; }
    gl.uniformMatrix4fv(this.loc.uMvp, false, mvp);
    gl.uniformMatrix4fv(this.loc.uModel, false, this._ident);
    gl.uniform3fv(this.loc.uEye, eye);
    gl.uniform2f(this.loc.uFog, this.fog[0], this.fog[1]);
    gl.uniform1i(this.loc.uTex, 0); gl.uniform1i(this.loc.uLm, 1);
    gl.uniform1i(this.loc.uLook, this.look); gl.uniform1f(this.loc.uLights, this.lights);
    if (!this.freezeGlow) this._glowT = t;
    if (this.loc.aUv2 >= 0) { gl.disableVertexAttribArray(this.loc.aUv2); gl.vertexAttrib2f(this.loc.aUv2, 0, 0); }
    if (this.showGrid) {
      gl.bindBuffer(gl.ARRAY_BUFFER, this._grid.b);
      gl.enableVertexAttribArray(this.loc.aPos); gl.vertexAttribPointer(this.loc.aPos, 3, gl.FLOAT, false, 0, 0);
      gl.disableVertexAttribArray(this.loc.aNor); gl.vertexAttrib3f(this.loc.aNor, 0, 0, 1);
      gl.disableVertexAttribArray(this.loc.aUv); gl.vertexAttrib2f(this.loc.aUv, 0, 0);
      gl.uniform1i(this.loc.uMode, 9); gl.uniform4f(this.loc.uTint, 0.16, 0.19, 0.25, 1); gl.uniform1f(this.loc.uAlpha, 1);
      gl.drawArrays(gl.LINES, 0, this._grid.n);
    }
    const bindTex = (unit, src) => { gl.activeTexture(gl.TEXTURE0 + unit); gl.bindTexture(gl.TEXTURE_2D, src ? (this.textures.get(src) || this.texture(src)) : this._white()); };
    // pass 0 opaque, 1 glass (blended), 2 effects (additive, no depth write)
    for (const pass of [0, 1, 2]) {
      if (pass === 1) { gl.enable(gl.BLEND); gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA); gl.depthMask(false); }
      if (pass === 2) { gl.blendFunc(gl.SRC_ALPHA, gl.ONE); }
      for (const o of this.objects) {
        if (!o.geo || o.hidden) continue;
        const fx = o.kind === 'fx';
        if (fx !== (pass === 2)) continue;
        const g = o.geo;
        gl.bindBuffer(gl.ARRAY_BUFFER, g.pos); gl.enableVertexAttribArray(this.loc.aPos); gl.vertexAttribPointer(this.loc.aPos, 3, gl.FLOAT, false, 0, 0);
        gl.bindBuffer(gl.ARRAY_BUFFER, g.nor); gl.enableVertexAttribArray(this.loc.aNor); gl.vertexAttribPointer(this.loc.aNor, 3, gl.FLOAT, false, 0, 0);
        gl.bindBuffer(gl.ARRAY_BUFFER, g.uv); gl.enableVertexAttribArray(this.loc.aUv); gl.vertexAttribPointer(this.loc.aUv, 2, gl.FLOAT, false, 0, 0);
        if (g.uv2 && this.loc.aUv2 >= 0) { gl.bindBuffer(gl.ARRAY_BUFFER, g.uv2); gl.enableVertexAttribArray(this.loc.aUv2); gl.vertexAttribPointer(this.loc.aUv2, 2, gl.FLOAT, false, 0, 0); }
        else if (this.loc.aUv2 >= 0) { gl.disableVertexAttribArray(this.loc.aUv2); gl.vertexAttrib2f(this.loc.aUv2, 0, 0); }
        gl.uniformMatrix4fv(this.loc.uModel, false, o.model || this._ident);
        if (o.kind !== 'map') bindTex(0, o.tex);
        for (const p of g.parts) {
          let mode = 0, alpha = 1, glow = 0;
          if (fx) { mode = 5; alpha = o.alpha === undefined ? 1 : o.alpha; }
          else if (o.kind === 'map') {
            if (pass !== 0) continue;
            const m = (o.mats && o.mats[p.mat]) || {};
            bindTex(0, m.tex); bindTex(1, m.lm);
            mode = 6; glow = o.lmMode === undefined ? 1 : o.lmMode; alpha = m.lm ? 1 : 0; // alpha = has a lightmap
          } else {
            const glass = o.kind !== 'own' && p.group === 1;
            if ((pass === 1) !== glass) continue;
            if (glass) { mode = 1; alpha = 0.62; }
            else if (o.kind === 'wheels' && p.name.startsWith('tyre')) mode = 2;
            else if (o.kind !== 'own' && (p.group === 3 || p.group === 4)) mode = 3;
            if (o.kind === 'own') { mode = 4; glow = o.glow ? (0.5 + 0.5 * Math.sin(this._glowT * 6.0)) * o.glow : 0; }
          }
          gl.uniform1i(this.loc.uMode, mode); gl.uniform1f(this.loc.uAlpha, alpha); gl.uniform1f(this.loc.uGlow, glow);
          const tint = o.tint || [1, 1, 1];
          gl.uniform4f(this.loc.uTint, tint[0], tint[1], tint[2], 1);
          gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, p.ib);
          gl.drawElements(gl.TRIANGLES, p.count, gl.UNSIGNED_INT, 0);
        }
      }
    }
    gl.disable(gl.BLEND); gl.depthMask(true); gl.activeTexture(gl.TEXTURE0);
  }
  _white() {
    if (!this._whiteTex) {
      const gl = this.gl; this._whiteTex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, this._whiteTex);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([200, 200, 200, 255]));
    }
    return this._whiteTex;
  }

  screenshot() { return this.canvas.toDataURL('image/png'); }
}

Viewer.VS = `
attribute vec3 aPos; attribute vec3 aNor; attribute vec2 aUv; attribute vec2 aUv2;
uniform mat4 uMvp; uniform mat4 uModel; varying vec3 vN; varying vec2 vUv; varying vec2 vUv2; varying vec3 vP;
void main(){ vec4 w=uModel*vec4(aPos,1.0); vN=mat3(uModel[0].xyz,uModel[1].xyz,uModel[2].xyz)*aNor; vUv=aUv; vUv2=aUv2; vP=w.xyz; gl_Position=uMvp*w; }`;
Viewer.FS = `
precision mediump float;
varying vec3 vN; varying vec2 vUv; varying vec2 vUv2; varying vec3 vP;
uniform sampler2D uTex; uniform sampler2D uLm; uniform int uMode; uniform vec4 uTint; uniform vec3 uEye; uniform float uAlpha; uniform float uGlow; uniform vec2 uFog; uniform int uLook; uniform float uLights;
void main(){
  if(uMode==9){ float d=length(vP.xy); gl_FragColor=vec4(uTint.rgb, 1.0)*(1.0-smoothstep(1.8,3.0,d)) + vec4(0.055,0.063,0.082,1.0)*smoothstep(1.8,3.0,d); return; }
  vec4 tx=texture2D(uTex,vUv);
  if(uMode==5){ gl_FragColor=vec4(tx.rgb*uTint.rgb, tx.a*uAlpha); return; }
  float fog=smoothstep(uFog.x,uFog.y,length(uEye-vP));
  if(uMode==6){
    if(tx.a<0.45) discard;
    vec3 lm=texture2D(uLm,vUv2).rgb;
    vec3 shade=vec3(0.5+0.5*abs(normalize(vN).z));
    vec3 col = uGlow<0.5 ? tx.rgb*shade : (uGlow<1.5 ? (uAlpha>0.5 ? tx.rgb*lm*2.0 : tx.rgb*shade) : (uAlpha>0.5 ? lm : shade*0.6));
    gl_FragColor=vec4(mix(col,vec3(0.055,0.063,0.082),fog),1.0); return;
  }
  vec3 n=normalize(vN); vec3 v=normalize(uEye-vP);
  if(length(vN)<0.01) n=v;
  if(dot(n,v)<0.0) n=-n;
  vec3 L1=normalize(vec3(-0.45,-0.6,0.75)), L2=normalize(vec3(0.6,0.8,0.3));
  float dif=max(dot(n,L1),0.0)*0.85+max(dot(n,L2),0.0)*0.3;
  float hemi=0.5+0.5*n.z;
  vec3 h=normalize(L1+v); float spec=pow(max(dot(n,h),0.0),48.0);
  vec3 base=tx.rgb; float a=uAlpha;
  if(uMode==1){ base=mix(vec3(0.10,0.13,0.17), tx.rgb, 0.9); a=0.18+0.72*tx.a; spec*=2.5; }
  if(uMode==2){ base=vec3(0.07,0.07,0.075); spec*=0.15; }
  vec3 col=base*(0.28*hemi+0.18+dif*0.72)+vec3(spec)*(uMode==1?0.6:0.28);
  if(uLook==1 && uMode<=2){
    // game look (fx.jmd standard pixel.fx): diffuse x sun light + cube-map reflection; here a sky gradient stands in for the cube map
    vec3 L=normalize(vec3(-0.35,-0.5,0.8)); float d=max(dot(n,L),0.0);
    vec3 r=reflect(-v,n);
    vec3 env=r.z>0.0 ? mix(vec3(0.42,0.47,0.55), vec3(0.78,0.86,0.98), clamp(r.z*1.6,0.0,1.0)) : mix(vec3(0.20,0.20,0.21), vec3(0.08,0.08,0.09), clamp(-r.z*3.0,0.0,1.0));
    float fres=0.04+0.96*pow(1.0-max(dot(n,v),0.0),5.0);
    float envF = uMode==1 ? 0.85 : (uMode==2 ? 0.04 : 0.32);
    vec3 lit=base*(0.38+0.22*hemi+0.7*d);
    vec3 hs=normalize(L+v); float sp=pow(max(dot(n,hs),0.0),90.0);
    col=mix(lit, env, clamp(envF*(0.35+0.65*fres),0.0,1.0)) + vec3(1.0,0.97,0.9)*sp*(uMode==2?0.1:0.8);
  }
  if(uMode==3) col=base*0.9+0.15 + (base*1.8+vec3(0.25))*uLights;
  if(uMode==4){ if(tx.a<0.35) discard; col+=base*uGlow*1.4; }
  gl_FragColor=vec4(mix(col,vec3(0.055,0.063,0.082),fog),a);
}`;

const M4 = {
  mul(a, b) { const o = new Float32Array(16); for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) { let s = 0; for (let k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k]; o[c * 4 + r] = s; } return o; },
  perspective(fov, asp, n, f) { const t = 1 / Math.tan(fov / 2), o = new Float32Array(16); o[0] = t / asp; o[5] = t; o[10] = (f + n) / (n - f); o[11] = -1; o[14] = 2 * f * n / (n - f); return o; },
  lookAt(e, c, up) {
    const z = norm([e[0] - c[0], e[1] - c[1], e[2] - c[2]]), x = norm(cross(up, z)), y = cross(z, x);
    return new Float32Array([x[0], y[0], z[0], 0, x[1], y[1], z[1], 0, x[2], y[2], z[2], 0, -dot(x, e), -dot(y, e), -dot(z, e), 1]);
  },
};
function cross(a, b) { return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]; }
function dot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
function norm(a) { const l = Math.hypot(a[0], a[1], a[2]) || 1; return [a[0] / l, a[1] / l, a[2] / l]; }
