# Shared helpers for the workshop backend. Game files are only read.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "paths.ps1")
$script:Ray = $GameRoot   # the client folder: relative game paths ("Data\car\...") are under it
$script:Workshop = $WsRoot
Add-Type -Path $JmdDll
$script:Inv = [Globalization.CultureInfo]::InvariantCulture

function Open-Jmd([string]$rel) {
    $p = if ([IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $Ray $rel }
    New-Object Raycity.File.JmdArchive($p)
}

# Entry by "folder/sub/file.ext" path, or $null.
function Find-Entry($arc, [string]$path) {
    $folder = [uint32]::MaxValue
    $parts = $path -split "/"
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $last = $i -eq $parts.Count - 1
        $hit = $null
        foreach ($e in $arc.GetEntries($folder)) {
            if ($last -and $e -is [Raycity.File.JMDPackedFileInfo] -and ($e.FileName + "." + $e.Extension) -ieq $parts[$i]) { $hit = $e; break }
            if (-not $last -and $e -is [Raycity.File.JMDPackedFolderInfo] -and $e.FolderName -ieq $parts[$i]) { $hit = $e; break }
        }
        if ($null -eq $hit) { return $null }
        if ($last) { return $hit }
        $folder = $hit.Index
    }
}

function Get-EntryBytes($arc, [string]$path) {
    $e = Find-Entry $arc $path
    if ($null -eq $e) { return $null }
    , $arc.GetFileData($e)
}

# Every file in an archive as "path<TAB>size".
function Get-AllEntries($arc) {
    $out = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@([uint32]::MaxValue, ""))
    while ($stack.Count) {
        $f = $stack.Pop()
        foreach ($e in $arc.GetEntries($f[0])) {
            if ($e -is [Raycity.File.JMDPackedFileInfo]) { $out.Add($f[1] + $e.FileName + "." + $e.Extension) }
            else { $stack.Push(@($e.Index, ($f[1] + $e.FolderName + "/"))) }
        }
    }
    $out
}

function Get-XmlText([byte[]]$b) {
    if ($null -eq $b) { return $null }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
    if ($b.Length -ge 2 -and $b[1] -eq 0) { return [Text.Encoding]::Unicode.GetString($b) }
    [Text.Encoding]::UTF8.GetString($b)
}

# <part id name mesh tex/> entries of a list.xml (regex: the game's xml is loose).
function Get-PartList([string]$xml) {
    $rows = @()
    foreach ($m in [regex]::Matches($xml, "<part\s([^>]*?)/?>")) {
        $row = @{}
        foreach ($a in [regex]::Matches($m.Groups[1].Value, "(\w+)\s*=\s*'([^']*)'")) { $row[$a.Groups[1].Value] = $a.Groups[2].Value }
        $rows += , $row
    }
    $rows
}

function F([float]$x) { $x.ToString("0.#####", $Inv) }

# A parsed OmMesh as JSON: positions/uvs/normals flat, parts with global indices and draw-header bytes.
function ConvertTo-MeshJson($mesh, [string]$label, [string]$mounts = "") {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('{"label":"').Append($label).Append('","positions":[')
    $first = $true
    foreach ($p in $mesh.Positions) { if (-not $first) { [void]$sb.Append(',') }; $first = $false; [void]$sb.Append((F $p.X)).Append(',').Append((F $p.Y)).Append(',').Append((F $p.Z)) }
    [void]$sb.Append('],"uvs":[')
    $first = $true
    foreach ($t in $mesh.TextureCoordinates) { if (-not $first) { [void]$sb.Append(',') }; $first = $false; [void]$sb.Append((F $t.X)).Append(',').Append((F $t.Y)) }
    [void]$sb.Append('],"normals":[')
    $first = $true
    foreach ($n in $mesh.Normals) { if (-not $first) { [void]$sb.Append(',') }; $first = $false; [void]$sb.Append((F $n.X)).Append(',').Append((F $n.Y)).Append(',').Append((F $n.Z)) }
    [void]$sb.Append('],"parts":[')
    for ($i = 0; $i -lt $mesh.Parts.Length; $i++) {
        $part = $mesh.Parts[$i]
        if ($i) { [void]$sb.Append(',') }
        $h = $part.DrawHeader
        $g = if ($h) { $h[0] } else { 0 }; $c = if ($h) { $h[1] } else { 0 }
        $nm = if ($part.Name) { $part.Name } else { "part_" + ($i + 1) }; [void]$sb.Append('{"name":').Append((ConvertTo-JsonString $nm)).Append(',"group":').Append($g).Append(',"cat":').Append($c).Append(',"indices":[')
        $base = $part.BaseVertex
        $idx = $part.Indices
        for ($k = 0; $k -lt $idx.Length; $k++) { if ($k) { [void]$sb.Append(',') }; [void]$sb.Append($base + $idx[$k]) }
        [void]$sb.Append(']}')
    }
    [void]$sb.Append(']')
    if ($mounts) { [void]$sb.Append(',"mounts":').Append($mounts) }
    [void]$sb.Append('}')
    $sb.ToString()
}

