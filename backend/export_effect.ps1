# Read-only: a scene effect (effect.jmd relement\<file>.0m, root "rootRelement") for the viewer ->
#   cache\effects\<file>.json : every textured plane (JMDReader OmResource TriLists) in its node's space, plus the node's
#                                scene matrix sampled every 1/30 s over the effect's length (JMDReader OmSceneNode, the
#                                client's PRS/visibility tracks) and whether it sits under a ReBillboard
#   cache\effects\tex\<tex>.png : its textures (relement\<tex>.dds/.tga, decoded)
# -Path/-TexDir: one of our own effects (out\effect\<name>\game\relement\) instead of the game's.
# Not read (JMDReader skips them): FloatTontroller tracks (fades) and AlphaProperty (blend mode); the viewer adds glow.
param([Parameter(Mandatory)][string]$File, [string]$Path, [string]$TexDir, [string]$OutDir)
. (Join-Path $PSScriptRoot "common.ps1")
if ($File -notmatch '^[\w\-]+$') { throw "bad file name" }
$out = if ($OutDir) { $OutDir } else { Join-Path $Workshop "cache\effects" }
[IO.Directory]::CreateDirectory("$out\tex") | Out-Null
$a = Open-Jmd "Data\effect\effect.jmd"
$all = Get-AllEntries $a
$bytes = if ($Path) { [IO.File]::ReadAllBytes($Path) } else {
    $p = $all | Where-Object { $_ -ieq "relement/$File.0m" } | Select-Object -First 1
    if (-not $p) { throw "effect.jmd has no relement/$File.0m" }
    Get-EntryBytes $a $p
}
$r = [Raycity.File.OmResource]::Parse($bytes)
if (-not $r.HasSceneGraph -or -not $r.TriLists.Count) { throw "$File is a particle effect (ReFx emitters); JMDReader can't read those yet" }

# ---- length: last key of any node track
$end = 0
foreach ($n in $r.Nodes) {
    $an = $n.Animation
    if ($an) { foreach ($t in @($an.Position, $an.Scale) + @($an.PositionXyz) + @($an.RotationXyz)) { if ($t -and $t.Times -and $t.Times.Length) { $end = [Math]::Max($end, [int]$t.Times[$t.Times.Length - 1]) } } }
    if ($n.Visibility -and $n.Visibility.Times.Length) { $end = [Math]::Max($end, [int]$n.Visibility.Times[$n.Visibility.Times.Length - 1]) }
}
$step = 1000.0 / 30
$count = [Math]::Max(1, [int][Math]::Floor($end / $step) + 1)

