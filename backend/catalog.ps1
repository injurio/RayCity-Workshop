# Read-only game catalogs for the workshop -> workshop\cache\catalog\
#   -Kind cars   : cars.json (car.xml rows whose Data\car\<name>.jmd exists)
#   -Kind plate  : plate.json (+ plate\<tex>.png)
#   -Kind glass  : glass.json (+ glass\<name>.png, colour settings from <name>.xml)
#   -Kind decal  : decal.json (decalinfo list); textures with -Tex <tex> (searched in decal4..decal) -> decal\<tex>.png
#   -Kind lamp   : lamp.json  (lamp.jmd list + lampEffect per name)
#   -Kind wheel  : wheel.json (wheel.jmd list: id, name, mesh, tex)
#   -Kind effect : effect.json (set effects: effectlink.xml options -> relementeffect.xml items -> relement files + kind)
param([Parameter(Mandatory)][ValidateSet("cars", "plate", "glass", "decal", "lamp", "wheel", "effect")][string]$Kind, [string]$Tex, [string]$Name)
. (Join-Path $PSScriptRoot "common.ps1")
$out = Join-Path $Workshop "cache\catalog"
[IO.Directory]::CreateDirectory("$out\$Kind") | Out-Null

function Colors([string]$xml) {
    if (-not $xml) { return '{"custom":false}' }
    $custom = $xml -match "<custom>\s*yes"
    $cols = @()
    foreach ($m in [regex]::Matches($xml, "<color\d>\s*([\d\s]+?)\s*</color\d>")) {
        $n = $m.Groups[1].Value -split "\s+"
        if ($n.Count -eq 4) { $cols += "[" + $n[1] + "," + $n[2] + "," + $n[3] + "]" }
    }
    '{"custom":' + $(if ($custom) { "true" } else { "false" }) + ',"colors":[' + ($cols -join ",") + ']}'
}

