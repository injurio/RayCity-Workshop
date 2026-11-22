# Adds finished set effects (out\effect\<name>\) to a COPY of Data\effect\effect.jmd -> out\package\effect\ (client folder
# layout) + a FileInfo.0m copy. Game files are only read.
#   relement\ + every file of out\effect\<name>\game\relement\ (.0m copies, new textures)
#   relement\relementeffect.xml + each relementeffect_add.xml (effectGroup + effectItems) before </relementEffect>
#   relement\effectlink.xml     + each effectlink_add.xml (<option name='US_WS_<name>' .../>) before </links>
param([Parameter(Mandatory)][string[]]$Names, [string]$FileInfo = '')
. (Join-Path $PSScriptRoot "common.ps1")
if (-not $FileInfo) { $FileInfo = $ClientFileInfo }
$Names = @($Names | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$rel = "Data\effect\effect.jmd"
$pkg = Join-Path $Workshop "out\package\effect"
if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
[IO.Directory]::CreateDirectory((Join-Path $pkg "Data\effect")) | Out-Null
$log = New-Object Collections.Generic.List[string]
function Log($s) { $log.Add($s); $s }

$a = Open-Jmd $rel
$folder = ($a.GetEntries([uint32]::MaxValue) | Where-Object { $_ -is [Raycity.File.JMDPackedFolderInfo] -and $_.FolderName -eq "relement" }).Index
$xe = Find-Entry $a "relement/relementeffect.xml"; $le = Find-Entry $a "relement/effectlink.xml"
$x = Get-XmlText ($a.GetFileData($xe)); $l = Get-XmlText ($a.GetFileData($le))
$addX = ""; $addL = ""
foreach ($n in $Names) {
    if ($n -notmatch '^[a-z0-9_]{2,30}$') { throw "bad name $n" }
    $d = Join-Path $Workshop "out\effect\$n"
    if (-not (Test-Path "$d\game\relement")) { throw "missing $d\game (make the effect first)" }
    foreach ($f in Get-ChildItem "$d\game\relement" -File) {
        if (Find-Entry $a "relement/$($f.Name)") { throw "effect.jmd already has relement/$($f.Name)" }
        [void]$a.AddFile($folder, $f.Name, [IO.File]::ReadAllBytes($f.FullName)); Log "  + relement/$($f.Name)"
    }
    $gx = [IO.File]::ReadAllText("$d\relementeffect_add.xml"); $gl = [IO.File]::ReadAllText("$d\effectlink_add.xml")
    $grp = [regex]::Match($gx, 'effectGroup name="([^"]+)"').Groups[1].Value
    if ($grp) { if ($x -match "name=""$([regex]::Escape($grp))""") { throw "relementeffect.xml already has $grp" } }
    else {
        # a roof accessory's own effect: only <equipffect type="lamp" ... partName="<lamp list name>" fileName="..."/> lines
        $eq = @([regex]::Matches($gx, '<equipffect[^>]*partName="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        if (-not $eq.Count) { throw "$n\relementeffect_add.xml has neither an effectGroup nor an equipffect" }
        foreach ($p in $eq) { if ($x -match "partName=""$([regex]::Escape($p))""") { throw "relementeffect.xml already has an equipffect for part '$p'" } }
        $grp = "equipffect " + ($eq -join ", ")
    }
    $addX += $gx; $addL += $gl
    Log "effect '$n': $grp, $($gl.Trim())"
}
$i = $x.LastIndexOf('</relementEffect>'); if ($i -lt 0) { throw "relementeffect.xml has no </relementEffect>" }
$x = $x.Substring(0, $i) + $addX + $x.Substring($i)
$i = $l.LastIndexOf('</links>'); if ($i -lt 0) { throw "effectlink.xml has no </links>" }
$l = $l.Substring(0, $i) + $addL + $l.Substring($i)
$a.ReplaceFile($xe, (Get-Utf16Bytes $x)); $a.ReplaceFile($le, (Get-Utf16Bytes $l))
$out = Join-Path $pkg $rel
$a.SaveAs($out)

# ---- read-back
$b = Open-Jmd $out
$all0 = Get-AllEntries (Open-Jmd $rel); $all1 = Get-AllEntries $b
foreach ($p in $all0) { if ($all1 -notcontains $p) { throw "read-back: $p went missing" } }
foreach ($n in $Names) {
    foreach ($f in Get-ChildItem (Join-Path $Workshop "out\effect\$n\game\relement") -File) {
        if (-not [Linq.Enumerable]::SequenceEqual([byte[]](Get-EntryBytes $b "relement/$($f.Name)"), [byte[]][IO.File]::ReadAllBytes($f.FullName))) { throw "read-back of $($f.Name) differs" }
        if ($f.Extension -eq ".0m") { $r = [Raycity.File.OmResource]::Parse([byte[]](Get-EntryBytes $b "relement/$($f.Name)")); if (-not $r.HasSceneGraph) { throw "read-back: $($f.Name) does not parse" } }
    }
}
$x2 = Get-XmlText (Get-EntryBytes $b "relement/relementeffect.xml"); $l2 = Get-XmlText (Get-EntryBytes $b "relement/effectlink.xml")
try { [void][xml]$l2 } catch { throw "read-back: effectlink.xml is not valid XML: $($_.Exception.Message)" }
Log "check: $($all0.Count) -> $($all1.Count) entries, new files byte-identical, .0m copies parse, effectlink.xml parses ($(([regex]::Matches($l2, '<option ')).Count) options), relementeffect.xml has $(([regex]::Matches($x2, '<effectGroup ')).Count) groups"
foreach ($s in (Update-FileInfo $FileInfo (Join-Path $pkg "FileInfo.0m") $pkg @($rel))) { Log $s }
[IO.File]::WriteAllLines((Join-Path $pkg "package_log.txt"), $log)
"PACKAGE OK $pkg"
