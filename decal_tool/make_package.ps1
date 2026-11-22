# Adds finished decals (out\<name>\ from make_decal.ps1) to COPIES of the game's decal archives -> out\package\.
# Game files are only READ. Copy out\package\ over a test copy of the client, never over the real Data folder.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File make_package.ps1 -Names samui_wave,samui_logo [-StartId 1001]
#
# Changes: Data\car\common\decal4.jmd   + decal_<name>.png, decal_<name>_s.dds, <name>.xml, icon/<name>.png
#          Data\car\common\decalinfo.jmd  list.xml + <part id='N' name='<name>' tex='decal_<name>'/>
#          FileInfo.0m                    the two archives' size + block hashes
param([Parameter(Mandatory = $true)][string[]]$Names, [int]$StartId = 0,
      [string]$FileInfo = '')  # the client's file list (read only); default <client>\FileInfo.0m
$ErrorActionPreference = 'Stop'
$Names = @($Names | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$here = $PSScriptRoot
# Client folder + JmdLibrary.dll from the Workshop's workshop.config.json (this folder is inside the Workshop, or next to it)
$ws = @((Join-Path $here '..'), (Join-Path $here '..\workshop'), (Join-Path $here '..\..'), (Join-Path $here '..\..\workshop')) | Where-Object { Test-Path (Join-Path $_ 'backend\paths.ps1') } | Select-Object -First 1
if (-not $ws) { throw 'RayCity Workshop not found next to decal_tool' }
. (Join-Path $ws 'backend\paths.ps1')
$ray = $GameRoot
if (-not $FileInfo) { $FileInfo = $ClientFileInfo }
Add-Type -Path $JmdDll
$pkg = Join-Path $here 'out\package'
if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
New-Item -ItemType Directory -Force (Join-Path $pkg 'Data\car\common') | Out-Null
$ROOT = [uint32]::MaxValue
$U16 = New-Object Text.UnicodeEncoding $false, $true
$log = New-Object Collections.Generic.List[string]
function Log($s) { $log.Add($s); $s }
function Name($e) { if ($e -is [Raycity.File.JMDPackedFileInfo]) { $e.FileName + '.' + $e.Extension } else { $e.FolderName } }
function Get($a, [uint32]$f, [string]$n) { @($a.GetEntries($f)) | Where-Object { (Name $_) -eq $n } | Select-Object -First 1 }
function Folder($a, [uint32]$f, [string]$n) { (@($a.GetEntries($f)) | Where-Object { $_ -is [Raycity.File.JMDPackedFolderInfo] -and $_.FolderName -eq $n }).Index }

# ---- decalinfo list.xml: ids and names already used
$info = New-Object Raycity.File.JmdArchive((Join-Path $ray 'Data\car\common\decalinfo.jmd'))
$le = Get $info $ROOT 'list.xml'
$raw = $info.GetFileData($le)
$x = [Text.Encoding]::Unicode.GetString($raw, 2, $raw.Length - 2)  # skip BOM
$ids = [regex]::Matches($x, "id='(\d+)'") | ForEach-Object { [int]$_.Groups[1].Value }
$used = [regex]::Matches($x, "name='([^']+)'") | ForEach-Object { $_.Groups[1].Value.ToLower() }
$id = if ($StartId) { $StartId } else { ($ids | Measure-Object -Maximum).Maximum + 1 }

$a = New-Object Raycity.File.JmdArchive((Join-Path $ray 'Data\car\common\decal4.jmd'))
$icons = Folder $a $ROOT 'icon'
$lines = ''
foreach ($n in $Names) {
    $src = Join-Path $here "out\$n"
    foreach ($f in "decal_$n.png", "decal_$($n)_s.dds", "$n.xml", "icon_$n.png") { if (-not (Test-Path (Join-Path $src $f))) { throw "missing $src\$f (run make_decal.ps1 first)" } }
    if ($used -contains $n.ToLower()) { throw "decal name '$n' is already in the game's list.xml" }
    while ($ids -contains $id) { $id++ }
    foreach ($f in "decal_$n.png", "decal_$($n)_s.dds", "$n.xml") {
        if (Get $a $ROOT $f) { throw "decal4.jmd already has $f" }
        [void]$a.AddFile($ROOT, $f, [IO.File]::ReadAllBytes((Join-Path $src $f)))
    }
    [void]$a.AddFile($icons, "$n.png", [IO.File]::ReadAllBytes((Join-Path $src "icon_$n.png")))
    $lines += "        <part id='$id'`tname='$n'                tex='decal_$n'/>`r`n"
    Log "decal4.jmd: + decal_$n.png, decal_$($n)_s.dds, $n.xml, icon/$n.png   (decal id $id)"
    $ids += $id; $id++
}
$a.SaveAs((Join-Path $pkg 'Data\car\common\decal4.jmd'))
$x = $x.Replace('</partlist>', $lines + '</partlist>')
$info.ReplaceFile($le, $U16.GetPreamble() + [Text.Encoding]::Unicode.GetBytes($x))
$info.SaveAs((Join-Path $pkg 'Data\car\common\decalinfo.jmd'))
Log "decalinfo.jmd: list.xml +"
$lines.TrimEnd() -split "`r`n" | ForEach-Object { Log ("    " + $_.Trim()) }

# ---- FileInfo.0m copy (client file list: size + Adler-32 per 1 MB block)
Log "FileInfo source: $FileInfo"
$tree = [Raycity.Model.OmUserProperties]::ParseHeaderless([IO.File]::ReadAllBytes($FileInfo))
foreach ($rel in 'Data\car\common\decal4.jmd', 'Data\car\common\decalinfo.jmd') {
    $path = Join-Path $pkg $rel
    $size = (Get-Item $path).Length
    $hashes = [Raycity.Model.ClientFileInfo]::BlockHashes($path)
    $entry = $tree.Children | Where-Object { ($_.Pairs | Where-Object { $_.Key -eq 'fileName' }).Value -eq $rel } | Select-Object -First 1
    if (-not $entry) { throw "FileInfo.0m has no entry for $rel" }
    for ($i = 0; $i -lt $entry.Pairs.Count; $i++) {
        if ($entry.Pairs[$i].Key -eq 'size') { $entry.Pairs[$i] = New-Object 'Collections.Generic.KeyValuePair[string,string]' 'size', "$size" }
    }
    [void]$entry.Children.RemoveAll([Predicate[Raycity.Model.OmUserProperties]] { param($c) $c.Name -eq 'Hash' })
    for ($i = 0; $i -lt $hashes.Count; $i++) {
        $h = [Raycity.Model.OmUserProperties]::Create('Hash', '')
        $h.Pairs.Add((New-Object 'Collections.Generic.KeyValuePair[string,string]' 'idx', "$i"))
        $h.Pairs.Add((New-Object 'Collections.Generic.KeyValuePair[string,string]' 'value', "$($hashes[$i])"))
        $entry.Children.Add($h)
    }
    Log ("FileInfo: updated {0} (size {1}, {2} block hashes)" -f $rel, $size, $hashes.Count)
}
[IO.File]::WriteAllBytes((Join-Path $pkg 'FileInfo.0m'), $tree.ToBytes())

# ---- read-back check
$b = New-Object Raycity.File.JmdArchive((Join-Path $pkg 'Data\car\common\decal4.jmd'))
foreach ($n in $Names) {
    $e = Get $b $ROOT "decal_$n.png"
    $same = [Linq.Enumerable]::SequenceEqual([byte[]]$b.GetFileData($e), [byte[]][IO.File]::ReadAllBytes((Join-Path $here "out\$n\decal_$n.png")))
    if (-not $same) { throw "read-back of decal_$n.png differs" }
}
$orig = New-Object Raycity.File.JmdArchive((Join-Path $ray 'Data\car\common\decal4.jmd'))
$cnt0 = @($orig.GetEntries($ROOT)).Count; $cnt1 = @($b.GetEntries($ROOT)).Count
Log "check: decal4.jmd root entries $cnt0 -> $cnt1, new decals read back byte-identical"
[IO.File]::WriteAllLines((Join-Path $pkg 'package_log.txt'), $log)
"PACKAGE OK $pkg"