# ---- textures
function Save-Tex([string]$name) {
    if (-not $name) { return "" }
    $key = $name.ToLower()
    $png = "$out\tex\$key.png"
    if (Test-Path $png) { return "$key.png" }
    $b = $null
    foreach ($ext in "dds", "tga") {
        if ($TexDir -and (Test-Path "$TexDir\$name.$ext")) { $b = [IO.File]::ReadAllBytes("$TexDir\$name.$ext"); break }
        $p = $all | Where-Object { $_ -ieq "relement/$name.$ext" -or $_ -ieq "$name.$ext" } | Select-Object -First 1
        if ($p) { $b = Get-EntryBytes $a $p; break }
    }
    if ($null -eq $b) { return "" }
    $w = 0; $h = 0
    if ([Raycity.Media.TextureCodec]::IsTga($b)) { $bgra = Read-Tga $b ([ref]$w) ([ref]$h) } else { $bgra = [Raycity.Media.TextureCodec]::DecodeDds($b, [ref]$w, [ref]$h) }
    $bmp = New-Object Drawing.Bitmap($w, $h, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $d = $bmp.LockBits((New-Object Drawing.Rectangle(0, 0, $w, $h)), [Drawing.Imaging.ImageLockMode]::WriteOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    for ($y = 0; $y -lt $h; $y++) { [Runtime.InteropServices.Marshal]::Copy($bgra, $y * $w * 4, [IntPtr]($d.Scan0.ToInt64() + $y * $d.Stride), $w * 4) }
    $bmp.UnlockBits($d); $bmp.Save($png, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    "$key.png"
}
# Uncompressed / RLE true-colour TGA -> BGRA top-down
function Read-Tga([byte[]]$b, [ref]$OutW, [ref]$OutH) {
    # (PowerShell names ignore case: keep the size in $tw/$th so they don't clash with the [ref] parameters)
    $idLen = $b[0]; $type = $b[2]; $tw = [int][BitConverter]::ToUInt16($b, 12); $th = [int][BitConverter]::ToUInt16($b, 14); $bpp = $b[16] / 8; $top = ($b[17] -band 0x20) -ne 0
    $px = New-Object byte[] ($tw * $th * 4); $i = 18 + $idLen; $n = 0
    while ($n -lt $tw * $th) {
        $run = 1; $raw = $true
        if ($type -eq 10) { $c = $b[$i]; $i++; $run = ($c -band 0x7F) + 1; $raw = ($c -band 0x80) -eq 0 }
        for ($k = 0; $k -lt $run; $k++) {
            $o = $n * 4
            $px[$o] = $b[$i]; $px[$o + 1] = $b[$i + 1]; $px[$o + 2] = $b[$i + 2]; $px[$o + 3] = $(if ($bpp -eq 4) { $b[$i + 3] } else { 255 })
            if ($raw -or $type -ne 10) { $i += $bpp }
            $n++
        }
        if (-not $raw -and $type -eq 10) { $i += $bpp }
    }
    if (-not $top) { $f = New-Object byte[] $px.Length; for ($y = 0; $y -lt $th; $y++) { [Array]::Copy($px, $y * $tw * 4, $f, ($th - 1 - $y) * $tw * 4, $tw * 4) }; $px = $f }
    $OutW.Value = $tw; $OutH.Value = $th; , $px
}

$sb = New-Object Text.StringBuilder
[void]$sb.Append('{"file":').Append((ConvertTo-JsonString $File)).Append(',"length":').Append($end).Append(',"step":').Append((F $step)).Append(',"frames":').Append($count).Append(',"nodes":[')
$first = $true
foreach ($t in $r.TriLists) {
    $node = $t.Node
    if ($null -eq $node) { continue }
    $bill = $false
    for ($q = $node; $q; $q = $q.Parent) { if ($q.Object.ClassName -eq "ReBillboard") { $bill = $true } }
    if (-not $first) { [void]$sb.Append(',') }; $first = $false
    [void]$sb.Append('{"name":').Append((ConvertTo-JsonString $node.Object.Name)).Append(',"tex":').Append((ConvertTo-JsonString (Save-Tex $node.TextureName))).Append(',"texName":').Append((ConvertTo-JsonString $node.TextureName))
    [void]$sb.Append(',"billboard":').Append($(if ($bill) { "true" } else { "false" })).Append(',"positions":[')
    [void]$sb.Append((($t.Positions | ForEach-Object { (F $_.X) + ',' + (F $_.Y) + ',' + (F $_.Z) }) -join ','))
    [void]$sb.Append('],"uvs":[')
    $uv = if ($t.TextureCoordinates -and $t.TextureCoordinates.Length) { $t.TextureCoordinates[0] } else { @() }
    [void]$sb.Append((($uv | ForEach-Object { (F $_.X) + ',' + (F $_.Y) }) -join ','))
    [void]$sb.Append('],"indices":[').Append(($t.Indices -join ',')).Append('],"m":[')
    $ms = @(); $vis = @()
    for ($i = 0; $i -lt $count; $i++) {
        $time = [uint32][Math]::Round($i * $step)
        $ms += (($node.GetWorldMatrix($time) | ForEach-Object { F $_ }) -join ',')
        $vis += $(if ($node.IsVisible($time)) { 1 } else { 0 })
    }
    [void]$sb.Append(($ms -join ',')).Append('],"vis":[').Append(($vis -join ',')).Append(']}')
}
[void]$sb.Append(']}')
Write-Utf8 "$out\$($File.ToLower()).json" $sb.ToString()
"ok $File $count frames, $($r.TriLists.Count) planes"
