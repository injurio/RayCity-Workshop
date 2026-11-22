# Where the game client and JMDReader are, from workshop.config.json (written by setup_paths.ps1 at start).
# Dot-sourced by common.ps1 and the decal_tool scripts. Sets:
#   $WsRoot        the Workshop folder
#   $GameRoot      the client folder (has Data\ and FileInfo.0m); game files are only read
#   $JmdDll        JmdLibrary.dll
#   $ClientFileInfo  <client>\FileInfo.0m
#   $Projects      the folder around the Workshop, scanned for <project>\package\Data\car\*.jmd
#   $BlenderExe / $BlenderPy   Blender (decal previews) and its Python (decal layout); $null when not installed
$script:WsRoot = Split-Path $PSScriptRoot -Parent
$script:WsConfigFile = Join-Path $WsRoot "workshop.config.json"

function Resolve-JmdDll([string]$dir) {
    if (-not $dir) { return $null }
    foreach ($p in @("JmdLibrary.dll", "dist\JMDReader\JmdLibrary.dll")) {
        $f = Join-Path $dir $p
        if (Test-Path -LiteralPath $f -PathType Leaf) { return $f }
    }
    $null
}
function Test-ClientDir([string]$dir) { $dir -and (Test-Path -LiteralPath (Join-Path $dir "Data\car") -PathType Container) }

function Read-WsConfig {
    if (-not (Test-Path -LiteralPath $WsConfigFile)) { return [pscustomobject]@{ client = ""; jmdreader = ""; blender = "" } }
    $c = Get-Content -LiteralPath $WsConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in "client", "jmdreader", "blender") { if (-not ($c.PSObject.Properties.Name -contains $k)) { $c | Add-Member $k "" } }
    $c
}

$script:WsConfig = Read-WsConfig
if (-not (Test-ClientDir $WsConfig.client)) {
    throw "The client folder is not set or is gone ($($WsConfig.client)). Close the Workshop window and start it again to choose it."
}
$script:JmdDll = Resolve-JmdDll $WsConfig.jmdreader
if (-not $JmdDll) {
    throw "JmdLibrary.dll is not found in the JMDReader folder ($($WsConfig.jmdreader)). Close the Workshop window and start it again to choose it."
}
$script:GameRoot = $WsConfig.client
$script:ClientFileInfo = Join-Path $GameRoot "FileInfo.0m"
$script:Projects = Split-Path $WsRoot -Parent

# Blender: the config's path, else the newest under Program Files.
$script:BlenderExe, $script:BlenderPy = & {   # own scope: no helper variables leak into the calling script
    $bl = @()
    if ($WsConfig.blender) { $bl += $WsConfig.blender }
    $bf = Join-Path $env:ProgramFiles "Blender Foundation"
    if (Test-Path $bf) { $bl += @(Get-ChildItem $bf -Directory | Sort-Object Name -Descending | ForEach-Object { $_.FullName }) }
    foreach ($d in $bl) {
        $exe = if ($d -like "*.exe") { $d } else { Join-Path $d "blender.exe" }
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        $py = Get-ChildItem (Split-Path $exe) -Directory | ForEach-Object { Join-Path $_.FullName "python\bin\python.exe" } |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($py) { return $exe, $py }
    }
    $null, $null
}
