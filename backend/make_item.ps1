# Plate / windshield: turns the textures the workshop page sent (out\<kind>\<name>\texture.png, icon.png, request.json)
# into game-named files in out\<kind>\<name>\game\ (what package_items.ps1 adds to the archive). Game files are only read.
#   plate : common_plate_<name>.png (128x64), common_plate_<name>_s.dds (64x32 DXT, like the game's), icon/common_plate_<name>.png
#   glass : <name>.png (64x64), <name>_s.dds (32x32), <name>.xml (custom colours, UTF-16), icon/<name>.png
param([Parameter(Mandatory)][ValidateSet("plate", "glass")][string]$Kind, [Parameter(Mandatory)][string]$Name)
. (Join-Path $PSScriptRoot "common.ps1")
if ($Name -notmatch '^[a-z0-9_]{2,40}$') { throw "bad name" }
$dir = Join-Path $Workshop "out\$Kind\$Name"
$req = Get-Content (Join-Path $dir "request.json") -Raw | ConvertFrom-Json
$game = Join-Path $dir "game"
if (Test-Path $game) { Remove-Item -Recurse -Force $game }
[IO.Directory]::CreateDirectory("$game\icon") | Out-Null

$arcRel = "Data\car\common\$Kind.jmd"
$arc = Open-Jmd $arcRel
$list = Get-XmlText (Get-EntryBytes $arc "list.xml")
$rows = Get-PartList $list
$tex = if ($Kind -eq "plate") { "common_plate_$Name" } else { $Name }
if ($rows | Where-Object { $_.name -ieq $Name -or $_.tex -ieq $tex }) { throw "'$Name' is already used in the game's $Kind list.xml; pick another name" }

$png = Join-Path $dir "texture.png"
$img = Read-Bgra $png
$want = if ($Kind -eq "plate") { @(128, 64) } else { @(64, 64) }
if ($img.W -ne $want[0] -or $img.H -ne $want[1]) { throw "texture is $($img.W)x$($img.H), expected $($want[0])x$($want[1])" }
Copy-Item $png "$game\$tex.png"
# template DDS: the first game texture of this kind (same size and format as ours)
$tpl = if ($Kind -eq "plate") { Get-EntryBytes $arc "common_plate_default_s.dds" } else { Get-EntryBytes $arc "basic_k_s.dds" }
[IO.File]::WriteAllBytes("$game\$($tex)_s.dds", (New-FarDds $png $tpl))
Copy-Item (Join-Path $dir "icon.png") "$game\icon\$tex.png"
"$Kind $Name -> $game"
"  $tex.png ($($img.W)x$($img.H))"
"  $($tex)_s.dds (far copy, $([int]($img.W/2))x$([int]($img.H/2)), template " + $(if ($Kind -eq "plate") { "common_plate_default_s.dds" } else { "basic_k_s.dds" }) + ")"
"  icon/$tex.png"

$settings = $req.settings
if ($Kind -eq "glass") {
    $xml = "<?xml version='1.0' encoding='UTF-16'?>`r`n<part>`r`n`t<color>`r`n"
    if ($settings.custom) {
        $xml += "`t`t<custom>yes</custom>`r`n"
        $i = 0
        foreach ($c in $settings.colors) { $xml += "`t`t<color$i>255 $($c[0]) $($c[1]) $($c[2])</color$i>`r`n"; $i++ }
        $xml += "`t`t<customCount>$i</customCount>`r`n"
    } else { $xml += "`t`t<custom>no</custom>`r`n" }
    $xml += "`t</color>`r`n</part>`r`n"
    Set-Utf16 "$game\$Name.xml" $xml
    "  $Name.xml (" + $(if ($settings.custom) { "players pick $($settings.colors.Count) colour(s)" } else { "fixed colours" }) + ")"
}
$meta = '{"url":"/out/' + $Kind + '/' + $Name + '/texture.png","tex":"' + $tex + '","settings":' + ($settings | ConvertTo-Json -Compress -Depth 5) + '}'
Write-Utf8 (Join-Path $dir "meta.json") $meta
"OK"
