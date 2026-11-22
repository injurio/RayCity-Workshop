# Picture (PNG / JPG / BMP / GIF) -> RayCity car decal (pattern), with 3D previews on real game cars.
# Game files are only READ. Output: decal_tool\out\<Name>\  (see README.md)
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File make_decal.ps1 -Image my.png -Name samui_wave
#   ... -Layout sides|top|sides+top|wrap|raw  -Scale 0.9  -Pos 0.5  -Mirror  -Recolor  -RemoveBg  -Cars clio,cx7
#   GIF: -Frame 3 picks one frame (default 0); -AllFrames makes one decal per frame (<Name>_f00, _f01 ...)
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9_]{2,40}$')][string]$Name,
    [ValidateSet('sides', 'top', 'sides+top', 'wrap', 'raw')][string]$Layout = 'sides',
    [double]$Scale = 0.9,
    [double]$Pos = 0.5,
    [switch]$Mirror,
    [switch]$Recolor,
    [string]$Colors = '',
    [switch]$RemoveBg,
    [int]$Frame = 0,
    [switch]$AllFrames,
    [string[]]$Cars = @('clio'),
    [switch]$NoPreview
)
$ErrorActionPreference = 'Stop'
$Cars = @($Cars | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$here = $PSScriptRoot
# Client folder + JmdLibrary.dll from the Workshop's workshop.config.json (this folder is inside the Workshop, or next to it)
$ws = @((Join-Path $here '..'), (Join-Path $here '..\workshop'), (Join-Path $here '..\..'), (Join-Path $here '..\..\workshop')) | Where-Object { Test-Path (Join-Path $_ 'backend\paths.ps1') } | Select-Object -First 1
if (-not $ws) { throw 'RayCity Workshop not found next to decal_tool' }
. (Join-Path $ws 'backend\paths.ps1')
$ray = $GameRoot
# Blender's Python (has numpy) places the picture; Blender renders the previews.
$py = $BlenderPy; $blender = $BlenderExe
if (-not $py) { throw 'The decal tool needs Blender (its Python places the picture). Install Blender, or set "blender" in workshop.config.json.' }
Add-Type -AssemblyName System.Drawing
Add-Type -Path $JmdDll

# Decode every frame into a full-size 32-bit bitmap. GDI+ composites normal animated GIFs itself; GIFs it reads as a
# single frame (e.g. ones written by WPF) are read again with WPF's decoder, drawing each sub-frame at its offset.
$path = (Resolve-Path $Image).Path
$img = [Drawing.Image]::FromFile($path)
$dim = New-Object Drawing.Imaging.FrameDimension $img.FrameDimensionsList[0]
$count = $img.GetFrameCount($dim)
$bitmaps = New-Object Collections.Generic.List[Drawing.Bitmap]
$delays = @()
for ($i = 0; $i -lt $count; $i++) {
    [void]$img.SelectActiveFrame($dim, $i)
    $bmp = New-Object Drawing.Bitmap $img.Width, $img.Height, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp); $g.DrawImage($img, 0, 0, $img.Width, $img.Height); $g.Dispose()
    $bitmaps.Add($bmp)
}
if ($count -gt 1) { try { $pi = $img.GetPropertyItem(0x5100); for ($i = 0; $i -lt $count; $i++) { $delays += 10 * [BitConverter]::ToInt32($pi.Value, 4 * $i) } } catch { } }
$W = $img.Width; $H = $img.Height
$img.Dispose()
if ($count -eq 1 -and $path -match '\.gif$') {
    Add-Type -AssemblyName PresentationCore, WindowsBase
    $fs = [IO.File]::OpenRead($path)
    $dec = New-Object Windows.Media.Imaging.GifBitmapDecoder $fs, 'PreservePixelFormat', 'OnLoad'
    $fs.Close()
    if ($dec.Frames.Count -gt 1) {
        $bitmaps.Clear()
        $canvas = New-Object Drawing.Bitmap $W, $H, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
        foreach ($fr in $dec.Frames) {
            $x = 0; $y = 0; $d = 0
            try { $x = [int]$fr.Metadata.GetQuery('/imgdesc/Left'); $y = [int]$fr.Metadata.GetQuery('/imgdesc/Top') } catch { }
            try { $d = 10 * [int]$fr.Metadata.GetQuery('/grctlext/Delay') } catch { }
            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($fr))
            $ms = New-Object IO.MemoryStream; $enc.Save($ms); $ms.Position = 0
            $part = New-Object Drawing.Bitmap $ms
            $g = [Drawing.Graphics]::FromImage($canvas); $g.DrawImage($part, $x, $y, $part.Width, $part.Height); $g.Dispose()
            $part.Dispose()
            $bitmaps.Add($canvas.Clone())
            $delays += $d
        }
        $canvas.Dispose()
        $count = $bitmaps.Count
    }
}
if ($count -gt 1) { "GIF: $count frames" + $(if ($delays) { ", delays (ms): " + ($delays -join ' ') } else { '' }) }
$frames = if ($AllFrames) { 0..($count - 1) } else { , [math]::Min($Frame, $count - 1) }

