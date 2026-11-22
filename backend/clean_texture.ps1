# Clean texture: fixes "broken pixel" cars whose detail triangles take their colour from the small _color slot of the
# car texture (composite rect 0.75..1 x 0.75..0.875; 128x64 pixels of the game's 512x512 car texture). Game files are
# only read.
#   in : -Car, -Colors (swatches, 4-32), -Mask (also clean the paint mask), -Specks (absorb tiny colour islands),
#        -Detail (0-3: how often a triangle that straddles a colour edge of the picture may be split in 4)
#   out: out\carmod\<car>\clean\<car>.jmd   cleaned copy of the car (the workshop previews and reshapes this one)
#        out\carmod\<car>\clean\report.json  palette and counts
#        out\package\car_<car>\Data\car\<car>.jmd (+ FileInfo.0m when the client lists the car)
# How:
#   1. Every triangle whose UV centre lies in the _color slot gets one colour: the most common colour among 21 samples
#      of <car>_color.png inside the triangle (speckle noise doesn't average into grey).
#   1b. A detail triangle whose dominant colour covers under 80% of its samples straddles a colour edge of the picture:
#      it is split in 4 at its edge midpoints (shared with the neighbours, so no cracks), up to -Detail times and never
#      below ~6 picture pixels, so colour edges follow the picture's outline instead of the big triangles' zigzag.
#   2. The colours are grouped into N swatches (k-means, weighted by triangle area, from the LOD-2 mesh; LOD 1 and 0
#      use the same swatches). Islands of one swatch smaller than 4 cm2 take the swatch of their surroundings.
#   3. <car>_color.png becomes a grid of solid swatches (same size, so the game's slot and the far copy fit), and each
#      detail triangle's three corners point at the centre of its swatch. Where triangles of different swatches share a
#      corner, the corner is split, so every triangle is one clean colour and colour edges follow the model's edges.
#   4. Paint mask (<car>_base.png, R/G/B = paint colour 1/2/3): every pixel goes to its strongest colour, blobs under
#      40 pixels join their surroundings, edges are softened (two 3x3 blurs) so they are not stair-stepped.
#   Files: big_0/1/2.rcb ("big" cars, rewritten block by block) or body_0/1/2.0m (JMDReader ReplaceCarGeometry);
#   <car>_color.png/_s.dds and <car>_base.png/_s.dds (far copies encoded like the originals).
param([Parameter(Mandatory)][string]$Car, [int]$Colors = 16, [int]$Mask = 1, [int]$Specks = 1, [int]$Detail = 2, [string]$Source,
      [string]$FileInfo = '')
. (Join-Path $PSScriptRoot "common.ps1")
if (-not $FileInfo) { $FileInfo = $ClientFileInfo }
if ($Car -notmatch '^[\w\-]+$') { throw "bad car name" }
$Colors = [Math]::Max(4, [Math]::Min(32, $Colors))
$src = if ($Source) { $Source } else { Join-Path $Ray "Data\car\$Car.jmd" }
if (-not (Test-Path $src)) { throw "car archive not found: $src" }
$dir = Join-Path $Workshop "out\carmod\$Car\clean"
[IO.Directory]::CreateDirectory($dir) | Out-Null
$arc = Open-Jmd $src

$dll = $JmdDll
Add-Type -ReferencedAssemblies $dll, System.Drawing -Language CSharp -TypeDefinition @'
using System; using System.Collections.Generic; using System.Text; using System.Globalization;
using Raycity.Model;
public class WsMesh { public float[] P, N, U; public int[] T; public int[] Part; public int Parts; }
public static class WsClean {
    const float U0 = 0.75f, U1 = 1f, V0 = 0.75f, V1 = 0.875f;
    static bool InSlot(float u, float v) { return u >= U0 && u <= U1 && v >= V0 && v <= V1; }

