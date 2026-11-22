# Roof accessory: out\lamp\<name>\ (model.obj, texture.png 64x64, icon.png, request.json {effect, transform}) -> game files in
# out\lamp\<name>\game\ + preview.json. Game files are only read.
#   <name>_0/1/2.0m          the model as one draw part, made from copies of lamp.jmd taxi_box_<L>.0m with JMDReader's
#                            OmObjImport.ReplaceCarGeometry (the same geometry in all three LODs)
#   lamp_<name>.png/_s.dds   64x64 texture + 32x32 far copy; the model's UVs are squeezed into the car texture's
#                            lamp slot (0, 0.375, 0.125, 0.5), where the game draws the accessory's texture
#   icon/common_lamp_<name>.png, and <name>.xml with <lampEffect name='...'/> when a glow effect was chosen
param([Parameter(Mandatory)][string]$Name)
. (Join-Path $PSScriptRoot "common.ps1")
if ($Name -notmatch '^[a-z0-9_]{2,40}$') { throw "bad name" }
$dir = Join-Path $Workshop "out\lamp\$Name"
$req = Get-Content (Join-Path $dir "request.json") -Raw | ConvertFrom-Json
$game = Join-Path $dir "game"
if (Test-Path $game) { Remove-Item -Recurse -Force $game }
[IO.Directory]::CreateDirectory("$game\icon") | Out-Null

$arc = Open-Jmd "Data\car\common\lamp.jmd"
$rows = Get-PartList (Get-XmlText (Get-EntryBytes $arc "list.xml"))
if ($rows | Where-Object { $_.name -ieq $Name -or $_.mesh -ieq $Name }) { throw "'$Name' is already used in lamp.jmd list.xml; pick another name" }
if (Find-Entry $arc "$($Name)_2.0m") { throw "lamp.jmd already has $($Name)_2.0m" }

# ---- OBJ -> one part, user transform baked in (relative to the roof mount), UVs into the lamp slot
$t = @($req.transform | ForEach-Object { [double]$_ })
if ($t.Count -ne 12) { $t = @(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0) }
$inv = [Globalization.CultureInfo]::InvariantCulture
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine("# workshop roof accessory $Name")
$nv = 0; $nf = 0; $hasVt = $false
$nm = @(0, 0, 0)
foreach ($line in [IO.File]::ReadAllLines((Join-Path $dir "model.obj"))) {
    $a = $line.Trim() -split '\s+'
    switch ($a[0]) {
        'v' {
            $x = [double]::Parse($a[1], $inv); $y = [double]::Parse($a[2], $inv); $z = [double]::Parse($a[3], $inv)
            $X = $t[0] * $x + $t[1] * $y + $t[2] * $z + $t[3]; $Y = $t[4] * $x + $t[5] * $y + $t[6] * $z + $t[7]; $Z = $t[8] * $x + $t[9] * $y + $t[10] * $z + $t[11]
            [void]$sb.AppendLine(("v {0} {1} {2}" -f $X.ToString("R", $inv), $Y.ToString("R", $inv), $Z.ToString("R", $inv))); $nv++
        }
        'vn' {
            $x = [double]::Parse($a[1], $inv); $y = [double]::Parse($a[2], $inv); $z = [double]::Parse($a[3], $inv)
            $X = $t[0] * $x + $t[1] * $y + $t[2] * $z; $Y = $t[4] * $x + $t[5] * $y + $t[6] * $z; $Z = $t[8] * $x + $t[9] * $y + $t[10] * $z
            $l = [Math]::Sqrt($X * $X + $Y * $Y + $Z * $Z); if ($l -eq 0) { $l = 1 }
            [void]$sb.AppendLine(("vn {0} {1} {2}" -f ($X / $l).ToString("R", $inv), ($Y / $l).ToString("R", $inv), ($Z / $l).ToString("R", $inv)))
        }
        'vt' {
            # OBJ v is bottom-up; the game's is top-down
            $u = [Math]::Min(1.0, [Math]::Max(0.0, [double]::Parse($a[1], $inv))); $v = [Math]::Min(1.0, [Math]::Max(0.0, [double]::Parse($a[2], $inv)))
            [void]$sb.AppendLine(("vt {0} {1}" -f (0.125 * $u).ToString("R", $inv), (0.375 + 0.125 * (1 - $v)).ToString("R", $inv))); $hasVt = $true
        }
        'f' { if ($nf -eq 0) { [void]$sb.AppendLine("o part_1") }; [void]$sb.AppendLine($line.Trim()); $nf++ }
    }
}
if ($nv -eq 0 -or $nf -eq 0) { throw "the OBJ has no vertices or faces" }
if ($nv -gt 65000) { throw "the OBJ has $nv vertices; the game's format allows at most 65 000 per part" }
if (-not $hasVt) { "warning: the OBJ has no UVs, the whole model will use one texel of the texture" }
$objText = $sb.ToString()
[IO.File]::WriteAllText((Join-Path $dir "model_game.obj"), $objText)

foreach ($L in 0, 1, 2) {
    $tpl = Get-EntryBytes $arc "taxi_box_$L.0m"
    $report = $null
    $bytes = [Raycity.Model.OmObjImport]::ReplaceCarGeometry($tpl, $objText, [ref]$report)
    $check = [Raycity.Model.OmMesh]::Parse($bytes)
    [IO.File]::WriteAllBytes("$game\$($Name)_$L.0m", $bytes)
    "  $($Name)_$L.0m: $($check.VertexCount) vertices, $($check.TriangleCount) triangles, $($check.Parts.Length) part (re-parsed OK)"
    if ($L -eq 2) { Write-Utf8 (Join-Path $dir "preview.json") (ConvertTo-MeshJson $check $Name) }
}

$tex = "lamp_$Name"
$png = Join-Path $dir "texture.png"
$img = Read-Bgra $png
if ($img.W -ne 64 -or $img.H -ne 64) { throw "texture is $($img.W)x$($img.H), expected 64x64" }
Copy-Item $png "$game\$tex.png"
[IO.File]::WriteAllBytes("$game\$($tex)_s.dds", (New-FarDds $png (Get-EntryBytes $arc "white_taxi_s.dds")))
Copy-Item (Join-Path $dir "icon.png") "$game\icon\common_lamp_$Name.png"
"  $tex.png, $($tex)_s.dds, icon/common_lamp_$Name.png"
$effect = [string]$req.effect
if ($effect) {
    if ($effect -notmatch '^EffectType_Lamp_\w+$') { throw "bad effect name" }
    Set-Utf16 "$game\$Name.xml" "<?xml version='1.0' encoding='UTF-16'?>`r`n<part>`r`n`t<lampEffect name = '$effect'/> `r`n</part>`r`n"
    "  $Name.xml: lampEffect $effect"
}
$meta = '{"url":"/out/lamp/' + $Name + '/texture.png","mesh":"/out/lamp/' + $Name + '/preview.json","effect":' + (ConvertTo-JsonString $effect) + '}'
Write-Utf8 (Join-Path $dir "meta.json") $meta
"OK"
