# Reshape: saves the workshop's sculpted car meshes into game files and a package. Game files are only read.
#   in : out\carmod\<car>\request.json
#        { car, source (car .jmd), edits: [{file, pos}], sets: [{folder, name, base: {name, mesh, tex}, pos}] }
#        file = "body" (body_<L>.0m), "big" (big_<L>.rcb, landverse "big" cars) or "<folder>/<mesh>" (<folder>/<mesh>_<L>.0m)
#        pos  = base64 little-endian float32 x,y,z of the LOD-2 mesh (same vertex order as the workshop's mesh export)
#   out: out\carmod\<car>\game\...   the changed / new files (archive paths)
#        out\package\car_<car>\Data\car\<car>.jmd  copy of the car with them, + FileInfo.0m when the client lists the car
# How:
#   - LOD 2 gets the new positions; LOD 1 and 0 (other meshes) get the same change, carried over from the LOD-2 vertices
#     within 6 cm (distance-weighted average of their moves, unmoved ones count as 0).
#   - Normals: original normal + (new face-normal average - old face-normal average) per vertex, so hard edges and
#     seams keep their look and only bent areas change shading.
#   - .0m: written with JMDReader OmObjImport.ReplaceCarGeometry (keeps mounts, door controllers, draw-part settings),
#     then re-parsed: same parts and triangles. .rcb: positions / normals patched in place (layout in export_car.ps1).
#   - New set: <folder>/<name>_0/1/2.0m from the base variant + list.xml row (base texture) + the base's icon copied.
param([Parameter(Mandatory)][string]$Car, [string]$FileInfo = '')
. (Join-Path $PSScriptRoot "common.ps1")
if (-not $FileInfo) { $FileInfo = $ClientFileInfo }
if ($Car -notmatch '^[\w\-]+$') { throw "bad car name" }
$dir = Join-Path $Workshop "out\carmod\$Car"
$req = Get-Content (Join-Path $dir "request.json") -Raw | ConvertFrom-Json
$src = [string]$req.source
if (-not $src) { $src = Join-Path $Ray "Data\car\$Car.jmd" }
if (-not (Test-Path $src)) { throw "car archive not found: $src" }
$game = Join-Path $dir "game"
if (Test-Path $game) { Remove-Item -Recurse -Force $game }
[IO.Directory]::CreateDirectory($game) | Out-Null
$arc = Open-Jmd $src

$dll = $JmdDll
Add-Type -ReferencedAssemblies $dll -Language CSharp -TypeDefinition @'
using System; using System.Collections.Generic; using System.Text; using System.Globalization;
using Raycity.Model;
public static class WsShape {
    static string F(float v) { return v.ToString("R", CultureInfo.InvariantCulture); }
    public static float[] Pos(OmMesh m) { var a = new float[m.Positions.Length * 3]; for (int i = 0; i < m.Positions.Length; i++) { a[i*3] = m.Positions[i].X; a[i*3+1] = m.Positions[i].Y; a[i*3+2] = m.Positions[i].Z; } return a; }
    public static float[] Nor(OmMesh m) { var a = new float[m.Positions.Length * 3]; for (int i = 0; i < m.Normals.Length && i < m.Positions.Length; i++) { a[i*3] = m.Normals[i].X; a[i*3+1] = m.Normals[i].Y; a[i*3+2] = m.Normals[i].Z; } return a; }
    // the workshop's mesh export rounds to 0.01 mm: moves under 0.1 mm are rounding, keep the original there
    public static float[] Clean(float[] a0, float[] p, out int moved) {
        var o = (float[])a0.Clone(); moved = 0;
        for (int i = 0; i < a0.Length / 3; i++) {
            float dx = p[i*3]-a0[i*3], dy = p[i*3+1]-a0[i*3+1], dz = p[i*3+2]-a0[i*3+2];
            if (dx*dx + dy*dy + dz*dz < 1e-8f) continue;
            o[i*3] = p[i*3]; o[i*3+1] = p[i*3+1]; o[i*3+2] = p[i*3+2]; moved++;
        }
        return o;
    }
    public static int[] Tris(OmMesh m) { var t = new List<int>(); foreach (var p in m.Parts) foreach (var i in p.Indices) t.Add(p.BaseVertex + i); return t.ToArray(); }