switch ($Kind) {
    "cars" {
        $x = Get-XmlText (Get-EntryBytes (Open-Jmd "Data\car\car.jmd") "car.xml")
        $rows = @()
        foreach ($m in [regex]::Matches($x, "<car\s([^>]*?)/>")) {
            $r = @{}
            foreach ($a in [regex]::Matches($m.Groups[1].Value, "(\w+)\s*=\s*'([^']*)'")) { $r[$a.Groups[1].Value] = $a.Groups[2].Value }
            if (-not (Test-Path (Join-Path $Ray "Data\car\$($r.name).jmd"))) { continue }
            $rows += '{"id":' + $r.id + ',"name":' + (ConvertTo-JsonString $r.name) + ',"display":' + (ConvertTo-JsonString $r.displayname) + ',"classId":' + $(if ($r.classId) { $r.classId } else { 0 }) + '}'
        }
        # Our own new cars: <folder around the Workshop>\<project>\package\Data\car\<car>.jmd, registered in that package's car.xml (read only)
        foreach ($pj in Get-ChildItem $Projects -Directory) {
            $pd = Join-Path $pj.FullName "package\Data\car"
            if (-not (Test-Path "$pd\car.jmd")) { continue }
            $px = Get-XmlText (Get-EntryBytes (Open-Jmd "$pd\car.jmd") "car.xml")
            foreach ($m in [regex]::Matches($px, "<car\s([^>]*?)/>")) {
                $r = @{}
                foreach ($a in [regex]::Matches($m.Groups[1].Value, "(\w+)\s*=\s*'([^']*)'")) { $r[$a.Groups[1].Value] = $a.Groups[2].Value }
                $jmd = "$pd\$($r.name).jmd"
                if (-not (Test-Path $jmd)) { continue }
                $rows += '{"id":' + $r.id + ',"name":' + (ConvertTo-JsonString $r.name) + ',"display":' + (ConvertTo-JsonString $r.displayname) + ',"classId":' + $(if ($r.classId) { $r.classId } else { 0 }) + ',"project":' + (ConvertTo-JsonString $pj.Name) + ',"path":' + (ConvertTo-JsonString $jmd) + '}'
            }
        }
        # Cars added by hand to Data\car: their row may only be in the client's car.xml
        # (<client>\Data\car\car.jmd, read only); a car archive with no row anywhere is still listed (id 0).
        $known = @{}
        foreach ($m in [regex]::Matches(($rows -join ","), '"name":"([^"]+)"')) { $known[$m.Groups[1].Value.ToLower()] = 1 }
        $live = @{}
        $liveJmd = Join-Path $Ray "Data\car\car.jmd"
        if (Test-Path $liveJmd) {
            foreach ($m in [regex]::Matches((Get-XmlText (Get-EntryBytes (Open-Jmd $liveJmd) "car.xml")), "<car\s([^>]*?)/>")) {
                $r = @{}
                foreach ($a in [regex]::Matches($m.Groups[1].Value, "(\w+)\s*=\s*'([^']*)'")) { $r[$a.Groups[1].Value] = $a.Groups[2].Value }
                if ($r.name) { $live[$r.name.ToLower()] = $r }
            }
        }
        foreach ($f in Get-ChildItem (Join-Path $Ray "Data\car") -Filter *.jmd) {
            $n = $f.BaseName
            if ($known.ContainsKey($n.ToLower()) -or $n -ieq "car" -or $n -ieq "carinfo") { continue }
            if (-not (Find-Entry (Open-Jmd $f.FullName) "body_2.0m")) { continue }
            $r = $live[$n.ToLower()]
            $note = if ($r) { "in the test client's car.xml only" } else { "no car.xml row" }
            $rows += '{"id":' + $(if ($r -and $r.id) { $r.id } else { 0 }) + ',"name":' + (ConvertTo-JsonString $n) + ',"display":' + (ConvertTo-JsonString $(if ($r) { $r.displayname } else { "" })) +
                ',"classId":' + $(if ($r -and $r.classId) { $r.classId } else { 0 }) + ',"project":' + (ConvertTo-JsonString $note) + '}'
        }
        Write-Utf8 "$out\cars.json" ("[" + ($rows -join ",") + "]")
    }
    "plate" {
        $a = Open-Jmd "Data\car\common\plate.jmd"
        $rows = @()
        foreach ($r in Get-PartList (Get-XmlText (Get-EntryBytes $a "list.xml"))) {
            $b = Get-EntryBytes $a "$($r.tex).png"
            if ($null -eq $b) { continue }
            [IO.File]::WriteAllBytes("$out\plate\$($r.tex).png", $b)
            $rows += '{"id":' + $r.id + ',"name":' + (ConvertTo-JsonString $r.name) + ',"tex":' + (ConvertTo-JsonString $r.tex) + '}'
        }
        Write-Utf8 "$out\plate.json" ("[" + ($rows -join ",") + "]")
    }
    "glass" {
        $a = Open-Jmd "Data\car\common\glass.jmd"
        $all = Get-AllEntries $a
        $rows = @()
        foreach ($p in $all | Where-Object { $_ -like "*.png" -and $_ -notlike "icon/*" }) {
            $n = $p.Substring(0, $p.Length - 4)
            [IO.File]::WriteAllBytes("$out\glass\$p", (Get-EntryBytes $a $p))
            $c = Colors (Get-XmlText (Get-EntryBytes $a "$n.xml"))
            $rows += '{"name":' + (ConvertTo-JsonString $n) + ',"settings":' + $c + '}'
        }
        Write-Utf8 "$out\glass.json" ("[" + ($rows -join ",") + "]")
    }
    "decal" {
        if ($Tex) {
            foreach ($d in "decal4", "decal3", "decal2", "decal") {
                $a = Open-Jmd "Data\car\common\$d.jmd"
                $b = Get-EntryBytes $a "$Tex.png"
                if ($null -eq $b) { continue }
                [IO.File]::WriteAllBytes("$out\decal\$Tex.png", $b)
                $name = if ($Name) { $Name } else { $Tex -replace "^decal_", "" }
                $x = Get-XmlText (Get-EntryBytes $a "$name.xml")
                Write-Utf8 "$out\decal\$Tex.json" (Colors $x)
                "ok $d"; return
            }
            throw "decal texture $Tex not found"
        }
        $rows = @()
        foreach ($r in Get-PartList (Get-XmlText (Get-EntryBytes (Open-Jmd "Data\car\common\decalinfo.jmd") "list.xml"))) {
            $rows += '{"id":' + $r.id + ',"name":' + (ConvertTo-JsonString $r.name) + ',"tex":' + (ConvertTo-JsonString $r.tex) + '}'
        }
        Write-Utf8 "$out\decal.json" ("[" + ($rows -join ",") + "]")
    }
    "lamp" {
        $a = Open-Jmd "Data\car\common\lamp.jmd"
        $rows = @()
        foreach ($r in Get-PartList (Get-XmlText (Get-EntryBytes $a "list.xml"))) {
            $fx = ""
            $x = Get-XmlText (Get-EntryBytes $a "$($r.name).xml")
            if ($x -match "lampEffect\s+name\s*=\s*'([^']+)'") { $fx = $Matches[1] }
            $rows += '{"id":' + $r.id + ',"name":' + (ConvertTo-JsonString $r.name) + ',"mesh":' + (ConvertTo-JsonString $r.mesh) + ',"tex":' + (ConvertTo-JsonString $r.tex) + ',"effect":' + (ConvertTo-JsonString $fx) + '}'
        }
        Write-Utf8 "$out\lamp.json" ("[" + ($rows -join ",") + "]")
    }
    "effect" {
        # Set effects: effectlink.xml options (what set items name) -> effectGroup -> effectItems -> relement\<file>.0m
        $a = Open-Jmd "Data\effect\effect.jmd"
        $all = Get-AllEntries $a
        $x = Get-XmlText (Get-EntryBytes $a "relement/relementeffect.xml")
        $links = Get-XmlText (Get-EntryBytes $a "relement/effectlink.xml")
        $kinds = @{}
        $rows = @()
        foreach ($m in [regex]::Matches($links, "<option\s+name='([^']+)'\s+effect='([^']+)'([^>]*)/>")) {
            $opt = $m.Groups[1].Value; $e = $m.Groups[2].Value; $legend = $m.Groups[3].Value -match "legend='true'"
            $g = [regex]::Match($x, "<effectGroup\s+name=""$([regex]::Escape($e))"">(.*?)</effectGroup>", 's')
            $items = @()
            foreach ($it in [regex]::Matches($g.Groups[1].Value, "<item\s+name=""([^""]+)""")) {
                $iname = $it.Groups[1].Value
                $d = [regex]::Match($x, "<effectItem\s+name=""$([regex]::Escape($iname))""([^>]*?)(/>|>(.*?)</effectItem>)", 's')
                $attr = $d.Groups[1].Value
                $GetAttr = { param($n) [regex]::Match($attr, "$n\s*=\s*[""']([^""']*)[""']").Groups[1].Value }
                $seq = @()
                foreach ($s in [regex]::Matches($d.Groups[3].Value, "<seq\s+([^>]*?)/>")) {
                    $sa = $s.Groups[1].Value
                    $sf = [regex]::Match($sa, "fileName\s*=\s*[""']([^""']+)").Groups[1].Value
                    $seq += '{"file":' + (ConvertTo-JsonString $sf) + ',"loop":' + $(if ($sa -match "loop\s*=\s*[""']true") { "true" } else { "false" }) + ',"next":' + $(if ($sa -match "next\s*=") { "true" } else { "false" }) + '}'
                }
                $files = @(& $GetAttr "fileName") + @([regex]::Matches($d.Groups[3].Value, "fileName\s*=\s*[""']([^""']+)") | ForEach-Object { $_.Groups[1].Value }) | Where-Object { $_ } | Select-Object -Unique
                foreach ($f in $files) {
                    if ($kinds.ContainsKey($f.ToLower())) { continue }
                    $p = $all | Where-Object { $_ -ieq "relement/$f.0m" } | Select-Object -First 1
                    $k = if (-not $p) { "missing" } else { try { $r = [Raycity.File.OmResource]::Parse((Get-EntryBytes $a $p)); if ($r.HasSceneGraph -and $r.TriLists.Count) { "scene" } else { "particles" } } catch { "unreadable" } }
                    $kinds[$f.ToLower()] = $k
                }
                $off = (& $GetAttr "posOffset") -split '\s+' | Where-Object { $_ } | ForEach-Object { [double]$_ }
                $items += '{"name":' + (ConvertTo-JsonString $iname) + ',"file":' + (ConvertTo-JsonString (& $GetAttr "fileName")) + ',"loop":' + $(if ((& $GetAttr "loop") -eq "true") { "true" } else { "false" }) +
                    ',"attach":' + (ConvertTo-JsonString (& $GetAttr "attatchType")) + ',"rot":' + (ConvertTo-JsonString (& $GetAttr "rotType")) + ',"scl":' + (ConvertTo-JsonString (& $GetAttr "sclType")) +
                    ',"offset":[' + ((@($off) + @(0, 0, 0))[0..2] -join ",") + '],"seq":[' + ($seq -join ",") + '],"speed":' + $(if ($d.Groups[3].Value -match "speedSensitive") { "true" } else { "false" }) + '}'
            }
            $rows += '{"option":' + (ConvertTo-JsonString $opt) + ',"name":' + (ConvertTo-JsonString $e) + ',"legend":' + $(if ($legend) { "true" } else { "false" }) + ',"items":[' + ($items -join ",") + ']}'
        }
        $kj = ($kinds.GetEnumerator() | ForEach-Object { (ConvertTo-JsonString $_.Key) + ':' + (ConvertTo-JsonString $_.Value) }) -join ","
        Write-Utf8 "$out\effect.json" ('{"effects":[' + ($rows -join ",") + '],"files":{' + $kj + '}}')
    }
    "wheel" {
        $a = Open-Jmd "Data\car\common\wheel.jmd"
        $rows = @()
        foreach ($r in Get-PartList (Get-XmlText (Get-EntryBytes $a "list.xml"))) {
            $rows += '{"id":' + $r.id + ',"name":' + (ConvertTo-JsonString $r.name) + ',"mesh":' + (ConvertTo-JsonString $r.mesh) + ',"tex":' + (ConvertTo-JsonString $r.tex) + '}'
        }
        Write-Utf8 "$out\wheel.json" ("[" + ($rows -join ",") + "]")
    }
}
"ok $Kind"