    // ---- mesh in / out -------------------------------------------------------------------------------------------
    public static WsMesh FromOm(OmMesh m) {
        int n = m.Positions.Length; var w = new WsMesh { P = new float[n*3], N = new float[n*3], U = new float[n*2], Parts = m.Parts.Length };
        for (int i = 0; i < n; i++) {
            w.P[i*3] = m.Positions[i].X; w.P[i*3+1] = m.Positions[i].Y; w.P[i*3+2] = m.Positions[i].Z;
            if (i < m.Normals.Length) { w.N[i*3] = m.Normals[i].X; w.N[i*3+1] = m.Normals[i].Y; w.N[i*3+2] = m.Normals[i].Z; }
            if (i < m.TextureCoordinates.Length) { w.U[i*2] = m.TextureCoordinates[i].X; w.U[i*2+1] = m.TextureCoordinates[i].Y; }
        }
        var t = new List<int>(); var pp = new List<int>();
        for (int k = 0; k < m.Parts.Length; k++) { var p = m.Parts[k]; for (int i = 0; i + 2 < p.Indices.Length; i += 3) { t.Add(p.BaseVertex + p.Indices[i]); t.Add(p.BaseVertex + p.Indices[i+1]); t.Add(p.BaseVertex + p.Indices[i+2]); pp.Add(k); } }
        w.T = t.ToArray(); w.Part = pp.ToArray(); return w;
    }
    static string F(float v) { return v.ToString("R", CultureInfo.InvariantCulture); }
    public static string ToObj(WsMesh w) {
        var sb = new StringBuilder("# workshop clean texture\n"); int n = w.P.Length / 3;
        for (int i = 0; i < n; i++) sb.Append("v ").Append(F(w.P[i*3])).Append(' ').Append(F(w.P[i*3+1])).Append(' ').Append(F(w.P[i*3+2])).Append('\n');
        for (int i = 0; i < n; i++) sb.Append("vn ").Append(F(w.N[i*3])).Append(' ').Append(F(w.N[i*3+1])).Append(' ').Append(F(w.N[i*3+2])).Append('\n');
        for (int i = 0; i < n; i++) sb.Append("vt ").Append(F(w.U[i*2])).Append(' ').Append(F(w.U[i*2+1])).Append('\n');
        for (int k = 0; k < w.Parts; k++) {
            sb.Append("o part_").Append(k + 1).Append('\n');
            for (int t = 0; t < w.Part.Length; t++) if (w.Part[t] == k) { sb.Append('f'); for (int c = 0; c < 3; c++) { int v = w.T[t*3+c] + 1; sb.Append(' ').Append(v).Append('/').Append(v).Append('/').Append(v); } sb.Append('\n'); }
        }
        return sb.ToString();
    }
    // RCB1: blocks = parts (body, glass, doors); header per door kept
    public static WsMesh FromRcb(byte[] b, out List<int[]> doorHead) {
        var w = new WsMesh(); var P = new List<float>(); var N = new List<float>(); var U = new List<float>(); var T = new List<int>(); var pp = new List<int>();
        doorHead = new List<int[]>(); int o = 60, baseV = 0, part = 0;
        Action<int, int> block = (V, I) => {
            for (int i = 0; i < V; i++) { int p = o + i * 32; for (int c = 0; c < 3; c++) { P.Add(BitConverter.ToSingle(b, p + c*4)); N.Add(BitConverter.ToSingle(b, p + 12 + c*4)); } U.Add(BitConverter.ToSingle(b, p + 24)); U.Add(BitConverter.ToSingle(b, p + 28)); }
            o += V * 32;
            for (int i = 0; i < I; i++) { T.Add(baseV + (int)BitConverter.ToUInt32(b, o + i * 4)); if (i % 3 == 2) pp.Add(part); }
            o += I * 4; baseV += V; part++;
        };
        block((int)BitConverter.ToUInt32(b, 12), (int)BitConverter.ToUInt32(b, 16));
        block((int)BitConverter.ToUInt32(b, 20), (int)BitConverter.ToUInt32(b, 24));
        int doors = (int)BitConverter.ToUInt32(b, o); o += 4;
        for (int d = 0; d < doors; d++) { doorHead.Add(new[] { (int)BitConverter.ToUInt32(b, o), (int)BitConverter.ToUInt32(b, o + 4) }); int V = (int)BitConverter.ToUInt32(b, o + 8), I = (int)BitConverter.ToUInt32(b, o + 12); o += 16; block(V, I); }
        if (o != b.Length) throw new Exception("RCB layout mismatch");
        w.P = P.ToArray(); w.N = N.ToArray(); w.U = U.ToArray(); w.T = T.ToArray(); w.Part = pp.ToArray(); w.Parts = part; return w;
    }
    public static byte[] ToRcb(WsMesh w, byte[] orig, List<int[]> doorHead) {
        var ms = new System.IO.MemoryStream(); var hdr = new byte[60]; Array.Copy(orig, hdr, 60);
        var blocks = new List<byte[]>(); var counts = new List<int[]>();
        for (int k = 0; k < w.Parts; k++) {
            var map = new Dictionary<int, int>(); var vb = new System.IO.MemoryStream(); var ib = new System.IO.MemoryStream();
            for (int t = 0; t < w.Part.Length; t++) if (w.Part[t] == k) for (int c = 0; c < 3; c++) {
                int v = w.T[t*3+c], li;
                if (!map.TryGetValue(v, out li)) {
                    li = map.Count; map[v] = li;
                    foreach (float f in new[] { w.P[v*3], w.P[v*3+1], w.P[v*3+2], w.N[v*3], w.N[v*3+1], w.N[v*3+2], w.U[v*2], w.U[v*2+1] }) vb.Write(BitConverter.GetBytes(f), 0, 4);
                }
                ib.Write(BitConverter.GetBytes((uint)li), 0, 4);
            }
            var all = new byte[vb.Length + ib.Length]; Array.Copy(vb.ToArray(), all, vb.Length); Array.Copy(ib.ToArray(), 0, all, vb.Length, ib.Length);
            blocks.Add(all); counts.Add(new[] { map.Count, (int)(ib.Length / 4) });
        }
        Array.Copy(BitConverter.GetBytes((uint)counts[0][0]), 0, hdr, 12, 4); Array.Copy(BitConverter.GetBytes((uint)counts[0][1]), 0, hdr, 16, 4);
        Array.Copy(BitConverter.GetBytes((uint)counts[1][0]), 0, hdr, 20, 4); Array.Copy(BitConverter.GetBytes((uint)counts[1][1]), 0, hdr, 24, 4);
        ms.Write(hdr, 0, 60); ms.Write(blocks[0], 0, blocks[0].Length); ms.Write(blocks[1], 0, blocks[1].Length);
        ms.Write(BitConverter.GetBytes((uint)doorHead.Count), 0, 4);
        for (int d = 0; d < doorHead.Count; d++) {
            foreach (int x in new[] { doorHead[d][0], doorHead[d][1], counts[d+2][0], counts[d+2][1] }) ms.Write(BitConverter.GetBytes((uint)x), 0, 4);
            ms.Write(blocks[d+2], 0, blocks[d+2].Length);
        }
        return ms.ToArray();
    }

