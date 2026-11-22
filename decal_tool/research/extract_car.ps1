# Read-only: export a car archive and its body/part meshes as OBJ into research\<car>\.  extract_car.ps1 clio
param([string]$Car = "clio")
$ErrorActionPreference = "Stop"
# Client folder + JmdLibrary.dll from the Workshop's workshop.config.json (this folder is inside the Workshop, or next to it)
$ws = @((Join-Path $PSScriptRoot '..'), (Join-Path $PSScriptRoot '..\workshop'), (Join-Path $PSScriptRoot '..\..'), (Join-Path $PSScriptRoot '..\..\workshop')) | Where-Object { Test-Path (Join-Path $_ 'backend\paths.ps1') } | Select-Object -First 1
if (-not $ws) { throw 'RayCity Workshop not found next to decal_tool' }
. (Join-Path $ws 'backend\paths.ps1')
$ray = $GameRoot
Add-Type -Path $JmdDll
$dst = Join-Path $PSScriptRoot $Car
$arc = New-Object Raycity.File.JmdArchive((Join-Path $ray "Data\car\$Car.jmd"))
[void]$arc.ExportAll($dst)
foreach ($f in Get-ChildItem $dst -Recurse -Filter "*_2.0m") {
    $m = [Raycity.Model.OmMesh]::Parse([IO.File]::ReadAllBytes($f.FullName))
    $o = $f.FullName -replace '\.0m$', '.obj'
    [IO.File]::WriteAllText($o, $m.ToObj($f.BaseName))
}
Get-ChildItem $dst -Recurse -Filter *.obj | % { $_.FullName.Substring($dst.Length + 1) }
