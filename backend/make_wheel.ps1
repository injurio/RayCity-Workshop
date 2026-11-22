# Wheel: out\wheel\<name>\ (texture.png 128x128, icon.png 64x64, request.json {mode, baseMesh, transform}, [model.obj])
# -> game files in out\wheel\<name>\game\ + parts.txt (list.xml rows) + preview.json + meta.json. Game files are only read.
#   repaint : <name>.png/_s.dds on an existing game rim mesh (normal + its wide version when the game has one)
#   obj     : also <name>_0/1/2.0m and <name>wide_0/1/2.0m, made from copies of the game's j6a / j6awide meshes with
#             JMDReader's OmObjImport.ReplaceCarGeometry. LOD 0 (the far 26-vertex disc) is the game's own, unchanged.
# Wheel space (from the game's meshes): axle = X, the rim face looks to -X, radius ~0.34 m (tyre included); the "wide"
# versions keep the inner edge (x = +0.12) and move the face out by 0.115 m, 5% larger radius.
# The texture sits in the car texture's wheel slot (0, 0.75, 0.25, 1), so the model's UVs are squeezed into it.
param([Parameter(Mandatory)][string]$Name)
. (Join-Path $PSScriptRoot "common.ps1")
if ($Name -notmatch '^[a-z0-9_]{2,36}$') { throw "bad name (2-36 lowercase letters, digits, _)" }
$dir = Join-Path $Workshop "out\wheel\$Name"
$req = Get-Content (Join-Path $dir "request.json") -Raw | ConvertFrom-Json
$game = Join-Path $dir "game"
if (Test-Path $game) { Remove-Item -Recurse -Force $game }
[IO.Directory]::CreateDirectory("$game\icon") | Out-Null

$arc = Open-Jmd "Data\car\common\wheel.jmd"
$rows = Get-PartList (Get-XmlText (Get-EntryBytes $arc "list.xml"))
foreach ($n in $Name, "$($Name)wide") {
    if ($rows | Where-Object { $_.name -ieq $n -or $_.mesh -ieq $n -or $_.tex -ieq $n }) { throw "'$n' is already used in wheel.jmd list.xml; pick another name" }
}
if (Find-Entry $arc "$Name.png") { throw "wheel.jmd already has $Name.png" }