    // ---- colours ---------------------------------------------------------------------------------------------------
    // Split detail triangles that straddle a colour edge of the picture (their dominant colour covers < 80% of the
    // samples) into 4 at the edge midpoints, up to maxDepth times and never below ~6 picture pixels, so the colour
    // edge follows the picture's outline instead of the big triangles' zigzag. Midpoints are shared between
    // neighbours (one per edge), so no cracks open. Returns the new mesh with per-triangle colour / detail / area.
    public static WsMesh Subdivide(WsMesh w, byte[] img, int W, int H, int maxDepth, out float[] col, out bool[] det, out float[] area, out int splits) {
        var P = new List<float>(w.P); var N = new List<float>(w.N); var U = new List<float>(w.U);
        var T = new List<int>(); var Part = new List<int>(); var C = new List<float>(); var D = new List<bool>(); var A = new List<float>();
        var mid = new Dictionary<long, int>(); int sp = 0;
        Func<int, int, int> Mid = (a, b) => {
            long k = a < b ? (long)a * 4000000L + b : (long)b * 4000000L + a; int m;
            if (mid.TryGetValue(k, out m)) return m;
            m = P.Count / 3; mid[k] = m;
            for (int c = 0; c < 3; c++) P.Add((P[a*3+c] + P[b*3+c]) / 2);
            float nx = N[a*3] + N[b*3], ny = N[a*3+1] + N[b*3+1], nz = N[a*3+2] + N[b*3+2]; float l = (float)Math.Sqrt(nx*nx + ny*ny + nz*nz); if (l == 0) l = 1;
            N.Add(nx / l); N.Add(ny / l); N.Add(nz / l);
            U.Add((U[a*2] + U[b*2]) / 2); U.Add((U[a*2+1] + U[b*2+1]) / 2);
            return m;
        };
        var bucket = new Dictionary<int, int[]>();
        // samples the picture inside (a,b,c): dominant colour and its share
        Func<int, int, int, float[]> Sample = (a, b, c) => {
            bucket.Clear(); int n = 0, nt = 0; double sR = 0, sG = 0, sB = 0;
            for (int i = 0; i <= 5; i++) for (int j = 0; j <= 5 - i; j++) {
                double l1 = i / 5.0, l2 = j / 5.0, l0 = 1 - l1 - l2;
                l0 = 1.0/3 + (l0 - 1.0/3) * 0.8; l1 = 1.0/3 + (l1 - 1.0/3) * 0.8; l2 = 1.0/3 + (l2 - 1.0/3) * 0.8;
                double su = l0 * U[a*2] + l1 * U[b*2] + l2 * U[c*2], sv = l0 * U[a*2+1] + l1 * U[b*2+1] + l2 * U[c*2+1];
                int px = Math.Min(W - 1, Math.Max(0, (int)((su - U0) / (U1 - U0) * W))), py = Math.Min(H - 1, Math.Max(0, (int)((sv - V0) / (V1 - V0) * H)));
                int o = (py * W + px) * 4; int B = img[o], G = img[o+1], R = img[o+2];
                if (img[o+3] < 128) { nt++; continue; } // see-through: the paint shows here
                int key = (R >> 4) << 8 | (G >> 4) << 4 | (B >> 4); int[] acc;
                if (!bucket.TryGetValue(key, out acc)) bucket[key] = acc = new int[4];
                acc[0]++; acc[1] += R; acc[2] += G; acc[3] += B; n++; sR += R; sG += G; sB += B;
            }
            int tot = n + nt; float tShare = nt / (float)tot;
            if (n == 0) return new[] { -1f, -1f, -1f, 1f, 1f };
            int[] best = null; foreach (var kv in bucket) if (best == null || kv.Value[0] > best[0]) best = kv.Value;
            // colour = the average of the solid samples (the picture is already shrunk to what the game shows); mostly
            // see-through -> -1 (transparent swatch). [3] = share of the dominant kind, decides splitting
            float dom = Math.Max(best[0], nt) / (float)tot;
            if (tShare >= 0.5f) return new[] { -1f, -1f, -1f, dom, tShare };
            return new[] { (float)(sR / n), (float)(sG / n), (float)(sB / n), dom, tShare };
        };
        Func<int, int, int, float> Area3 = (a, b, c) => {
            double ux = P[b*3]-P[a*3], uy = P[b*3+1]-P[a*3+1], uz = P[b*3+2]-P[a*3+2], vx = P[c*3]-P[a*3], vy = P[c*3+1]-P[a*3+1], vz = P[c*3+2]-P[a*3+2];
            return (float)(0.5 * Math.Sqrt(Math.Pow(uy*vz-uz*vy, 2) + Math.Pow(uz*vx-ux*vz, 2) + Math.Pow(ux*vy-uy*vx, 2)));
        };
        Func<int, int, int, double> Texels = (a, b, c) => Math.Abs((U[b*2]-U[a*2]) * (U[c*2+1]-U[a*2+1]) - (U[c*2]-U[a*2]) * (U[b*2+1]-U[a*2+1])) * 0.5 * (W / (U1 - U0)) * (H / (V1 - V0));
        Action<int, int, int, int, int> Emit = null;
        Emit = (a, b, c, part, depth) => {
            float cu = (U[a*2] + U[b*2] + U[c*2]) / 3, cv = (U[a*2+1] + U[b*2+1] + U[c*2+1]) / 3;
            if (!InSlot(cu, cv)) { T.Add(a); T.Add(b); T.Add(c); Part.Add(part); C.Add(0); C.Add(0); C.Add(0); D.Add(false); A.Add(Area3(a, b, c)); return; }
            var s = Sample(a, b, c);
            if (s[3] < 0.8f && depth < maxDepth && Texels(a, b, c) > 6) {
                int ab = Mid(a, b), bc = Mid(b, c), ca = Mid(c, a); sp++;
                Emit(a, ab, ca, part, depth + 1); Emit(ab, b, bc, part, depth + 1); Emit(ca, bc, c, part, depth + 1); Emit(ab, bc, ca, part, depth + 1);
                return;
            }
            T.Add(a); T.Add(b); T.Add(c); Part.Add(part); C.Add(s[0]); C.Add(s[1]); C.Add(s[2]); D.Add(true); A.Add(Area3(a, b, c));
        };
        for (int t = 0; t < w.T.Length / 3; t++) Emit(w.T[t*3], w.T[t*3+1], w.T[t*3+2], w.Part[t], 0);
        col = C.ToArray(); det = D.ToArray(); area = A.ToArray(); splits = sp;
        return new WsMesh { P = P.ToArray(), N = N.ToArray(), U = U.ToArray(), T = T.ToArray(), Part = Part.ToArray(), Parts = w.Parts };
    }
    // box-average BGRA W x H down to w x h (rows stay top-down)
    public static byte[] Box(byte[] src, int W, int H, int w, int h) {
        var o = new byte[w * h * 4];
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            int x0 = x * W / w, x1 = Math.Max(x0 + 1, (x + 1) * W / w), y0 = y * H / h, y1 = Math.Max(y0 + 1, (y + 1) * H / h);
            double b = 0, g = 0, r = 0, a = 0; int n = 0;
            for (int yy = y0; yy < y1; yy++) for (int xx = x0; xx < x1; xx++) { int p = (yy * W + xx) * 4; b += src[p]; g += src[p+1]; r += src[p+2]; a += src[p+3]; n++; }
            int q = (y * w + x) * 4; o[q] = (byte)(b / n); o[q+1] = (byte)(g / n); o[q+2] = (byte)(r / n); o[q+3] = (byte)(a / n);
        }
        return o;
    }
    public static float[] KMeans(float[] col, bool[] det, float[] area, int K) {
        var idx = new List<int>(); for (int t = 0; t < det.Length; t++) if (det[t] && col[t*3] >= 0) idx.Add(t);
        if (idx.Count == 0) return new float[0];
        // seeds: colours (4-bit buckets) that cover at least 0.2% of the detail area; the biggest first, then always the
        // one farthest from the seeds so far (weighted a little by its area), so black, white and accent colours each
        // get their own swatch instead of being averaged together
        var bArea = new Dictionary<int, double>(); var bSum = new Dictionary<int, double[]>(); double total = 0;
        foreach (int t in idx) {
            int key = ((int)col[t*3] >> 4) << 8 | ((int)col[t*3+1] >> 4) << 4 | ((int)col[t*3+2] >> 4);
            double a; bArea.TryGetValue(key, out a); bArea[key] = a + area[t] + 1e-9; total += area[t] + 1e-9;
            double[] s; if (!bSum.TryGetValue(key, out s)) bSum[key] = s = new double[3];
            for (int c = 0; c < 3; c++) s[c] += col[t*3+c] * (area[t] + 1e-9);
        }
        var cand = new List<float[]>();
        foreach (var kv in bArea) if (kv.Value >= 0.002 * total) { var s = bSum[kv.Key]; cand.Add(new[] { (float)(s[0] / kv.Value), (float)(s[1] / kv.Value), (float)(s[2] / kv.Value), (float)(kv.Value / total) }); }
        if (cand.Count == 0) foreach (var kv in bArea) { var s = bSum[kv.Key]; cand.Add(new[] { (float)(s[0] / kv.Value), (float)(s[1] / kv.Value), (float)(s[2] / kv.Value), (float)(kv.Value / total) }); }
        K = Math.Min(K, cand.Count); var C = new float[K * 3];
        var used = new bool[cand.Count]; int f0 = 0; for (int i = 1; i < cand.Count; i++) if (cand[i][3] > cand[f0][3]) f0 = i;
        used[f0] = true; for (int c = 0; c < 3; c++) C[c] = cand[f0][c];
        for (int k = 1; k < K; k++) {
            int bi = -1; double bs = -1;
            for (int i = 0; i < cand.Count; i++) {
                if (used[i]) continue; double dm = 1e18;
                for (int j = 0; j < k; j++) { double r = cand[i][0]-C[j*3], g = cand[i][1]-C[j*3+1], b = cand[i][2]-C[j*3+2]; dm = Math.Min(dm, 0.3*r*r + 0.59*g*g + 0.11*b*b); }
                double sc = dm * Math.Pow(cand[i][3], 0.25); if (sc > bs) { bs = sc; bi = i; }
            }
            used[bi] = true; for (int c = 0; c < 3; c++) C[k*3+c] = cand[bi][c];
        }
        for (int it = 0; it < 20; it++) {
            var S = new double[K * 3]; var Wt = new double[K];
            foreach (int t in idx) { int j = Nearest(col, t, C, K); double w = area[t] + 1e-6; Wt[j] += w; for (int c = 0; c < 3; c++) S[j*3+c] += col[t*3+c] * w; }
            for (int j = 0; j < K; j++) if (Wt[j] > 0) for (int c = 0; c < 3; c++) C[j*3+c] = (float)(S[j*3+c] / Wt[j]);
        }
        return C;
    }
    static double Dist(float[] col, int t, float[] C, int j) { double r = col[t*3]-C[j*3], g = col[t*3+1]-C[j*3+1], b = col[t*3+2]-C[j*3+2]; return 0.3*r*r + 0.59*g*g + 0.11*b*b; }
    public static int Nearest(float[] col, int t, float[] C, int K) { int bj = 0; double bd = 1e18; for (int j = 0; j < K; j++) { double d = Dist(col, t, C, j); if (d < bd) { bd = d; bj = j; } } return bj; }
    public static int[] Label(float[] col, bool[] det, float[] C) {
        int K = C.Length / 3; var lab = new int[det.Length];
        for (int t = 0; t < det.Length; t++) lab[t] = !det[t] ? -1 : (col[t*3] < 0 ? K : Nearest(col, t, C, K)); // K = the see-through swatch
        return lab;
    }
    // islands of one swatch smaller than minArea take the swatch their border shares most (triangles joined by edges,
    // corners matched by position so UV seams don't cut islands)
    public static int Despeck(WsMesh w, int[] lab, float[] area, double minArea) {
        int m = lab.Length; var vkey = new long[w.P.Length / 3];
        for (int i = 0; i < vkey.Length; i++) vkey[i] = ((long)Math.Round(w.P[i*3] * 2000) * 73856093L) ^ ((long)Math.Round(w.P[i*3+1] * 2000) * 19349663L) ^ ((long)Math.Round(w.P[i*3+2] * 2000) * 83492791L);
        var edges = new Dictionary<long, List<int>>();
        for (int t = 0; t < m; t++) if (lab[t] >= 0) for (int c = 0; c < 3; c++) {
            long a = vkey[w.T[t*3+c]], b = vkey[w.T[t*3+(c+1)%3]]; long k = a < b ? a * 1000003L ^ b : b * 1000003L ^ a;
            List<int> l; if (!edges.TryGetValue(k, out l)) edges[k] = l = new List<int>(); l.Add(t);
        }
        var nb = new List<int>[m]; for (int t = 0; t < m; t++) nb[t] = new List<int>();
        foreach (var l in edges.Values) for (int i = 0; i < l.Count; i++) for (int j = 0; j < l.Count; j++) if (i != j) nb[l[i]].Add(l[j]);
        int changed = 0;
        for (int pass = 0; pass < 3; pass++) {
            var comp = new int[m]; for (int t = 0; t < m; t++) comp[t] = -1;
            int nc = 0;
            for (int s = 0; s < m; s++) {
                if (lab[s] < 0 || comp[s] >= 0) continue;
                var stack = new Stack<int>(); var members = new List<int>(); stack.Push(s); comp[s] = nc; double ar = 0;
                while (stack.Count > 0) { int t = stack.Pop(); members.Add(t); ar += area[t]; foreach (int q in nb[t]) if (comp[q] < 0 && lab[q] == lab[s]) { comp[q] = nc; stack.Push(q); } }
                nc++;
                if (ar >= minArea) continue;
                var votes = new Dictionary<int, double>();
                foreach (int t in members) foreach (int q in nb[t]) if (lab[q] >= 0 && lab[q] != lab[s]) { double v; votes.TryGetValue(lab[q], out v); votes[lab[q]] = v + 1; }
                if (votes.Count == 0) continue;
                int bl = -1; double bv = -1; foreach (var kv in votes) if (kv.Value > bv) { bv = kv.Value; bl = kv.Key; }
                foreach (int t in members) lab[t] = bl; changed += members.Count;
            }
        }
        // straighten colour edges: a triangle with at least two edge-neighbours of one other swatch (a "tooth" of a
        // zigzag edge) takes that swatch; three passes
        for (int pass = 0; pass < 3; pass++) {
            var next = (int[])lab.Clone(); int n = 0;
            for (int t = 0; t < m; t++) {
                if (lab[t] < 0) continue;
                var votes = new Dictionary<int, int>();
                foreach (int q in nb[t]) if (lab[q] >= 0 && lab[q] != lab[t]) { int v; votes.TryGetValue(lab[q], out v); votes[lab[q]] = v + 1; }
                foreach (var kv in votes) if (kv.Value >= 2 && kv.Value * 2 > nb[t].Count) { next[t] = kv.Key; n++; break; }
            }
            Array.Copy(next, lab, m); changed += n; // (lab is the caller's array: copy into it)
            if (n == 0) break;
        }
        return changed;
    }
    // swatch grid: 8 columns; centre UV of swatch j in the car texture
    // the last cell (index K) is fully see-through, for triangles where the original picture let the paint show
    public static byte[] Atlas(float[] C, int W, int H, out float[] uv) {
        int K = C.Length / 3, cells = K + 1, cols = 8, rows = (cells + 7) / 8; var img = new byte[W * H * 4]; uv = new float[cells * 2];
        int cw = W / cols, ch = H / rows;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            int j = Math.Min(cells - 1, Math.Min(rows - 1, y / ch) * cols + Math.Min(cols - 1, x / cw)); int o = (y * W + x) * 4;
            if (j == K) { img[o] = img[o+1] = img[o+2] = 0; img[o+3] = 0; continue; }
            img[o] = (byte)Math.Round(C[j*3+2]); img[o+1] = (byte)Math.Round(C[j*3+1]); img[o+2] = (byte)Math.Round(C[j*3]); img[o+3] = 255;
        }
        for (int j = 0; j < cells; j++) { int cx = (j % cols) * cw + cw / 2, cy = (j / cols) * ch + ch / 2; uv[j*2] = U0 + (cx + 0.5f) / W * (U1 - U0); uv[j*2+1] = V0 + (cy + 0.5f) / H * (V1 - V0); }
        return img;
    }
    // every detail triangle's corners -> its swatch centre; corners shared by different swatches are split
    public static WsMesh Remap(WsMesh w, int[] lab, float[] uv, out int added) {
        var map = new Dictionary<long, int>(); var P = new List<float>(); var N = new List<float>(); var U = new List<float>(); var T = new int[w.T.Length];
        for (int t = 0; t < lab.Length; t++) for (int c = 0; c < 3; c++) {
            int v = w.T[t*3+c]; long key = (long)v * 64 + (lab[t] + 1); int ni;
            if (!map.TryGetValue(key, out ni)) {
                ni = P.Count / 3; map[key] = ni;
                for (int q = 0; q < 3; q++) { P.Add(w.P[v*3+q]); N.Add(w.N[v*3+q]); }
                if (lab[t] < 0) { U.Add(w.U[v*2]); U.Add(w.U[v*2+1]); } else { U.Add(uv[lab[t]*2]); U.Add(uv[lab[t]*2+1]); }
            }
            T[t*3+c] = ni;
        }
        added = P.Count / 3 - w.P.Length / 3;
        return new WsMesh { P = P.ToArray(), N = N.ToArray(), U = U.ToArray(), T = T, Part = w.Part, Parts = w.Parts };
    }

    // ---- paint mask -------------------------------------------------------------------------------------------------
    public static byte[] CleanMask(byte[] img, int W, int H, int minPx, out int fixedPx) {
        var lab = new int[W * H]; fixedPx = 0;
        for (int i = 0; i < W * H; i++) { int B = img[i*4], G = img[i*4+1], R = img[i*4+2]; int mx = Math.Max(R, Math.Max(G, B)); lab[i] = mx < 40 ? 3 : (R == mx ? 0 : (G == mx ? 1 : 2)); }
        var comp = new int[W * H]; for (int i = 0; i < comp.Length; i++) comp[i] = -1;
        int nc = 0; var st = new Stack<int>(); var mem = new List<int>();
        for (int s = 0; s < W * H; s++) {
            if (comp[s] >= 0) continue;
            mem.Clear(); st.Push(s); comp[s] = nc;
            while (st.Count > 0) { int p = st.Pop(); mem.Add(p); int x = p % W, y = p / W;
                foreach (int q in new[] { x > 0 ? p - 1 : -1, x < W - 1 ? p + 1 : -1, y > 0 ? p - W : -1, y < H - 1 ? p + W : -1 }) if (q >= 0 && comp[q] < 0 && lab[q] == lab[s]) { comp[q] = nc; st.Push(q); } }
            nc++;
            if (mem.Count >= minPx) continue;
            var votes = new int[4];
            foreach (int p in mem) { int x = p % W, y = p / W; foreach (int q in new[] { x > 0 ? p - 1 : -1, x < W - 1 ? p + 1 : -1, y > 0 ? p - W : -1, y < H - 1 ? p + W : -1 }) if (q >= 0 && lab[q] != lab[s]) votes[lab[q]]++; }
            int bl = lab[s], bv = 0; for (int k = 0; k < 4; k++) if (votes[k] > bv) { bv = votes[k]; bl = k; }
            if (bl != lab[s]) { foreach (int p in mem) lab[p] = bl; fixedPx += mem.Count; }
        }
        // soft edges: one-hot channels, two 3x3 box blurs
        var ch = new float[3][]; for (int c = 0; c < 3; c++) { ch[c] = new float[W * H]; for (int i = 0; i < W * H; i++) ch[c][i] = lab[i] == c ? 255f : 0f; }
        for (int pass = 0; pass < 2; pass++) for (int c = 0; c < 3; c++) {
            var o = new float[W * H];
            for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { float s = 0; int n = 0; for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) { int xx = x + dx, yy = y + dy; if (xx < 0 || yy < 0 || xx >= W || yy >= H) continue; s += ch[c][yy * W + xx]; n++; } o[y * W + x] = s / n; }
            ch[c] = o;
        }
        var res = (byte[])img.Clone();
        for (int i = 0; i < W * H; i++) { res[i*4+2] = (byte)Math.Round(ch[0][i]); res[i*4+1] = (byte)Math.Round(ch[1][i]); res[i*4] = (byte)Math.Round(ch[2][i]); }
        return res;
    }
}
'@