function Write-Utf8([string]$path, [string]$text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

function ConvertTo-JsonString([string]$s) { '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }

# ---- images
Add-Type -AssemblyName System.Drawing
function Read-Bgra([string]$png) {
    $bmp = New-Object Drawing.Bitmap($png)
    try {
        $r = New-Object Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
        $d = $bmp.LockBits($r, [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $buf = New-Object byte[] ($bmp.Width * $bmp.Height * 4)
        for ($y = 0; $y -lt $bmp.Height; $y++) { [Runtime.InteropServices.Marshal]::Copy([IntPtr]($d.Scan0.ToInt64() + $y * $d.Stride), $buf, $y * $bmp.Width * 4, $bmp.Width * 4) }
        $bmp.UnlockBits($d)
        @{ W = $bmp.Width; H = $bmp.Height; B = $buf }
    } finally { $bmp.Dispose() }
}
# Far copy (_s.dds): half size, encoded like a game template DDS (format + mips).
function New-FarDds([string]$png, [byte[]]$template) {
    $i = Read-Bgra $png
    $w = [Math]::Max(1, [int]($i.W / 2)); $h = [Math]::Max(1, [int]($i.H / 2))
    $small = [Raycity.Media.TextureCodec]::Resize($i.B, $i.W, $i.H, $w, $h)
    , [Raycity.Media.TextureCodec]::EncodeDdsLike($template, $small, $w, $h)
}
$script:U16 = New-Object Text.UnicodeEncoding $false, $true
function Get-Utf16Bytes([string]$s) { , ($U16.GetPreamble() + $U16.GetBytes($s)) }
function Set-Utf16([string]$path, [string]$s) { [IO.File]::WriteAllBytes($path, (Get-Utf16Bytes $s)) }

# ---- FileInfo.0m (client file list: size + Adler-32 per 1 MB block) for files under $pkg
function Update-FileInfo([string]$src, [string]$dst, [string]$pkg, [string[]]$rels) {
    $tree = [Raycity.Model.OmUserProperties]::ParseHeaderless([IO.File]::ReadAllBytes($src))
    $done = @()
    foreach ($rel in $rels) {
        $path = Join-Path $pkg $rel
        $size = (Get-Item $path).Length
        $hashes = [Raycity.Model.ClientFileInfo]::BlockHashes($path)
        $entry = $tree.Children | Where-Object { ($_.Pairs | Where-Object { $_.Key -eq 'fileName' }).Value -eq $rel } | Select-Object -First 1
        if (-not $entry) { throw "FileInfo.0m has no entry for $rel" }
        for ($i = 0; $i -lt $entry.Pairs.Count; $i++) {
            if ($entry.Pairs[$i].Key -eq 'size') { $entry.Pairs[$i] = New-Object 'Collections.Generic.KeyValuePair[string,string]' 'size', "$size" }
        }
        [void]$entry.Children.RemoveAll([Predicate[Raycity.Model.OmUserProperties]] { param($c) $c.Name -eq 'Hash' })
        for ($i = 0; $i -lt $hashes.Count; $i++) {
            $h = [Raycity.Model.OmUserProperties]::Create('Hash', '')
            $h.Pairs.Add((New-Object 'Collections.Generic.KeyValuePair[string,string]' 'idx', "$i"))
            $h.Pairs.Add((New-Object 'Collections.Generic.KeyValuePair[string,string]' 'value', "$($hashes[$i])"))
            $entry.Children.Add($h)
        }
        $done += "FileInfo: $rel size $size, $($hashes.Count) block hashes"
    }
    [IO.File]::WriteAllBytes($dst, $tree.ToBytes())
    $done
}

function Get-MountsJson([byte[]]$b) {
    '[' + ((([Raycity.Model.OmMesh]::ReadCarMounts($b)) | ForEach-Object { '{"slot":' + $_.Key + ',"m":[' + (($_.Value | ForEach-Object { F $_ }) -join ",") + ']}' }) -join ",") + ']'
}
