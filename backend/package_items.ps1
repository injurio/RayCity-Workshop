# Adds finished plates / windshields / roof accessories (out\<kind>\<name>\game\) to a COPY of the game archive
# -> out\package\<kind>\ in the client folder layout, plus a FileInfo.0m copy. Game files are only read.
#   plate : Data\car\common\plate.jmd  + common_plate_<n>.png/_s.dds, icon/common_plate_<n>.png; list.xml + <part id name tex/>
#   glass : Data\car\common\glass.jmd  + <n>.png/_s.dds/.xml, icon/<n>.png;                        list.xml + <part id name tex/>
#   lamp  : Data\car\common\lamp.jmd   + <n>_0/1/2.0m, lamp_<n>.png/_s.dds, [<n>.xml], icon/common_lamp_<n>.png; list.xml + <part id name mesh tex/>
#   wheel : Data\car\common\wheel.jmd  + <n>.png/_s.dds, [<n>_0/1/2.0m, <n>wide_0/1/2.0m], icon/common_wheel_<row>.png;
#           list.xml + one <part id name mesh tex/> per line of out\wheel\<n>\parts.txt (normal + wide version)
param([Parameter(Mandatory)][ValidateSet("plate", "glass", "lamp", "wheel")][string]$Kind, [Parameter(Mandatory)][string[]]$Names, [int]$StartId = 0,
      [string]$FileInfo = '')  # the test client's file list (read only)
. (Join-Path $PSScriptRoot "common.ps1")
if (-not $FileInfo) { $FileInfo = $ClientFileInfo }
$Names = @($Names | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$rel = "Data\car\common\$Kind.jmd"
$pkg = Join-Path $Workshop "out\package\$Kind"
if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
[IO.Directory]::CreateDirectory((Join-Path $pkg "Data\car\common")) | Out-Null
$log = New-Object Collections.Generic.List[string]
function Log($s) { $log.Add($s); $s }
$ROOT = [uint32]::MaxValue

$a = Open-Jmd $rel
$le = Find-Entry $a "list.xml"
$x = Get-XmlText ($a.GetFileData($le))
$rows = Get-PartList $x
$ids = @($rows | ForEach-Object { [int]$_.id })
$id = if ($StartId) { $StartId } else { ($ids | Measure-Object -Maximum).Maximum + 1 }
$iconFolder = ($a.GetEntries($ROOT) | Where-Object { $_ -is [Raycity.File.JMDPackedFolderInfo] -and $_.FolderName -eq "icon" }).Index
$lines = ""
$added = @()
foreach ($n in $Names) {
    if ($n -notmatch '^[a-z0-9_]{2,40}$') { throw "bad name $n" }
    $src = Join-Path $Workshop "out\$Kind\$n\game"
    if (-not (Test-Path $src)) { throw "missing $src (make the $Kind first)" }
    # wheel: one list row per line of parts.txt (name|mesh|tex: the normal and the wide version)
    # (assigned directly: an if-expression's output would unroll @(, @(n, n, n)) into three loose strings)
    if ($Kind -eq "wheel") { $rowDefs = @(Get-Content (Join-Path $Workshop "out\wheel\$n\parts.txt") | Where-Object { $_ } | ForEach-Object { , ($_ -split '\|') }) }
    else { $rowDefs = @(, @($n, $n, $n)) }
    foreach ($rd in $rowDefs) { if ($rows | Where-Object { $_.name -ieq $rd[0] }) { throw "'$($rd[0])' is already in the game's $Kind list.xml" } }
    foreach ($f in Get-ChildItem $src -File) {
        if (Find-Entry $a $f.Name) { throw "$Kind.jmd already has $($f.Name)" }
        [void]$a.AddFile($ROOT, $f.Name, [IO.File]::ReadAllBytes($f.FullName)); $added += $f.FullName
        Log "  + $($f.Name)"
    }
    foreach ($f in Get-ChildItem "$src\icon" -File) {
        if (Find-Entry $a "icon/$($f.Name)") { throw "$Kind.jmd already has icon/$($f.Name)" }
        [void]$a.AddFile($iconFolder, $f.Name, [IO.File]::ReadAllBytes($f.FullName)); Log "  + icon/$($f.Name)"
    }
    foreach ($rd in $rowDefs) {
        while ($ids -contains $id) { $id++ }
        $line = switch ($Kind) {
            "plate" { "      <part id='$id'   name='$n'          tex='common_plate_$n'      />" }
            "glass" { "        <part id='$id'   name='$n'        tex='$n'      />" }
            "lamp"  { "        <part id='$id'   name='$n'                  mesh='$n'                 tex='lamp_$n'       />" }
            "wheel" { "        <part id='$id'   name='$($rd[0])'          mesh='$($rd[1])'         tex='$($rd[2])'       />" }
        }
        $lines += $line + "`r`n"
        Log "$Kind '$($rd[0])' -> id $id"
        $ids += $id; $id++
    }
}
$i = $x.LastIndexOf('</partlist>')
if ($i -lt 0) { throw "list.xml has no </partlist>" }
$x = $x.Substring(0, $i) + $lines + $x.Substring($i)
$a.ReplaceFile($le, (Get-Utf16Bytes $x))
$out = Join-Path $pkg $rel
$a.SaveAs($out)
Log "list.xml:"
$lines.TrimEnd() -split "`r`n" | ForEach-Object { Log ("    " + $_.Trim()) }

# ---- read-back: every new file byte-identical, the old entries all still there
$b = Open-Jmd $out
$all0 = Get-AllEntries (Open-Jmd $rel)
$all1 = Get-AllEntries $b
foreach ($p in $all0) { if ($all1 -notcontains $p) { throw "read-back: $p went missing" } }
foreach ($n in $Names) {
    foreach ($f in Get-ChildItem (Join-Path $Workshop "out\$Kind\$n\game") -File) {
        if (-not [Linq.Enumerable]::SequenceEqual([byte[]](Get-EntryBytes $b $f.Name), [byte[]][IO.File]::ReadAllBytes($f.FullName))) { throw "read-back of $($f.Name) differs" }
    }
}
Log "check: $($all0.Count) -> $($all1.Count) entries, new files read back byte-identical, list.xml has $(@(Get-PartList (Get-XmlText (Get-EntryBytes $b 'list.xml'))).Count) parts"
foreach ($s in (Update-FileInfo $FileInfo (Join-Path $pkg "FileInfo.0m") $pkg @($rel))) { Log $s }
[IO.File]::WriteAllLines((Join-Path $pkg "package_log.txt"), $log)
"PACKAGE OK $pkg"