function Load-Png([byte[]]$b) {
    $bmp = New-Object Drawing.Bitmap (New-Object IO.MemoryStream(, $b))
    $d = $bmp.LockBits((New-Object Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)), [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $buf = New-Object byte[] ($bmp.Width * $bmp.Height * 4)
    for ($y = 0; $y -lt $bmp.Height; $y++) { [Runtime.InteropServices.Marshal]::Copy([IntPtr]($d.Scan0.ToInt64() + $y * $d.Stride), $buf, $y * $bmp.Width * 4, $bmp.Width * 4) }
    $bmp.UnlockBits($d); $r = @{ W = $bmp.Width; H = $bmp.Height; B = $buf }; $bmp.Dispose(); $r
}
function Save-Png([byte[]]$buf, [int]$w, [int]$h, [string]$path) {
    $bmp = New-Object Drawing.Bitmap($w, $h, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $d = $bmp.LockBits((New-Object Drawing.Rectangle(0, 0, $w, $h)), [Drawing.Imaging.ImageLockMode]::WriteOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    for ($y = 0; $y -lt $h; $y++) { [Runtime.InteropServices.Marshal]::Copy($buf, $y * $w * 4, [IntPtr]($d.Scan0.ToInt64() + $y * $d.Stride), $w * 4) }
    $bmp.UnlockBits($d); $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

$changes = @{}   # archive path -> bytes
$colorName = "$($Car)_color"
$cb = Get-EntryBytes $arc "$colorName.png"
if ($null -eq $cb) { throw "the car has no $colorName.png" }
$atlas = Load-Png $cb
"detail picture $colorName.png: $($atlas.W) x $($atlas.H)"
# colours are read from the picture as the game shows it: shrunk into the 512x512 car texture's 128x64 slot (box average)
$sw = [Math]::Min($atlas.W, 128); $sh = [Math]::Min($atlas.H, 64)
$look = @{ W = $sw; H = $sh; B = $(if ($sw -eq $atlas.W -and $sh -eq $atlas.H) { $atlas.B } else { [WsClean]::Box($atlas.B, $atlas.W, $atlas.H, $sw, $sh) }) }

$big = $null -ne (Find-Entry $arc "big_2.rcb")
$files = if ($big) { "big_2.rcb", "big_1.rcb", "big_0.rcb" } else { "body_2.0m", "body_1.0m", "body_0.0m" }
$C = $null; $report = @()
foreach ($f in $files) {
    $bytes = Get-EntryBytes $arc $f; if ($null -eq $bytes) { continue }
    $doorHead = $null
    $w = if ($big) { [WsClean]::FromRcb($bytes, [ref]$doorHead) } else { [WsClean]::FromOm([Raycity.Model.OmMesh]::Parse($bytes)) }
    $det = $null; $area = $null; $col = $null; $splits = 0; $tris0 = $w.T.Length / 3
    $w = [WsClean]::Subdivide($w, $look.B, $look.W, $look.H, [Math]::Max(0, [Math]::Min(3, $Detail)), [ref]$col, [ref]$det, [ref]$area, [ref]$splits)
    $nd = @($det | Where-Object { $_ }).Count
    if ($nd -eq 0) { "  $($f): no triangle uses the detail picture, kept"; continue }
    if ($null -eq $C) {
        $C = [WsClean]::KMeans($col, $det, $area, $Colors)
        "  swatches from $f ($nd of $($det.Length) triangles use the detail picture): $($C.Length / 3)"
    }
    $lab = [WsClean]::Label($col, $det, $C)
    $sp = if ($Specks) { [WsClean]::Despeck($w, $lab, $area, 0.0004) } else { 0 }
    $uvC = $null; $atlasNew = [WsClean]::Atlas($C, $atlas.W, $atlas.H, [ref]$uvC)
    $added = 0; $w2 = [WsClean]::Remap($w, $lab, $uvC, [ref]$added)
    if ($big) {
        $out = [WsClean]::ToRcb($w2, $bytes, $doorHead)
        $chk = $null; $back = [WsClean]::FromRcb($out, [ref]$chk)
        if ($back.T.Length -ne $w2.T.Length) { throw "check: $f came back with $($back.T.Length / 3) triangles" }
    } else {
        $m = [Raycity.Model.OmMesh]::Parse($bytes); $rep = $null
        $out = [Raycity.Model.OmObjImport]::ReplaceCarGeometry($bytes, [WsClean]::ToObj($w2), [ref]$rep)
        $chk = [Raycity.Model.OmMesh]::Parse($out)
        if ($chk.Parts.Length -ne $m.Parts.Length -or $chk.TriangleCount -ne $w2.T.Length / 3) { throw "check: $f came back with $($chk.Parts.Length) parts / $($chk.TriangleCount) triangles" }
    }
    $changes[$f] = $out
    "  $($f): $nd detail triangles -> solid swatches ($splits split along colour edges: $tris0 -> $($w2.T.Length / 3) triangles), $sp in tiny islands joined their surroundings, $added corners split for colour, $($w2.P.Length / 3) vertices, re-read OK"
}
if ($null -eq $C) { throw "no triangle of this car uses the detail picture; nothing to clean" }
Save-Png $atlasNew $atlas.W $atlas.H "$dir\$colorName.png"
$changes["$colorName.png"] = [IO.File]::ReadAllBytes("$dir\$colorName.png")
$cs = Get-EntryBytes $arc "$($colorName)_s.dds"
if ($cs) { $changes["$($colorName)_s.dds"] = New-FarDds "$dir\$colorName.png" $cs }
"  $colorName.png: $($C.Length / 3) solid swatches (+ far copy)"
$pal = @(); for ($j = 0; $j -lt $C.Length / 3; $j++) { $pal += '"#' + ('{0:x2}{1:x2}{2:x2}' -f [int][Math]::Round($C[$j*3]), [int][Math]::Round($C[$j*3+1]), [int][Math]::Round($C[$j*3+2])) + '"' }

$maskFixed = 0
if ($Mask) {
    $bn = "$($Car)_base"; $bb = Get-EntryBytes $arc "$bn.png"
    if ($bb) {
        $mk = Load-Png $bb
        $mres = [WsClean]::CleanMask($mk.B, $mk.W, $mk.H, [int](40 * $mk.W * $mk.H / (1024 * 1024)), [ref]$maskFixed)
        Save-Png $mres $mk.W $mk.H "$dir\$bn.png"
        $changes["$bn.png"] = [IO.File]::ReadAllBytes("$dir\$bn.png")
        $bs = Get-EntryBytes $arc "$($bn)_s.dds"; if ($bs) { $changes["$($bn)_s.dds"] = New-FarDds "$dir\$bn.png" $bs }
        "  $bn.png ($($mk.W) x $($mk.H)): $maskFixed pixels of tiny blobs joined their surroundings, edges softened (+ far copy)"
    }
}

# ---- cleaned copy of the car + package
foreach ($p in $changes.Keys) { $arc.ReplaceFile((Find-Entry $arc $p), [byte[]]$changes[$p]) }
$cleanJmd = "$dir\$Car.jmd"
$arc.SaveAs($cleanJmd)
$b = Open-Jmd $cleanJmd
foreach ($p in $changes.Keys) { if (-not [Linq.Enumerable]::SequenceEqual([byte[]](Get-EntryBytes $b $p), [byte[]]$changes[$p])) { throw "read-back of $p differs" } }
"check: $($changes.Count) files read back byte-identical"
Write-Utf8 "$dir\report.json" ('{"colors":' + ($C.Length / 3) + ',"palette":[' + ($pal -join ',') + '],"mask":' + $Mask + ',"maskFixed":' + $maskFixed + ',"source":' + (ConvertTo-JsonString $src) + '}')
$pkg = Join-Path $Workshop "out\package\car_$Car"
if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
[IO.Directory]::CreateDirectory("$pkg\Data\car") | Out-Null
Copy-Item $cleanJmd "$pkg\Data\car\$Car.jmd"
try { Update-FileInfo $FileInfo (Join-Path $pkg "FileInfo.0m") $pkg @("Data\car\$Car.jmd") } catch { "  FileInfo.0m not written: $($_.Exception.Message) (add the car to the launcher's file list by hand)" }
"CLEAN OK $cleanJmd"
