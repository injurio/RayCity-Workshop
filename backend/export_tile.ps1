# Read-only: one map tile (Data\field\<area>\<tile>.jmd) for the workshop's map viewer -> cache\map\<area>\
#   <tile>.json         ground/buildings mesh (world metres, Z up) with UV (base texture) + UV2 (render map / lightmap),
#                       one part per sub-mesh with its material number; materials [{tex, lm}] (PNG names)
#   <tile>_objects.json placed props (xref.jmd objects at the tile's ReXRefObj placements), untextured
#   tex\<name>.png      base textures and the tile's render maps (_completemap), DDS decoded
# Uses JMDReader: OmFieldMesh.TryParseTile, OmFieldObjects (placements + xref libraries), TextureCodec.DecodeDds.
param([Parameter(Mandatory)][string]$Area, [Parameter(Mandatory)][string]$Tile)
. (Join-Path $PSScriptRoot "common.ps1")
if ($Area -notmatch '^[a-z0-9_]+$' -or $Tile -notmatch '^[a-z0-9_]+$') { throw "bad tile name" }
$path = Join-Path $Ray "Data\field\$Area\$Tile.jmd"
if (-not (Test-Path $path)) { throw "no $path" }
$out = Join-Path $Workshop "cache\map\$Area"
[IO.Directory]::CreateDirectory("$out\tex") | Out-Null
$arc = Open-Jmd $path
$b = Get-EntryBytes $arc "$Tile.0m"
if ($null -eq $b) { throw "$Tile.jmd has no $Tile.0m" }
$ft = $null; $err = $null
if (-not [Raycity.Model.OmFieldMesh]::TryParseTile($b, [ref]$ft, [ref]$err)) { throw "tile: $err" }
$m = $ft.Mesh

# ---- textures: the tile's own _tex.jmd, then common_<area>\tex.jmd, then common\tex.jmd (the client's order)
$texArcs = @()
foreach ($p in [Raycity.Model.OmFieldTile]::GetTextureArchivePaths($path)) { if (Test-Path $p) { $texArcs += , @((Open-Jmd $p), $null) } }
foreach ($t in $texArcs) { $t[1] = @{}; foreach ($e in Get-AllEntries $t[0]) { $t[1][$e.ToLower()] = $e } }
$missing = @()
function Save-Tex([string]$name) {
    if (-not $name) { return "" }
    $key = ($name.ToLower() -replace '[^a-z0-9_@\-]', '_')
    if (Test-Path "$out\tex\$key.png") { return "$key.png" }
    $want = $name.ToLower() + ".dds"
    foreach ($t in $texArcs) {
        if (-not $t[1].ContainsKey($want)) { continue }
        $dds = Get-EntryBytes $t[0] $t[1][$want]
        $w = 0; $h = 0
        try { $bgra = [Raycity.Media.TextureCodec]::DecodeDds($dds, [ref]$w, [ref]$h) } catch { break }
        $bmp = New-Object Drawing.Bitmap($w, $h, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $d = $bmp.LockBits((New-Object Drawing.Rectangle(0, 0, $w, $h)), [Drawing.Imaging.ImageLockMode]::WriteOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [Runtime.InteropServices.Marshal]::Copy($bgra, 0, $d.Scan0, $bgra.Length)
        # neighbouring tiles are exported in parallel and share textures: write a private temp file, then move it in
        $tmp = "$out\tex\$key.$PID.tmp"
        $bmp.UnlockBits($d); $bmp.Save($tmp, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        try { [IO.File]::Move($tmp, "$out\tex\$key.png") } catch { Remove-Item $tmp -ErrorAction SilentlyContinue }
        return "$key.png"
    }
    $script:missing += $name
    ""
}
$mats = @()
foreach ($mt in $ft.Materials) { $mats += '{"tex":' + (ConvertTo-JsonString (Save-Tex $mt.BaseTexture)) + ',"lm":' + (ConvertTo-JsonString (Save-Tex $mt.Lightmap)) + ',"name":' + (ConvertTo-JsonString $mt.BaseTexture) + ',"lmName":' + (ConvertTo-JsonString $mt.Lightmap) + '}' }

# ---- mesh
$sb = New-Object Text.StringBuilder
[void]$sb.Append('{"tile":').Append((ConvertTo-JsonString $Tile)).Append(',"positions":[')
[void]$sb.Append((($m.Positions | ForEach-Object { (F $_.X) + ',' + (F $_.Y) + ',' + (F $_.Z) }) -join ','))
[void]$sb.Append('],"uvs":[').Append((($m.TextureCoordinates | ForEach-Object { (F $_.X) + ',' + (F $_.Y) }) -join ','))
[void]$sb.Append('],"uvs2":[').Append((($ft.LightmapCoordinates | ForEach-Object { (F $_.X) + ',' + (F $_.Y) }) -join ','))
[void]$sb.Append('],"normals":[],"parts":[')
for ($i = 0; $i -lt $m.Parts.Length; $i++) {
    $p = $m.Parts[$i]
    if ($i) { [void]$sb.Append(',') }
    $mat = if ($ft.PartMaterials -and $i -lt $ft.PartMaterials.Length) { $ft.PartMaterials[$i] } else { 0 }
    $idx = $p.Indices; $base = $p.BaseVertex
    [void]$sb.Append('{"name":"sub').Append($i).Append('","group":0,"cat":0,"mat":').Append($mat).Append(',"indices":[')
    [void]$sb.Append((($idx | ForEach-Object { $base + $_ }) -join ',')).Append(']}')
}
[void]$sb.Append('],"materials":[').Append(($mats -join ',')).Append('],"missing":[').Append((($missing | Select-Object -Unique | ForEach-Object { ConvertTo-JsonString $_ }) -join ',')).Append(']}')
Write-Utf8 "$out\$Tile.json" $sb.ToString()

# ---- placed props
$pl = [Raycity.Model.OmFieldObjects]::ReadPlacements($b)
$objs = '{"positions":[],"uvs":[],"normals":[],"parts":[]}'
$nObj = 0
if ($pl.Count) {
    $libs = [Raycity.Model.OmFieldObjects]::LoadLibraries($path)
    $miss = $null
    $pm = [Raycity.Model.OmFieldObjects]::BuildPlacedMesh($pl, $libs, [ref]$miss)
    if ($pm.Positions.Length) { $objs = ConvertTo-MeshJson $pm "objects"; $nObj = $pm.Parts.Length }
}
Write-Utf8 "$out\$($Tile)_objects.json" $objs
"ok $Tile $($m.Positions.Length) vertices, $($m.Parts.Length) parts, $($mats.Count) materials, $nObj placed objects, missing textures: $($missing.Count)"