    // Carry the LOD-2 change over to another mesh: distance-weighted average of LOD-2 moves within r.
    public static float[] Transfer(float[] a0, float[] a1, float[] dst, float r, out int moved) {
        var grid = new Dictionary<long, List<int>>(); float c = r;
        Func<float, float, float, long> key = (x, y, z) => ((long)Math.Floor(x / c) * 73856093L) ^ ((long)Math.Floor(y / c) * 19349663L) ^ ((long)Math.Floor(z / c) * 83492791L);
        bool any = false;
        for (int i = 0; i < a0.Length / 3; i++) {
            List<int> l; long k = key(a0[i*3], a0[i*3+1], a0[i*3+2]);
            if (!grid.TryGetValue(k, out l)) grid[k] = l = new List<int>(); l.Add(i);
            if (a0[i*3] != a1[i*3] || a0[i*3+1] != a1[i*3+1] || a0[i*3+2] != a1[i*3+2]) any = true;
        }
        var o = (float[])dst.Clone(); moved = 0;
        if (!any) return o;
        for (int v = 0; v < dst.Length / 3; v++) {
            float x = dst[v*3], y = dst[v*3+1], z = dst[v*3+2]; double sw = 0, dx = 0, dy = 0, dz = 0; bool near = false;
            for (int ix = -1; ix <= 1; ix++) for (int iy = -1; iy <= 1; iy++) for (int iz = -1; iz <= 1; iz++) {
                List<int> l; if (!grid.TryGetValue(key(x + ix * c, y + iy * c, z + iz * c), out l)) continue;
                foreach (int i in l) {
                    double ex = a0[i*3] - x, ey = a0[i*3+1] - y, ez = a0[i*3+2] - z, d = Math.Sqrt(ex*ex + ey*ey + ez*ez);
                    if (d > r) continue;
                    double w = 1.0 / (d + 0.004); sw += w; near = true;
                    dx += w * (a1[i*3] - a0[i*3]); dy += w * (a1[i*3+1] - a0[i*3+1]); dz += w * (a1[i*3+2] - a0[i*3+2]);
                }
            }
            if (!near || sw == 0) continue;
            dx /= sw; dy /= sw; dz /= sw;
            if (dx*dx + dy*dy + dz*dz < 1e-12) continue;
            o[v*3] += (float)dx; o[v*3+1] += (float)dy; o[v*3+2] += (float)dz; moved++;
        }
        return o;
    }

    static float[] FaceAvg(float[] p, int[] t, int n) {
        var a = new float[n * 3];
        for (int k = 0; k + 2 < t.Length; k += 3) {
            int i = t[k], j = t[k+1], l = t[k+2];
            float ux = p[j*3]-p[i*3], uy = p[j*3+1]-p[i*3+1], uz = p[j*3+2]-p[i*3+2], vx = p[l*3]-p[i*3], vy = p[l*3+1]-p[i*3+1], vz = p[l*3+2]-p[i*3+2];
            float nx = uy*vz-uz*vy, ny = uz*vx-ux*vz, nz = ux*vy-uy*vx;
            foreach (int q in new[] { i, j, l }) { a[q*3] += nx; a[q*3+1] += ny; a[q*3+2] += nz; }
        }
        for (int q = 0; q < n; q++) { double L = Math.Sqrt(a[q*3]*a[q*3] + a[q*3+1]*a[q*3+1] + a[q*3+2]*a[q*3+2]); if (L > 0) { a[q*3] /= (float)L; a[q*3+1] /= (float)L; a[q*3+2] /= (float)L; } }
        return a;
    }
    // new normal = old normal + (new face average - old face average), only where the vertex moved nearby
    public static float[] Normals(float[] p0, float[] p1, float[] n0, int[] t) {
        int n = p0.Length / 3; var f0 = FaceAvg(p0, t, n); var f1 = FaceAvg(p1, t, n); var o = (float[])n0.Clone();
        for (int q = 0; q < n; q++) {
            float dx = f1[q*3]-f0[q*3], dy = f1[q*3+1]-f0[q*3+1], dz = f1[q*3+2]-f0[q*3+2];
            if (dx*dx + dy*dy + dz*dz < 1e-10) continue;
            float x = n0[q*3]+dx, y = n0[q*3+1]+dy, z = n0[q*3+2]+dz; double L = Math.Sqrt(x*x+y*y+z*z); if (L == 0) continue;
            o[q*3] = (float)(x/L); o[q*3+1] = (float)(y/L); o[q*3+2] = (float)(z/L);
        }
        return o;
    }
    // OBJ with the mesh's own parts (part_1 ...), UVs and indices, new positions / normals (ReplaceCarGeometry input)
    public static string Obj(OmMesh m, float[] p, float[] nor) {
        var sb = new StringBuilder("# workshop reshape\n");
        int n = m.Positions.Length; bool uv = m.TextureCoordinates != null && m.TextureCoordinates.Length == n;
        for (int i = 0; i < n; i++) sb.Append("v ").Append(F(p[i*3])).Append(' ').Append(F(p[i*3+1])).Append(' ').Append(F(p[i*3+2])).Append('\n');
        for (int i = 0; i < n; i++) sb.Append("vn ").Append(F(nor[i*3])).Append(' ').Append(F(nor[i*3+1])).Append(' ').Append(F(nor[i*3+2])).Append('\n');
        if (uv) for (int i = 0; i < n; i++) sb.Append("vt ").Append(F(m.TextureCoordinates[i].X)).Append(' ').Append(F(m.TextureCoordinates[i].Y)).Append('\n');
        for (int k = 0; k < m.Parts.Length; k++) {
            var part = m.Parts[k]; sb.Append("o part_").Append(k + 1).Append('\n');
            for (int i = 0; i + 2 < part.Indices.Length; i += 3) {
                sb.Append('f');
                for (int c = 0; c < 3; c++) { int v = part.BaseVertex + part.Indices[i + c] + 1; sb.Append(' ').Append(v); if (uv) sb.Append('/').Append(v).Append('/').Append(v); else sb.Append("//").Append(v); }
                sb.Append('\n');
            }
        }
        return sb.ToString();
    }

