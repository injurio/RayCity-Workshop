# New set effect from a game one: out\effect\<name>\ (request.json {template = effectGroup name, textures {<tex>: <png>}},
# tex\*.png) -> out\effect\<name>\game\relement\ (copies of the template's .0m files that use a replaced texture, the new
# textures) + relementeffect_add.xml / effectlink_add.xml (the lines package_effect.ps1 adds) + preview\ + meta.json.
# Game files are only read.
#   Texture names inside a .0m are 0x27AA string records (u16 id, u32 length, UTF-16 text). The new names have the SAME
#   length as the ones they replace, so no other byte of the file moves; the copy is re-parsed with JMDReader and must
#   have the same objects, geometry and transforms, with only the texture names changed.
#   New textures are encoded like the originals (same size, DDS format/mips or TGA layout: TextureCodec.Encode*Like).
#   Names: effect group EffectType_SetItem_WS_<name>, set-item option US_WS_<name>, files relement\ws_<name>[_n].0m.
param([Parameter(Mandatory)][string]$Name)
. (Join-Path $PSScriptRoot "common.ps1")
if ($Name -notmatch '^[a-z0-9_]{2,30}$') { throw "bad name" }
$dir = Join-Path $Workshop "out\effect\$Name"
$req = Get-Content (Join-Path $dir "request.json") -Raw | ConvertFrom-Json
$game = Join-Path $dir "game\relement"
foreach ($d in "game", "preview") { if (Test-Path "$dir\$d") { Remove-Item -Recurse -Force "$dir\$d" } }
[IO.Directory]::CreateDirectory($game) | Out-Null

$a = Open-Jmd "Data\effect\effect.jmd"
$all = Get-AllEntries $a
$x = Get-XmlText (Get-EntryBytes $a "relement/relementeffect.xml")
$links = Get-XmlText (Get-EntryBytes $a "relement/effectlink.xml")
$group = "EffectType_SetItem_WS_$Name"; $option = "US_WS_$Name"
if ($x -match "name=""$group""" -or $links -match "'$option'") { throw "$group / $option already exist in the game's effect lists" }

# ---- template: effectGroup -> items (full text) -> files
$tpl = [string]$req.template
$g = [regex]::Match($x, "<effectGroup\s+name=""$([regex]::Escape($tpl))"">(.*?)</effectGroup>", 's')
if (-not $g.Success) { throw "relementeffect.xml has no effectGroup $tpl" }
$items = @()
foreach ($it in [regex]::Matches($g.Groups[1].Value, "<item\s+name=""([^""]+)""")) {
    $iname = $it.Groups[1].Value
    $d = [regex]::Match($x, "<effectItem\s+name=""$([regex]::Escape($iname))""([^>]*?)(/>|>(.*?)</effectItem>)", 's')
    if (-not $d.Success) { throw "relementeffect.xml has no effectItem $iname" }
    $files = @([regex]::Matches($d.Value, "fileName\s*=\s*[""']([^""']+)") | ForEach-Object { $_.Groups[1].Value }) | Select-Object -Unique
    $items += @{ name = $iname; text = $d.Value; files = $files }
}
$legend = $links -match "effect='$([regex]::Escape($tpl))'\s+legend='true'"

