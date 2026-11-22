# Makes the test inputs: samples\samui_logo.png (logo on white) and samples\wave_anim.gif (4 frames).
Add-Type -AssemblyName System.Drawing, PresentationCore, WindowsBase
$dir = $PSScriptRoot
function Logo([int]$phase) {
  $b = New-Object Drawing.Bitmap 600, 200
  $g = [Drawing.Graphics]::FromImage($b); $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAlias'
  $g.Clear([Drawing.Color]::White)
  $pts = @(); for ($x = 0; $x -le 600; $x += 10) { $pts += New-Object Drawing.PointF $x, (150 + 22 * [math]::Sin(($x / 60.0) + $phase * 1.5708)) }
  $poly = $pts + @((New-Object Drawing.PointF 600, 200), (New-Object Drawing.PointF 0, 200))
  $g.FillPolygon((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(0, 150, 210))), [Drawing.PointF[]]$poly)
  $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 170, 0))), 470, 20, 90, 90)
  $f = New-Object Drawing.Font 'Arial Black', 64, ([Drawing.FontStyle]::Bold)
  $g.DrawString('SAMUI', $f, (New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(20, 30, 60))), 20, 30)
  $g.Dispose(); $b
}
$l = Logo 0; $l.Save("$dir\samui_logo.png", [Drawing.Imaging.ImageFormat]::Png)
$enc = New-Object Windows.Media.Imaging.GifBitmapEncoder
foreach ($p in 0..3) {
  $b = Logo $p; $ms = New-Object IO.MemoryStream; $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $ms.Position = 0
  $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($ms, 'None', 'OnLoad'))
}
$fs = [IO.File]::Create("$dir\wave_anim.gif"); $enc.Save($fs); $fs.Close()
"samples ok"