    // ---- RCB1 ("big" cars): blocks in file order (body, glass, doors); positions/normals at vertex+0 / +12
    static List<int[]> RcbBlocks(byte[] b) { // {vertex offset, V, index offset, I}
        var l = new List<int[]>(); int o = 60;
        Action<int, int> add = (V, I) => { l.Add(new[] { o, V, o + V * 32, I }); o += V * 32 + I * 4; };
        add((int)BitConverter.ToUInt32(b, 12), (int)BitConverter.ToUInt32(b, 16));
        add((int)BitConverter.ToUInt32(b, 20), (int)BitConverter.ToUInt32(b, 24));
        int doors = (int)BitConverter.ToUInt32(b, o); o += 4;
        for (int d = 0; d < doors; d++) { int V = (int)BitConverter.ToUInt32(b, o + 8), I = (int)BitConverter.ToUInt32(b, o + 12); o += 16; add(V, I); }
        if (o != b.Length) throw new Exception("RCB layout mismatch");
        return l;
    }
    public static float[] RcbArray(byte[] b, int at) {
        var bl = RcbBlocks(b); int n = 0; foreach (var k in bl) n += k[1];
        var a = new float[n * 3]; int q = 0;
        foreach (var k in bl) for (int i = 0; i < k[1]; i++, q++) for (int c = 0; c < 3; c++) a[q*3+c] = BitConverter.ToSingle(b, k[0] + i * 32 + at + c * 4);
        return a;
    }
    public static int[] RcbTris(byte[] b) {
        var t = new List<int>(); int baseV = 0;
        foreach (var k in RcbBlocks(b)) { for (int i = 0; i < k[3]; i++) t.Add(baseV + (int)BitConverter.ToUInt32(b, k[2] + i * 4)); baseV += k[1]; }
        return t.ToArray();
    }
    public static byte[] RcbPatch(byte[] b, float[] p, float[] nor) {
        var o = (byte[])b.Clone(); int q = 0;
        foreach (var k in RcbBlocks(b)) for (int i = 0; i < k[1]; i++, q++) for (int c = 0; c < 3; c++) {
            Array.Copy(BitConverter.GetBytes(p[q*3+c]), 0, o, k[0] + i * 32 + c * 4, 4);
            Array.Copy(BitConverter.GetBytes(nor[q*3+c]), 0, o, k[0] + i * 32 + 12 + c * 4, 4);
        }
        return o;
    }
}
'@

