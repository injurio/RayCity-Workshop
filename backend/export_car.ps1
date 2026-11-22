# Read-only export of a game car for the 3D viewer -> workshop\cache\cars\<car>\
#   model.json : parts per folder (variants, default pick), textures, wheel info
#   meshes\*.json : LOD-2 meshes (body, every part variant, wheels)
#   tex\*.png : every PNG in the archive (folder/ -> folder__) + the wheel texture
param([Parameter(Mandatory)][string]$Car, [int]$Lod = 2, [string]$Path)
. (Join-Path $PSScriptRoot "common.ps1")
if ($Car -notmatch '^[\w\-]+$') { throw "bad car name" }
$out = Join-Path $Workshop "cache\cars\$Car"
$arc = Open-Jmd $(if ($Path) { $Path } else { "Data\car\$Car.jmd" })
[IO.Directory]::CreateDirectory("$out\meshes") | Out-Null
[IO.Directory]::CreateDirectory("$out\tex") | Out-Null

$all = Get-AllEntries $arc
foreach ($p in $all | Where-Object { $_ -like "*.png" -and $_ -notlike "icon/*" }) {
    [IO.File]::WriteAllBytes("$out\tex\" + ($p -replace "/", "__"), (Get-EntryBytes $arc $p))
}

function Save-Mesh([string]$path, [string]$file) {
    $b = Get-EntryBytes $arc $path
    if ($null -eq $b) { return $false }
    $m = [Raycity.Model.OmMesh]::Parse($b)
    Write-Utf8 "$out\meshes\$file.json" (ConvertTo-MeshJson $m $file (Get-MountsJson $b))
    $true
}

$bodyBytes = Get-EntryBytes $arc "body_$Lod.0m"
$body = [Raycity.Model.OmMesh]::Parse($bodyBytes)
# "Big" cars (Convert_car --game full, drawn by the landverse.dll mod): body_<L>.0m is only a 12-vertex stand-in and the
# real model is big_<L>.rcb in the car jmd (or Data\car\big\<id>_<L>.rcb). Layout, read from the file:
#   "RCB1", u32 version (2), u32 ?, u32 V, u32 I (body), u32 V2, u32 I2 (glass), zero-filled to byte 60;
#   body: V x 32-byte vertices (x y z, normal x y z, u v; game space, Z up) + I x u32 indices; glass block likewise;
#   u32 door count, then per door: u32 door, u32 kind (0 body, 1 window), u32 V, u32 I + its vertices and indices.
$rcb = Get-EntryBytes $arc "big_$Lod.rcb"
if ($null -ne $rcb) {
    Add-Type -Language CSharp -TypeDefinition @'
using System; using System.Text; using System.Globalization;
public static class WsRcb {
    static string F(float v) { return v.ToString("0.#####", CultureInfo.InvariantCulture); }
    public static string ToJson(byte[] b, out string info) {
        if (b.Length < 60 || Encoding.ASCII.GetString(b, 0, 4) != "RCB1") throw new Exception("not an RCB1 file");
        var P = new StringBuilder(); var N = new StringBuilder(); var U = new StringBuilder(); var parts = new StringBuilder();
        int o = 60, baseV = 0, nParts = 0; var sum = new StringBuilder();
        Action<int, int, string, int> block = (V, I, name, group) => {
            if (o + (long)V * 32 + (long)I * 4 > b.Length) throw new Exception("RCB block " + name + " runs past the end");
            for (int i = 0; i < V; i++) {
                int p = o + i * 32;
                if (P.Length > 0) { P.Append(','); N.Append(','); U.Append(','); }
                P.Append(F(BitConverter.ToSingle(b, p))).Append(',').Append(F(BitConverter.ToSingle(b, p + 4))).Append(',').Append(F(BitConverter.ToSingle(b, p + 8)));
                N.Append(F(BitConverter.ToSingle(b, p + 12))).Append(',').Append(F(BitConverter.ToSingle(b, p + 16))).Append(',').Append(F(BitConverter.ToSingle(b, p + 20)));
                U.Append(F(BitConverter.ToSingle(b, p + 24))).Append(',').Append(F(BitConverter.ToSingle(b, p + 28)));
            }
            o += V * 32;
            if (nParts++ > 0) parts.Append(',');
            parts.Append("{\"name\":\"").Append(name).Append("\",\"group\":").Append(group).Append(",\"cat\":0,\"indices\":[");
            for (int i = 0; i < I; i++) { if (i > 0) parts.Append(','); parts.Append(baseV + (int)BitConverter.ToUInt32(b, o + i * 4)); }
            parts.Append("]}");
            o += I * 4; baseV += V;
            sum.Append(name).Append(' ').Append(V).Append('/').Append(I).Append("; ");
        };
        block((int)BitConverter.ToUInt32(b, 12), (int)BitConverter.ToUInt32(b, 16), "big_body", 0);
        block((int)BitConverter.ToUInt32(b, 20), (int)BitConverter.ToUInt32(b, 24), "big_glass", 1);
        int doors = (int)BitConverter.ToUInt32(b, o); o += 4;
        for (int d = 0; d < doors; d++) {
            uint door = BitConverter.ToUInt32(b, o), kind = BitConverter.ToUInt32(b, o + 4); int V = (int)BitConverter.ToUInt32(b, o + 8), I = (int)BitConverter.ToUInt32(b, o + 12); o += 16;
            block(V, I, "big_door" + door + (kind == 1 ? "_window" : ""), kind == 1 ? 1 : 0);
        }
        if (o != b.Length) throw new Exception("RCB: " + (b.Length - o) + " bytes left over");
        info = sum.ToString();
        return "{\"label\":\"body\",\"positions\":[" + P + "],\"uvs\":[" + U + "],\"normals\":[" + N + "],\"parts\":[" + parts + "]}";
    }
}
'@
    $info = $null
    Write-Utf8 "$out\meshes\body.json" ([WsRcb]::ToJson($rcb, [ref]$info))
    "big body from big_$Lod.rcb: $info"
} else {
    Write-Utf8 "$out\meshes\body.json" (ConvertTo-MeshJson $body "body")
}

# Wheels: wheel.jmd default rim at the body's wheel mounts + a tyre cylinder (as JMDReader does).
$wa = Open-Jmd "Data\car\common\wheel.jmd"
$rim = [Raycity.Model.OmMesh]::Parse((Get-EntryBytes $wa "default_$Lod.0m"))
[IO.File]::WriteAllBytes("$out\tex\wheel.png", (Get-EntryBytes $wa "default.png"))
$tyre = [Raycity.Model.OmMesh]::Cylinder(0.34, 0.12, 28, "tyre")
$ms = New-Object 'System.Collections.Generic.List[Raycity.Model.OmMesh]'
$ls = New-Object 'System.Collections.Generic.List[string]'
$mounts = [Raycity.Model.OmMesh]::ReadCarMounts($bodyBytes)
$mountJson = @()
foreach ($mt in $mounts) {
    $mountJson += '{"slot":' + $mt.Key + ',"m":[' + (($mt.Value | ForEach-Object { F $_ }) -join ",") + ']}'
    if ($mt.Key -gt 1) { continue }
    $ms.Add($rim.Transformed($mt.Value)); $ls.Add("rim")
    $ms.Add($tyre.Transformed($mt.Value)); $ls.Add("tyre")
}
if ($ms.Count) { Write-Utf8 "$out\meshes\wheels.json" (ConvertTo-MeshJson ([Raycity.Model.OmMesh]::Merge($ms, $ls)) "wheels") }

# Part folders: every variant's mesh; default = name 'default', else none (the stock car has no such part).
$folders = @()
foreach ($e in $arc.GetEntries([uint32]::MaxValue)) {
    if ($e -isnot [Raycity.File.JMDPackedFolderInfo] -or $e.FolderName -eq "icon") { continue }
    $f = $e.FolderName
    $list = Get-XmlText (Get-EntryBytes $arc "$f/list.xml")
    if ($null -eq $list) { continue }
    $vars = @()
    $default = $null
    $seen = @{}
    foreach ($row in Get-PartList $list) {
        $mesh = $row["mesh"]; $tex = $row["tex"]
        $ok = $false
        if ($mesh) {
            $key = "$f" + "__" + $mesh
            if ($seen.ContainsKey($mesh)) { $ok = $seen[$mesh] } else { $ok = Save-Mesh "$f/$($mesh)_$Lod.0m" $key; $seen[$mesh] = $ok }
        }
        $texFile = if ($tex -and ($all -contains "$f/$tex.png")) { "$f" + "__" + "$tex.png" } elseif ($tex -and ($all -contains "$tex.png")) { "$tex.png" } else { "" }
        $v = '{"id":' + (ConvertTo-JsonString $row["id"]) + ',"name":' + (ConvertTo-JsonString $row["name"]) + ',"mesh":' + (ConvertTo-JsonString $(if ($ok) { "$f" + "__" + $mesh } else { "" })) + ',"tex":' + (ConvertTo-JsonString $texFile) + '}'
        $vars += $v
        if ($null -eq $default -and $row["name"] -eq "default") { $default = $row["id"] }
    }
    $folders += '{"folder":' + (ConvertTo-JsonString $f) + ',"default":' + (ConvertTo-JsonString $(if ($null -ne $default) { $default } else { "" })) + ',"variants":[' + ($vars -join ",") + ']}'
}

$json = '{"car":' + (ConvertTo-JsonString $Car) + ',"lod":' + $Lod +
    ',"base":' + (ConvertTo-JsonString "$Car`_base.png") + ',"color":' + (ConvertTo-JsonString "$Car`_color.png") +
    ',"mounts":[' + ($mountJson -join ",") + '],"folders":[' + ($folders -join ",") + ']}'
Write-Utf8 "$out\model.json" $json
"ok $out"
