# RayCity Workshop setup: copies the Workshop from payload.zip into an install folder, checks Node.js, makes shortcuts.
# Run by the setup .exe (IExpress) from its temporary folder, or by hand:
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-Target "D:\RayCity Workshop"] [-Quiet]
# An update over an existing install keeps workshop.config.json, cache\, out\, inbox\ and decal_tool\out\.
param([string]$Target = "", [switch]$Quiet, [switch]$NoShortcuts)
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$payload = Join-Path $here "payload.zip"
$version = if (Test-Path (Join-Path $here "VERSION.txt")) { (Get-Content (Join-Path $here "VERSION.txt") -Raw).Trim() } else { "" }

function Ask([string]$q, [string]$def) {
    if ($Quiet) { return $def }
    $a = Read-Host "$q [$def]"
    if ($a) { $a.Trim().Trim('"') } else { $def }
}
function Yes([string]$q) {
    if ($Quiet) { return $false }
    $a = Read-Host "$q [Y/n]"
    -not $a -or $a -match '^[yY]'
}

try {
    Write-Host "RayCity Workshop $version setup" -ForegroundColor Cyan
    Write-Host "A local tool for previewing and making RayCity car content. Game files are only read."
    Write-Host ""

    # 1. install folder (must be writable: the Workshop keeps its cache and outputs next to itself)
    if (-not $Target) { $Target = Ask "Install folder" "C:\RayCity Workshop" }
    $Target = [IO.Path]::GetFullPath($Target)
    if (@($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ -and $Target -like "$_*" }) {
        Write-Host "Note: Program Files is read-only for normal users; the Workshop writes cache\ and out\ in its folder." -ForegroundColor Yellow
    }
    $update = Test-Path (Join-Path $Target "server.js")
    [IO.Directory]::CreateDirectory($Target) | Out-Null

    # 2. copy the files (program files are replaced; settings and made content stay)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("rcws_" + [guid]::NewGuid().ToString("N"))
    Expand-Archive -LiteralPath $payload -DestinationPath $tmp
    $src = Join-Path $tmp "RayCity Workshop"
    foreach ($d in "backend", "web", "release") { $p = Join-Path $Target $d; if (Test-Path $p) { Remove-Item -Recurse -Force $p } }
    Copy-Item -Path (Join-Path $src "*") -Destination $Target -Recurse -Force
    Remove-Item -Recurse -Force $tmp
    Write-Host ($(if ($update) { "Updated" } else { "Installed" }) + " in $Target") -ForegroundColor Green

    # 3. Node.js (the Workshop's server)
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) { Write-Host "Node.js: $(& node --version)" }
    else {
        Write-Host "Node.js is not installed. The Workshop needs it (LTS version)." -ForegroundColor Yellow
        $wg = Get-Command winget -ErrorAction SilentlyContinue
        if ($wg -and (Yes "Install Node.js LTS now with winget?")) {
            & winget install -e --id OpenJS.NodeJS.LTS
            Write-Host "If the Workshop still says Node.js is missing, sign out and in again (or restart) so PATH updates."
        } else {
            Write-Host "Install it from https://nodejs.org/ before starting the Workshop."
        }
    }

    # 4. shortcuts: Start menu (Workshop + Change folders) and desktop
    $sh = New-Object -ComObject WScript.Shell
    $menu = Join-Path ([Environment]::GetFolderPath("Programs")) "RayCity Workshop"
    [IO.Directory]::CreateDirectory($menu) | Out-Null
    $links = @(
        @((Join-Path $menu "RayCity Workshop.lnk"), "Start_Workshop.cmd", "Start the RayCity Workshop"),
        @((Join-Path $menu "Change client and JMDReader folders.lnk"), "Change_Folders.cmd", "Choose the client folder and the JMDReader folder again"),
        @((Join-Path $menu "Uninstall RayCity Workshop.lnk"), "Uninstall.cmd", "Remove the RayCity Workshop"),
        @((Join-Path ([Environment]::GetFolderPath("Desktop")) "RayCity Workshop.lnk"), "Start_Workshop.cmd", "Start the RayCity Workshop"))
    foreach ($l in $links) {
        if ($NoShortcuts) { break }
        $s = $sh.CreateShortcut($l[0])
        $s.TargetPath = Join-Path $Target $l[1]
        $s.WorkingDirectory = $Target
        $s.Description = $l[2]
        $s.Save()
    }
    Write-Host "Shortcuts: Start menu > RayCity Workshop, and the desktop."
    Write-Host ""
    Write-Host "At the first start the Workshop asks for the RayCity client folder (with Data\ and FileInfo.0m)"
    Write-Host "and the JMDReader folder (with JmdLibrary.dll). It asks again if one of them is gone."
    if ((Get-Command node -ErrorAction SilentlyContinue) -and (Yes "Start the Workshop now?")) {
        Start-Process -FilePath (Join-Path $Target "Start_Workshop.cmd") -WorkingDirectory $Target
    }
} catch {
    Write-Host "Setup failed: $($_.Exception.Message)" -ForegroundColor Red
    if (-not $Quiet) { Read-Host "Press Enter to close" | Out-Null }
    exit 1
}
if (-not $Quiet) { Read-Host "Done. Press Enter to close" | Out-Null }