function From64([string]$s) { $b = [Convert]::FromBase64String($s); $f = New-Object float[] ($b.Length / 4); [Buffer]::BlockCopy($b, 0, $f, 0, $b.Length); , $f }
$written = New-Object Collections.Generic.List[string]
function Put([string]$path, [byte[]]$bytes) {
    $full = Join-Path $game ($path -replace '/', '\')
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
    [IO.File]::WriteAllBytes($full, $bytes); $written.Add($path)
}

# One reshaped mesh family: LOD 2 positions given; LOD 1/0 carried over. $prefix "body" / "big" / "<folder>/<mesh>";
# $outPrefix: where to write (a new set's own name).
function Reshape-Family([string]$prefix, [float[]]$p2, [string]$outPrefix) {
    if ($prefix -eq "big") {
        $b2 = Get-EntryBytes $arc "big_2.rcb"; if ($null -eq $b2) { throw "no big_2.rcb in the car" }
        $a0 = [WsShape]::RcbArray($b2, 0)
        if ($a0.Length -ne $p2.Length) { throw "big_2.rcb has $($a0.Length / 3) vertices, the edit $($p2.Length / 3)" }
        $n2 = 0; $p2 = [WsShape]::Clean($a0, $p2, [ref]$n2); if ($n2 -eq 0) { "  nothing moved"; return }
        foreach ($L in 2, 1, 0) {
            $b = Get-EntryBytes $arc "big_$L.rcb"; if ($null -eq $b) { continue }
            $q0 = [WsShape]::RcbArray($b, 0); $moved = 0
            $same = $L -ne 2 -and [Linq.Enumerable]::SequenceEqual([byte[]]$b, [byte[]]$b2) # a LOD that is the same file as LOD 2 gets the exact shape
            $q1 = if ($L -eq 2 -or $same) { $p2 } else { [WsShape]::Transfer($a0, $p2, $q0, 0.06, [ref]$moved) }
            if ($same) { $moved = $n2 }
            $n1 = [WsShape]::Normals($q0, $q1, [WsShape]::RcbArray($b, 12), [WsShape]::RcbTris($b))
            Put "big_$L.rcb" ([WsShape]::RcbPatch($b, $q1, $n1))
            "  big_$L.rcb: " + $(if ($L -eq 2) { "your shape ($n2 vertices moved)" } else { "$moved vertices moved with it" }) + " (patched in place)"
        }
        return
    }
    $m2 = [Raycity.Model.OmMesh]::Parse((Get-EntryBytes $arc "$($prefix)_2.0m"))
    $a0 = [WsShape]::Pos($m2)
    if ($a0.Length -ne $p2.Length) { throw "$($prefix)_2.0m has $($a0.Length / 3) vertices, the edit $($p2.Length / 3)" }
    $n2 = 0; $p2 = [WsShape]::Clean($a0, $p2, [ref]$n2)
    if ($n2 -eq 0 -and $outPrefix -eq $prefix) { "  nothing moved"; return }
    foreach ($L in 2, 1, 0) {
        $bytes = Get-EntryBytes $arc "$($prefix)_$L.0m"; if ($null -eq $bytes) { continue }
        $m = [Raycity.Model.OmMesh]::Parse($bytes); $q0 = [WsShape]::Pos($m); $moved = 0
        $q1 = if ($L -eq 2) { $p2 } else { [WsShape]::Transfer($a0, $p2, $q0, 0.06, [ref]$moved) }
        if ($L -ne 2 -and $moved -eq 0 -and $outPrefix -eq $prefix) { "  $($prefix)_$L.0m: nothing near the change, kept"; continue }
        $tris = [WsShape]::Tris($m)
        $n1 = [WsShape]::Normals($q0, $q1, [WsShape]::Nor($m), $tris)
        $report = $null
        $out = [Raycity.Model.OmObjImport]::ReplaceCarGeometry($bytes, [WsShape]::Obj($m, $q1, $n1), [ref]$report)
        $chk = [Raycity.Model.OmMesh]::Parse($out)
        if ($chk.Parts.Length -ne $m.Parts.Length -or $chk.TriangleCount -ne $m.TriangleCount) { throw "check: $($prefix)_$L.0m came back with $($chk.Parts.Length) parts / $($chk.TriangleCount) triangles (was $($m.Parts.Length) / $($m.TriangleCount))" }
        Put "$($outPrefix)_$L.0m" $out
        "  $($outPrefix)_$L.0m: " + $(if ($L -eq 2) { "your shape ($n2 vertices moved)" } else { "$moved vertices moved with it" }) + ", re-parsed: $($chk.Parts.Length) parts, $($chk.TriangleCount) triangles"
    }
}

foreach ($e in @($req.edits)) {
    if (-not $e) { continue }
    $f = [string]$e.file
    if ($f -notmatch '^(body|big|[\w\-]+/[\w\-.]+)$') { throw "bad file $f" }
    "edit $f"
    Reshape-Family $f (From64 $e.pos) $f
}
$listAdds = @{}
foreach ($s in @($req.sets)) {
    if (-not $s) { continue }
    $folder = [string]$s.folder; $name = [string]$s.name
    if ($folder -notmatch '^[\w\-]+$' -or $name -notmatch '^[a-z0-9_]{2,30}$') { throw "bad set name" }
    $rows = Get-PartList (Get-XmlText (Get-EntryBytes $arc "$folder/list.xml"))
    if ($rows | Where-Object { $_.name -ieq $name -or $_.mesh -ieq $name }) { throw "$folder already has a part called $name" }
    if (Find-Entry $arc "$folder/$($name)_2.0m") { throw "$folder/$($name)_2.0m already exists" }
    "new set $folder/$name (from $($s.base.name), mesh $($s.base.mesh))"
    Reshape-Family "$folder/$($s.base.mesh)" (From64 $s.pos) "$folder/$name"
    if (-not $listAdds.ContainsKey($folder)) { $listAdds[$folder] = @() }
    $listAdds[$folder] += , @($name, [string]$s.base.tex, [string]$s.base.name)
}

# ---- package: copy of the car archive with the files replaced / added
$pkg = Join-Path $Workshop "out\package\car_$Car"
if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
[IO.Directory]::CreateDirectory("$pkg\Data\car") | Out-Null
$ROOT = [uint32]::MaxValue
function Folder-Index([string]$name) { ($arc.GetEntries($ROOT) | Where-Object { $_ -is [Raycity.File.JMDPackedFolderInfo] -and $_.FolderName -ieq $name }).Index }
foreach ($p in $written) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $game ($p -replace '/', '\')))
    $e = Find-Entry $arc $p
    if ($e) { $arc.ReplaceFile($e, $bytes); "  package: replaced $p" }
    else { $parts = $p -split '/'; $fi = if ($parts.Count -gt 1) { Folder-Index $parts[0] } else { $ROOT }; [void]$arc.AddFile($fi, $parts[-1], $bytes); "  package: added $p" }
}
foreach ($folder in $listAdds.Keys) {
    $le = Find-Entry $arc "$folder/list.xml"; $x = Get-XmlText ($arc.GetFileData($le))
    $ids = @(Get-PartList $x | ForEach-Object { [int]$_.id }); $id = ($ids | Measure-Object -Maximum).Maximum + 1
    $lines = ""
    foreach ($r in $listAdds[$folder]) {
        $lines += "        <part id='$id'   name='$($r[0])'          mesh='$($r[0])'      tex='$($r[1])'/>`r`n"
        "  $folder/list.xml + id $id name '$($r[0])' (texture $($r[1]))"
        # icon: the base variant's, under the new name (the shop shows it)
        $ic = Get-EntryBytes $arc "icon/$($Car)_$($folder)_$($r[2]).png"
        if ($ic -and -not (Find-Entry $arc "icon/$($Car)_$($folder)_$($r[0]).png")) { [void]$arc.AddFile((Folder-Index "icon"), "$($Car)_$($folder)_$($r[0]).png", $ic); Put "icon/$($Car)_$($folder)_$($r[0]).png" $ic; "  icon/$($Car)_$($folder)_$($r[0]).png (copy of the base's icon)" }
        $id++
    }
    $i = $x.LastIndexOf('</partlist>'); $x = $x.Substring(0, $i) + $lines + $x.Substring($i)
    $arc.ReplaceFile($le, (Get-Utf16Bytes $x)); Put "$folder/list.xml" (Get-Utf16Bytes $x)
}
$out = "$pkg\Data\car\$Car.jmd"
$arc.SaveAs($out)
$b = Open-Jmd $out
foreach ($p in $written) { if (-not [Linq.Enumerable]::SequenceEqual([byte[]](Get-EntryBytes $b $p), [byte[]][IO.File]::ReadAllBytes((Join-Path $game ($p -replace '/', '\'))))) { throw "read-back of $p differs" } }
"check: $($written.Count) files read back byte-identical from the package"
try { Update-FileInfo $FileInfo (Join-Path $pkg "FileInfo.0m") $pkg @("Data\car\$Car.jmd") } catch { "  FileInfo.0m not written: $($_.Exception.Message) (add the car to the launcher's file list by hand)" }
"PACKAGE OK $pkg"