# DDS template (the game's own far-texture format for decals: 256x256 DXT3 + mips)
$tpl = Join-Path $here 'research\template_decal_s.dds'
if (-not (Test-Path $tpl)) {
    $a = New-Object Raycity.File.JmdArchive((Join-Path $ray 'Data\car\common\decal4.jmd'))
    $e = $a.GetEntries([uint32]::MaxValue) | Where-Object { $_ -is [Raycity.File.JMDPackedFileInfo] -and $_.FileName -eq 'decal_won_20_s' } | Select-Object -First 1
    [IO.File]::WriteAllBytes($tpl, $a.GetFileData($e))
}
$tplBytes = [IO.File]::ReadAllBytes($tpl)

function Bgra([string]$png) {
    $b = New-Object Drawing.Bitmap $png
    $r = New-Object Drawing.Rectangle 0, 0, $b.Width, $b.Height
    $d = $b.LockBits($r, 'ReadOnly', [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $px = New-Object byte[] ($b.Width * $b.Height * 4)
    for ($y = 0; $y -lt $b.Height; $y++) { [Runtime.InteropServices.Marshal]::Copy([IntPtr]($d.Scan0.ToInt64() + $y * $d.Stride), $px, $y * $b.Width * 4, $b.Width * 4) }
    $b.UnlockBits($d); $b.Dispose()
    , $px
}

$U16 = New-Object Text.UnicodeEncoding $false, $true
foreach ($f in $frames) {
    $n = if ($AllFrames) { '{0}_f{1:D2}' -f $Name, $f } else { $Name }
    $out = Join-Path $here "out\$n"
    New-Item -ItemType Directory -Force $out | Out-Null
    # 1. frame -> plain RGBA PNG (any input format System.Drawing reads)
    $srcPng = Join-Path $out "source_$n.png"
    $bitmaps[$f].Save($srcPng, [Drawing.Imaging.ImageFormat]::Png)
    # 2. place into the 512 template
    $args2 = @('-I', (Join-Path $here 'scripts\layout_decal.py'), $srcPng, $out, $n, '--layout', $Layout, '--scale', "$Scale", '--pos', "$Pos")
    if ($Mirror) { $args2 += '--mirror' }
    if ($Recolor) { $args2 += '--recolor'; if ($Colors) { $args2 += @('--colors', $Colors) } }
    if ($RemoveBg) { $args2 += @('--bg', 'remove') }
    & $py @args2
    if ($LASTEXITCODE) { throw "layout_decal.py failed" }
    # 3. far copy: 256x256 DXT3 like the game's own decals
    $png = Join-Path $out "decal_$n.png"
    $px = Bgra $png
    $small = [Raycity.Media.TextureCodec]::Resize($px, 512, 512, 256, 256)
    [IO.File]::WriteAllBytes((Join-Path $out "decal_$($n)_s.dds"), [Raycity.Media.TextureCodec]::EncodeDdsLike($tplBytes, $small, 256, 256))
    # 4. <name>.xml (UTF-16 + BOM, CRLF, like the game's)
    $cf = Join-Path $out "colors_$n.txt"
    if ($Recolor) {
        $c = @(Get-Content $cf)
        $xml = "<?xml version='1.0' encoding='UTF-16'?>`r`n<part>`r`n`t<color>`r`n`t`t<custom>yes</custom>`r`n" +
            "`t`t<color0>255 $($c[0])</color0>`r`n`t`t<color1>255 $($c[1])</color1>`r`n`t`t<color2>255 $($c[2])</color2>`r`n" +
            "`t`t<customCount>3</customCount>`r`n`t</color>`r`n</part>"
    } else {
        $xml = "<?xml version='1.0' encoding='UTF-16'?>`r`n<part>`r`n`t<color>`r`n`t`t<custom>no</custom>`r`n`t</color>`r`n</part>"
    }
    [IO.File]::WriteAllBytes((Join-Path $out "$n.xml"), $U16.GetPreamble() + $U16.GetBytes($xml))
    # 5. 3D previews on game cars (exported once into research\<car>)
    if (-not $NoPreview) {
        $mode = if ($Recolor) { '3color' } else { 'rgba' }
        $col = if ($Recolor) { (@(Get-Content $cf) | ForEach-Object { $_ -replace ' ', ',' }) -join ';' } else { '-' }
        foreach ($car in $Cars) {
            $cd = Join-Path $here "research\$car"
            if (-not (Test-Path (Join-Path $cd 'body_2.obj'))) { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'research\extract_car.ps1') $car | Out-Null }
            $prev = Join-Path $out 'preview'
            New-Item -ItemType Directory -Force $prev | Out-Null
            $ErrorActionPreference = 'Continue'
            & $blender -b --factory-startup -P (Join-Path $here 'scripts\preview_car.py') -- $cd $png (Join-Path $prev $car) $mode 1to1 "$col" 'left,right,top,front34' 2>&1 |
                ForEach-Object { "$_" } | Select-String -Pattern 'Error|Traceback|rendered' | ForEach-Object { $_.Line }
            $ErrorActionPreference = 'Stop'
        }
    }
    "DECAL OK $n -> $out"
}
foreach ($b in $bitmaps) { $b.Dispose() }
if ($AllFrames -and $count -gt 1) {
    "Note: the game shows decals as still images. The $count frames are separate decals ($($Name)_f00 ...); animating them needs client code (README 'Animated decals')."
}
