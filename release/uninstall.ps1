# Removes the RayCity Workshop's shortcuts and (after asking) its folder. Run by Uninstall.cmd in the install folder.
# Game files and the JMDReader folder are never touched (they are only pointed to by workshop.config.json).
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Write-Host "Uninstall the RayCity Workshop in $root" -ForegroundColor Cyan
$keep = Read-Host "Also delete what it made (cache\, out\, inbox\, decal_tool\out\, workshop.config.json)? [y/N]"
$menu = Join-Path ([Environment]::GetFolderPath("Programs")) "RayCity Workshop"
if (Test-Path $menu) { Remove-Item -Recurse -Force $menu }
$desk = Join-Path ([Environment]::GetFolderPath("Desktop")) "RayCity Workshop.lnk"
if (Test-Path $desk) { Remove-Item -Force $desk }
$made = @("cache", "out", "inbox", "workshop.config.json")
foreach ($e in Get-ChildItem -LiteralPath $root -Force) {
    if ($keep -notmatch '^[yY]' -and $made -contains $e.Name) { continue }
    if ($keep -notmatch '^[yY]' -and $e.Name -eq "decal_tool") {
        Get-ChildItem -LiteralPath $e.FullName -Force | Where-Object { $_.Name -ne "out" } | Remove-Item -Recurse -Force
        continue
    }
    Remove-Item -LiteralPath $e.FullName -Recurse -Force
}
if ((Get-ChildItem -LiteralPath $root -Force | Measure-Object).Count -eq 0) { Set-Location \; Remove-Item -LiteralPath $root -Force }
Write-Host "Removed." -ForegroundColor Green