$parts = @()
if ($req.mode -eq "obj") {
    $t = @($req.transform | ForEach-Object { [double]$_ })
    if ($t.Count -ne 12) { $t = @(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0) }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $V = New-Object Collections.Generic.List[double[]]; $N = New-Object Collections.Generic.List[double[]]; $T = New-Object Collections.Generic.List[double[]]; $F = New-Object Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $dir "model.obj"))) {
        $a = $line.Trim() -split '\s+'
        switch ($a[0]) {
            'v' { $x = [double]::Parse($a[1], $inv); $y = [double]::Parse($a[2], $inv); $z = [double]::Parse($a[3], $inv)
                  $V.Add(@(($t[0] * $x + $t[1] * $y + $t[2] * $z + $t[3]), ($t[4] * $x + $t[5] * $y + $t[6] * $z + $t[7]), ($t[8] * $x + $t[9] * $y + $t[10] * $z + $t[11]))) }
            'vn' { $x = [double]::Parse($a[1], $inv); $y = [double]::Parse($a[2], $inv); $z = [double]::Parse($a[3], $inv)
                   $N.Add(@(($t[0] * $x + $t[1] * $y + $t[2] * $z), ($t[4] * $x + $t[5] * $y + $t[6] * $z), ($t[8] * $x + $t[9] * $y + $t[10] * $z))) }
            'vt' { $T.Add(@([Math]::Min(1.0, [Math]::Max(0.0, [double]::Parse($a[1], $inv))), [Math]::Min(1.0, [Math]::Max(0.0, [double]::Parse($a[2], $inv))))) }
            'f' { $F.Add($line.Trim()) }
        }
    }
    if ($V.Count -eq 0 -or $F.Count -eq 0) { throw "the OBJ has no vertices or faces" }
    if ($V.Count -gt 65000) { throw "the OBJ has $($V.Count) vertices; the game's format allows at most 65 000 per part" }
    if ($T.Count -eq 0) { "warning: the OBJ has no UVs, the whole wheel will use one texel of the texture" }
    function Obj-Text([bool]$wide) {
        $sb = New-Object Text.StringBuilder
        [void]$sb.AppendLine("# workshop wheel $Name" + $(if ($wide) { " (wide)" } else { "" }))
        foreach ($p in $V) {
            $x = $p[0]; $y = $p[1]; $z = $p[2]
            if ($wide) { $k = [Math]::Min(1.0, [Math]::Max(0.0, (0.12 - $x) / 0.24)); $x = $x - 0.115 * $k; $y *= 1.05; $z *= 1.05 }
            [void]$sb.AppendLine(("v {0} {1} {2}" -f $x.ToString("R", $inv), $y.ToString("R", $inv), $z.ToString("R", $inv)))
        }
        foreach ($n in $N) { $l = [Math]::Sqrt($n[0] * $n[0] + $n[1] * $n[1] + $n[2] * $n[2]); if ($l -eq 0) { $l = 1 }
            [void]$sb.AppendLine(("vn {0} {1} {2}" -f ($n[0] / $l).ToString("R", $inv), ($n[1] / $l).ToString("R", $inv), ($n[2] / $l).ToString("R", $inv))) }
        # OBJ v is bottom-up; the game's is top-down; squeeze into the wheel slot
        foreach ($u in $T) { [void]$sb.AppendLine(("vt {0} {1}" -f (0.25 * $u[0]).ToString("R", $inv), (0.75 + 0.25 * (1 - $u[1])).ToString("R", $inv))) }
        [void]$sb.AppendLine("o part_1")
        foreach ($f in $F) { [void]$sb.AppendLine($f) }
        $sb.ToString()
    }
    foreach ($wide in $false, $true) {
        $mesh = if ($wide) { "$($Name)wide" } else { $Name }
        $tplName = if ($wide) { "j6awide" } else { "j6a" }
        $objText = Obj-Text $wide
        [IO.File]::WriteAllText((Join-Path $dir "$($mesh)_game.obj"), $objText)
        [IO.File]::WriteAllBytes("$game\$($mesh)_0.0m", (Get-EntryBytes $arc "$($tplName)_0.0m"))
        "  $($mesh)_0.0m: the game's far disc ($($tplName)_0.0m)"
        foreach ($L in 1, 2) {
            $report = $null
            $bytes = [Raycity.Model.OmObjImport]::ReplaceCarGeometry((Get-EntryBytes $arc "$($tplName)_$L.0m"), $objText, [ref]$report)
            $check = [Raycity.Model.OmMesh]::Parse($bytes)
            [IO.File]::WriteAllBytes("$game\$($mesh)_$L.0m", $bytes)
            "  $($mesh)_$L.0m: $($check.VertexCount) vertices, $($check.TriangleCount) triangles, $($check.Parts.Length) part (re-parsed OK)"
            if ($L -eq 2 -and -not $wide) { Write-Utf8 (Join-Path $dir "preview.json") (ConvertTo-MeshJson $check $Name) }
        }
    }
    $parts += "$Name|$Name|$Name", "$($Name)wide|$($Name)wide|$Name"
} else {
    $base = [string]$req.baseMesh
    if (-not (Find-Entry $arc "$($base)_2.0m")) { throw "wheel.jmd has no mesh '$base'" }
    Write-Utf8 (Join-Path $dir "preview.json") (ConvertTo-MeshJson ([Raycity.Model.OmMesh]::Parse((Get-EntryBytes $arc "$($base)_2.0m"))) $Name)
    $parts += "$Name|$base|$Name"
    $wideMesh = @("$($base)wide", "$($base)_wide") | Where-Object { Find-Entry $arc "$($_)_2.0m" } | Select-Object -First 1
    if ($base -match 'wide$') { $wideMesh = $null; "  (the base is already a wide rim; no extra wide version)" }
    if ($wideMesh) { $parts += "$($Name)wide|$wideMesh|$Name"; "  wide version on the game's $wideMesh" } elseif ($base -notmatch 'wide$') { "  the game has no wide version of $base; only the normal one is made" }
    "  rim mesh: the game's $base (unchanged)"
}

$png = Join-Path $dir "texture.png"
$img = Read-Bgra $png
if ($img.W -ne 128 -or $img.H -ne 128) { throw "texture is $($img.W)x$($img.H), expected 128x128" }
Copy-Item $png "$game\$Name.png"
[IO.File]::WriteAllBytes("$game\$($Name)_s.dds", (New-FarDds $png (Get-EntryBytes $arc "j6a_s.dds")))
"  $Name.png, $($Name)_s.dds"
foreach ($p in $parts) {
    $n = ($p -split '\|')[0]
    Copy-Item (Join-Path $dir "icon.png") "$game\icon\common_wheel_$n.png"
    "  icon/common_wheel_$n.png"
}
[IO.File]::WriteAllLines((Join-Path $dir "parts.txt"), [string[]]$parts)
"  list rows: " + ($parts -join "; ")
Write-Utf8 (Join-Path $dir "meta.json") ('{"url":"/out/wheel/' + $Name + '/texture.png","mesh":"/out/wheel/' + $Name + '/preview.json","mode":' + (ConvertTo-JsonString ([string]$req.mode)) + '}')
"OK"