# ---- replacement textures: same-length new names, encoded like the originals
$repl = @{}   # old texture name -> new name
$texIdx = 0
foreach ($p in $req.textures.PSObject.Properties) {
    $old = $p.Name
    $src = $all | Where-Object { $_ -ieq "relement/$old.dds" -or $_ -ieq "relement/$old.tga" } | Select-Object -First 1
    if (-not $src) { throw "effect.jmd has no relement texture $old" }
    $ext = [IO.Path]::GetExtension($src).TrimStart('.').ToLower()
    $L = $old.Length
    if ($L -lt 4) { throw "texture name $old is too short to replace" }
    $new = $null
    for ($k = 0; $k -lt 36 -and -not $new; $k++) {
        $core = "w" + "0123456789abcdefghijklmnopqrstuvwxyz"[($texIdx + $k) % 36] + "_" + $Name
        $cand = if ($core.Length -ge $L) { $core.Substring(0, $L) } else { $core + ("_" * ($L - $core.Length)) }
        if (($all | Where-Object { $_ -like "relement/$cand.*" }) -or $repl.Values -contains $cand) { continue }
        $new = $cand
    }
    if (-not $new) { throw "no free texture name of length $L" }
    $texIdx++
    $orig = Get-EntryBytes $a $src
    $w = 0; $h = 0
    if ($ext -eq "dds") { [void][Raycity.Media.TextureCodec]::DecodeDds($orig, [ref]$w, [ref]$h) } else { $w = [BitConverter]::ToUInt16($orig, 12); $h = [BitConverter]::ToUInt16($orig, 14) }
    $img = Read-Bgra (Join-Path $dir "tex\$($p.Value)")
    $bgra = if ($img.W -ne $w -or $img.H -ne $h) { [Raycity.Media.TextureCodec]::Resize($img.B, $img.W, $img.H, $w, $h) } else { $img.B }
    $enc = if ($ext -eq "dds") { [Raycity.Media.TextureCodec]::EncodeDdsLike($orig, $bgra, $w, $h) } else { [Raycity.Media.TextureCodec]::EncodeTgaLike($orig, $bgra, $w, $h) }
    [IO.File]::WriteAllBytes("$game\$new.$ext", $enc)
    "  texture $old ($w x $h $ext) -> relement/$new.$ext"
    $repl[$old] = $new
}

# ---- copies of the .0m files that use a replaced texture
function Patch-Names([byte[]]$b, [hashtable]$map) {
    $o = [byte[]]$b.Clone(); $n = 0
    foreach ($old in $map.Keys) {
        $u = [Text.Encoding]::Unicode.GetBytes($old); $nu = [Text.Encoding]::Unicode.GetBytes($map[$old])
        for ($i = 0; $i -le $o.Length - 8 - $u.Length; $i++) {
            if ($o[$i] -ne 0xAA -or $o[$i + 1] -ne 0x27 -or [BitConverter]::ToInt32($o, $i + 4) -ne $old.Length) { continue }
            $hit = $true
            for ($k = 0; $k -lt $u.Length; $k++) { if ($o[$i + 8 + $k] -ne $u[$k]) { $hit = $false; break } }
            if ($hit) { [Array]::Copy($nu, 0, $o, $i + 8, $nu.Length); $n++ }
        }
    }
    @{ bytes = $o; count = $n }
}
$fileMap = @{}   # old file -> new file
$allFiles = @($items | ForEach-Object { $_.files }) | Select-Object -Unique
$clone = @(); $usedTex = @{}
foreach ($f in $allFiles) {
    $p = $all | Where-Object { $_ -ieq "relement/$f.0m" } | Select-Object -First 1
    if (-not $p) { continue }
    $b = Get-EntryBytes $a $p
    try { $r0 = [Raycity.File.OmResource]::Parse($b) } catch { "  $f.0m: particle effect, kept as the game's"; continue }
    $uses = @($r0.Nodes | Where-Object { $_.TextureName -and $repl.ContainsKey($_.TextureName) })
    if (-not $uses.Count) { "  $f.0m: no replaced texture, the new effect uses the game's file"; continue }
    foreach ($u in $uses) { $usedTex[$u.TextureName] = 1 }
    $clone += , @($f, $b, $r0)
}
$fi = 0
foreach ($c in $clone) {
    $f = $c[0]; $b = $c[1]; $r0 = $c[2]
    $res = Patch-Names $b $repl
    $nf = if ($clone.Count -gt 1) { "ws_$($Name)_$fi" } else { "ws_$Name" }; $fi++
    if ($all | Where-Object { $_ -ieq "relement/$nf.0m" }) { throw "effect.jmd already has relement/$nf.0m" }
    # check: same objects / geometry / transforms, only the texture names changed
    $r1 = [Raycity.File.OmResource]::Parse($res.bytes)
    if ($res.bytes.Length -ne $b.Length) { throw "check: size changed" }
    if (($r0.GetClassCounts() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "," -ne (($r1.GetClassCounts() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ",")) { throw "check: objects differ after renaming" }
    if ($r0.TriLists.Count -ne $r1.TriLists.Count) { throw "check: planes differ" }
    for ($i = 0; $i -lt $r0.Nodes.Count; $i++) {
        $t0 = $r0.Nodes[$i].TextureName; $t1 = $r1.Nodes[$i].TextureName
        $want = if ($t0 -and $repl.ContainsKey($t0)) { $repl[$t0] } else { $t0 }
        if ($t1 -ne $want) { throw "check: node $i texture '$t1', expected '$want'" }
        if ((($r0.Nodes[$i].GetWorldMatrix(500)) -join ",") -ne (($r1.Nodes[$i].GetWorldMatrix(500)) -join ",")) { throw "check: node $i transform differs" }
    }
    $diff = 0; for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -ne $res.bytes[$i]) { $diff++ } }
    [IO.File]::WriteAllBytes("$game\$nf.0m", $res.bytes)
    "  $f.0m -> relement/$nf.0m: $($res.count) texture name(s) changed ($diff bytes), re-parsed: same $($r1.TriLists.Count) planes, objects and transforms"
    $fileMap[$f] = $nf
}
if (-not $fileMap.Count) { throw "none of the template's files uses the textures you changed" }
foreach ($old in @($repl.Keys)) {
    if ($usedTex.ContainsKey($old)) { continue }
    Get-ChildItem $game -File | Where-Object { $_.BaseName -eq $repl[$old] } | Remove-Item
    "  texture $old is not used by this effect's files; left out"
}

