# Asks for the client folder and the JMDReader folder when they are not set or are gone, and saves them in
# workshop.config.json. Run by server.js at every start (and by Change_Folders.cmd with -Force).
#   client     the RayCity client folder: the one with Data\ (Data\car\...) and FileInfo.0m. Only read.
#   jmdreader  the JMDReader folder (JMDReader-master, or its dist\JMDReader) that has JmdLibrary.dll.
# Exit code 0 = both folders are fine, 1 = cancelled.
param([switch]$Force, [switch]$NoDialog)   # -NoDialog: ask in the console only (e.g. Server Core)
$ErrorActionPreference = "Stop"
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

$cfg = [ordered]@{ client = ""; jmdreader = ""; blender = "" }
if (Test-Path -LiteralPath $WsConfigFile) {
    $old = Get-Content -LiteralPath $WsConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $old.PSObject.Properties) { $cfg[$p.Name] = [string]$p.Value }
}

$ui = $true
if ($NoDialog -or $env:WORKSHOP_NODIALOG) { $ui = $false } else { try { Add-Type -AssemblyName System.Windows.Forms } catch { $ui = $false } }

function Ask-Folder([string]$title, [string]$hint, [string]$start, [scriptblock]$ok) {
    while ($true) {
        Write-Host ""
        Write-Host $title -ForegroundColor Cyan
        Write-Host $hint
        $pick = $null
        if ($ui) {
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.Description = "$title`n$hint"
            $d.ShowNewFolderButton = $false
            if ($start -and (Test-Path -LiteralPath $start)) { $d.SelectedPath = $start }
            $top = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
            if ($d.ShowDialog($top) -eq [System.Windows.Forms.DialogResult]::OK) { $pick = $d.SelectedPath }
            $top.Dispose()
        }
        if (-not $pick) {
            $pick = Read-Host "Type or paste the folder path (empty = cancel)"
            if (-not $pick) { return $null }
            $pick = $pick.Trim().Trim('"')
        }
        if (& $ok $pick) { return (Resolve-Path -LiteralPath $pick).Path }
        Write-Host "That folder is not right: $pick" -ForegroundColor Yellow
    }
}

$changed = $false
if ($Force -or -not (Test-ClientDir $cfg.client)) {
    if ($cfg.client -and -not $Force) { Write-Host "The client folder is gone: $($cfg.client)" -ForegroundColor Yellow }
    $p = Ask-Folder "Choose the RayCity client folder" "The folder the game client is in: it has a Data folder (Data\car ...) and FileInfo.0m. It is only read." $cfg.client { param($d) Test-ClientDir $d }
    if (-not $p) { Write-Host "No client folder chosen."; exit 1 }
    $cfg.client = $p; $changed = $true
    if (-not (Test-Path -LiteralPath (Join-Path $p "FileInfo.0m"))) { Write-Host "Note: no FileInfo.0m in that folder; packages will be made without a FileInfo.0m copy." -ForegroundColor Yellow }
}
if ($Force -or -not (Resolve-JmdDll $cfg.jmdreader)) {
    if ($cfg.jmdreader -and -not $Force) { Write-Host "JmdLibrary.dll is gone from: $($cfg.jmdreader)" -ForegroundColor Yellow }
    $p = Ask-Folder "Choose the JMDReader folder" "The JMDReader folder (JMDReader-master or its dist\JMDReader) that has JmdLibrary.dll. It reads and writes the game's file formats." $cfg.jmdreader { param($d) [bool](Resolve-JmdDll $d) }
    if (-not $p) { Write-Host "No JMDReader folder chosen."; exit 1 }
    $cfg.jmdreader = $p; $changed = $true
}
if ($changed) {
    [IO.File]::WriteAllText($WsConfigFile, ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    Write-Host "Saved in $WsConfigFile" -ForegroundColor Green
}
Write-Host "Client folder:    $($cfg.client)"
Write-Host "JmdLibrary.dll:   $(Resolve-JmdDll $cfg.jmdreader)"
exit 0
