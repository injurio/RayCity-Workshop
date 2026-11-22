# Read-only: a game roof accessory's or wheel's LOD-2 mesh + texture for the viewer -> cache\catalog\<kind>mesh\
param([Parameter(Mandatory)][string]$Mesh, [Parameter(Mandatory)][string]$Tex, [ValidateSet("lamp", "wheel")][string]$Kind = "lamp")
. (Join-Path $PSScriptRoot "common.ps1")
$out = Join-Path $Workshop "cache\catalog\$($Kind)mesh"
[IO.Directory]::CreateDirectory($out) | Out-Null
$a = Open-Jmd "Data\car\common\$Kind.jmd"
$b = Get-EntryBytes $a "$($Mesh)_2.0m"
if ($null -eq $b) { throw "$Kind.jmd has no $($Mesh)_2.0m" }
Write-Utf8 "$out\$Mesh.json" (ConvertTo-MeshJson ([Raycity.Model.OmMesh]::Parse($b)) $Mesh)
$p = Get-EntryBytes $a "$Tex.png"
if ($null -ne $p) { [IO.File]::WriteAllBytes("$out\$Tex.png", $p) }
"ok"
