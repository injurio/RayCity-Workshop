# Builds the RayCity Workshop release (for a server machine that pre-renders models before they go to the real server):
#   release\dist\RayCity-Workshop-<version>.zip         portable: unzip, run Start_Workshop.cmd
#   release\dist\RayCity-Workshop-Setup-<version>.exe   setup: asks the install folder, checks Node.js, makes shortcuts
# Only the Workshop's own files go in (JMDReader and game files are not shipped; the first start asks for both folders).
#   powershell -NoProfile -ExecutionPolicy Bypass -File release\build_release.ps1 -Version 1.0.0
param([Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version)
$ErrorActionPreference = "Stop"
$ws = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $PSScriptRoot "dist"
$work = Join-Path $dist "work"
$stage = Join-Path $work "RayCity Workshop"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
[IO.Directory]::CreateDirectory($stage) | Out-Null

# 1. the program files (what git tracks, minus the release builder itself)
$files = @("Start_Workshop.cmd", "Change_Folders.cmd", "server.js", "README.md", "LICENSE", ".gitignore")
$files += Get-ChildItem (Join-Path $ws "backend") -File -Filter *.ps1 | ForEach-Object { "backend\" + $_.Name }
$files += Get-ChildItem (Join-Path $ws "web") -File | ForEach-Object { "web\" + $_.Name }
$files += "release\uninstall.ps1"
$dt = Join-Path $ws "decal_tool"
# decal tool: scripts and samples only (research\<car>\ and *.dds are exported game files)
$files += @("make_decal.ps1", "make_package.ps1", "README.md", "template_guide.png", "research\extract_car.ps1") | ForEach-Object { "decal_tool\$_" }
$files += Get-ChildItem (Join-Path $dt "samples") -File | ForEach-Object { "decal_tool\samples\" + $_.Name }
$files += Get-ChildItem (Join-Path $dt "scripts") -File -Filter *.py | ForEach-Object { "decal_tool\scripts\" + $_.Name }
foreach ($f in $files) {
    $from = Join-Path $ws $f
    if (-not (Test-Path $from)) { if ($f -in "LICENSE", ".gitignore") { continue }; throw "missing $f" }
    $to = Join-Path $stage $f
    [IO.Directory]::CreateDirectory((Split-Path $to)) | Out-Null
    Copy-Item -LiteralPath $from -Destination $to
}
Set-Content -LiteralPath (Join-Path $stage "VERSION.txt") -Value $Version -Encoding ASCII
Set-Content -LiteralPath (Join-Path $stage "Uninstall.cmd") -Encoding ASCII -Value @(
    '@echo off', 'rem Removes the RayCity Workshop shortcuts and this folder (asks about made content).', 'cd /d "%~dp0"',
    'powershell -NoProfile -ExecutionPolicy Bypass -File release\uninstall.ps1', 'pause')
# a release starts clean: no config, cache or outputs
foreach ($n in "workshop.config.json", "cache", "out", "inbox") { if (Test-Path (Join-Path $stage $n)) { throw "$n must not be in the release" } }
"Staged $($files.Count + 2) files"

# 2. portable zip
$zip = Join-Path $dist "RayCity-Workshop-$Version.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $stage -DestinationPath $zip
"Zip:   $zip ($([math]::Round((Get-Item $zip).Length / 1KB)) KB)"

# 3. setup .exe (IExpress, part of Windows): payload.zip + install.ps1 + install.cmd, runs install.cmd after extracting
$pay = Join-Path $work "setup"
[IO.Directory]::CreateDirectory($pay) | Out-Null
Copy-Item -LiteralPath $zip -Destination (Join-Path $pay "payload.zip")
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "install.ps1") -Destination $pay
Set-Content -LiteralPath (Join-Path $pay "VERSION.txt") -Value $Version -Encoding ASCII
Set-Content -LiteralPath (Join-Path $pay "install.cmd") -Encoding ASCII -Value @(
    '@echo off', 'title RayCity Workshop setup', 'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"')
$exe = Join-Path $dist "RayCity-Workshop-Setup-$Version.exe"
if (Test-Path $exe) { Remove-Item -Force $exe }
$sed = Join-Path $work "setup.sed"
$names = "install.cmd", "install.ps1", "payload.zip", "VERSION.txt"
$lines = @(
    "[Version]", "Class=IEXPRESS", "SEDVersion=3",
    "[Options]", "PackagePurpose=InstallApp", "ShowInstallProgramWindow=1", "HideExtractAnimation=1", "UseLongFileName=1",
    "InsideCompressed=0", "CAB_FixedSize=0", "CAB_ResvCodeSigning=0", "RebootMode=N",
    "InstallPrompt=%InstallPrompt%", "DisplayLicense=%DisplayLicense%", "FinishMessage=%FinishMessage%",
    "TargetName=%TargetName%", "FriendlyName=%FriendlyName%", "AppLaunched=%AppLaunched%", "PostInstallCmd=%PostInstallCmd%",
    "AdminQuietInstCmd=%AdminQuietInstCmd%", "UserQuietInstCmd=%UserQuietInstCmd%", "SourceFiles=SourceFiles",
    "[Strings]", "InstallPrompt=", "DisplayLicense=", "FinishMessage=", "TargetName=$exe",
    "FriendlyName=RayCity Workshop $Version setup", "AppLaunched=cmd /c install.cmd", "PostInstallCmd=<None>",
    "AdminQuietInstCmd=", "UserQuietInstCmd=")
for ($i = 0; $i -lt $names.Count; $i++) { $lines += "FILE$i=`"$($names[$i])`"" }
$lines += "[SourceFiles]", "SourceFiles0=$pay\", "[SourceFiles0]"
for ($i = 0; $i -lt $names.Count; $i++) { $lines += "%FILE$i%=" }
Set-Content -LiteralPath $sed -Value $lines -Encoding ASCII
# run through cmd from the work folder (Start-Process -Wait returned before IExpress had written the .exe)
Push-Location $work
& cmd.exe /c "`"$env:WINDIR\System32\iexpress.exe`" /N /Q setup.sed"
Pop-Location
for ($t = 0; $t -lt 60 -and -not (Test-Path $exe); $t++) { Start-Sleep 1 }
if (-not (Test-Path $exe)) { throw "IExpress did not make the setup" }
"Setup: $exe ($([math]::Round((Get-Item $exe).Length / 1KB)) KB)"
Remove-Item -Recurse -Force $work