# ---- xml lines for the package
$newItems = @(); $itemXml = ""
for ($i = 0; $i -lt $items.Count; $i++) {
    $it = $items[$i]
    $nn = if ($items.Count -gt 1) { "$($group)_$i" } else { $group }
    $t = [regex]::Replace($it.text, "name=""$([regex]::Escape($it.name))""", "name=""$nn""", 1)
    foreach ($of in $fileMap.Keys) { $t = [regex]::Replace($t, "fileName(\s*=\s*)([""'])$([regex]::Escape($of))\2", "fileName`$1`$2$($fileMap[$of])`$2", 'IgnoreCase') }
    $itemXml += "`t`t" + $t + "`r`n"
    $newItems += $nn
}
$groupXml = "`r`n`t<!-- workshop: $Name (from $tpl) -->`r`n`t<effectGroup name=""$group"">`r`n" + (($newItems | ForEach-Object { "`t`t<item name=""$_""/>" }) -join "`r`n") + "`r`n`t</effectGroup>`r`n" + $itemXml
$linkXml = "`t<option name='$option' effect='$group'" + $(if ($legend) { " legend='true'" } else { "" }) + "/>`r`n"
[IO.File]::WriteAllText((Join-Path $dir "relementeffect_add.xml"), $groupXml, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $dir "effectlink_add.xml"), $linkXml, (New-Object Text.UTF8Encoding($false)))
"  relementeffect.xml + effectGroup $group (" + ($newItems -join ", ") + ")"
"  effectlink.xml + option $option" + $(if ($legend) { " (legend)" } else { "" })

# ---- preview of the copied files (the others are the game's)
foreach ($nf in $fileMap.Values) {
    & (Join-Path $PSScriptRoot "export_effect.ps1") -File $nf -Path "$game\$nf.0m" -TexDir $game -OutDir (Join-Path $dir "preview") | Out-Null
}
# meta: the effect in the same shape as the catalog rows, with the new names
$sb = New-Object Text.StringBuilder
foreach ($k in $fileMap.Keys) { [void]$sb.Append((ConvertTo-JsonString $k)).Append(':').Append((ConvertTo-JsonString $fileMap[$k])).Append(',') }
$firstTex = @($req.textures.PSObject.Properties)[0].Value
Write-Utf8 (Join-Path $dir "meta.json") ('{"url":"/out/effect/' + $Name + '/tex/' + $firstTex + '","template":' + (ConvertTo-JsonString $tpl) + ',"group":' + (ConvertTo-JsonString $group) +
    ',"option":' + (ConvertTo-JsonString $option) + ',"files":{' + $sb.ToString().TrimEnd(',') + '}}')
"OK  set items that should show it use the option $option"
