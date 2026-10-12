#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Restore-Core.ps1')
$script:assertions = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:assertions++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert $threw $Message
}
# Exercise the native directory canonicalizer before substituting the filesystem.
$native = Get-RMCanonicalPath $PSScriptRoot
Assert ([System.IO.Directory]::Exists($native)) 'Native canonicalizer opens a real directory without modifying it.'
Assert ((Get-RMAbsolutePath (Join-Path $PSScriptRoot '..\Tests\.')) -eq (Get-RMAbsolutePath $PSScriptRoot)) 'Lexical dot segments normalize.'
$script:A = '{AAAAAAAAAAAAAAAA}Prefabs/Characters/DRG_Rifleman.et'
$script:B = '{BBBBBBBBBBBBBBBB}Prefabs/Characters/Rifleman.et'
$script:C = '{CCCCCCCCCCCCCCCC}Prefabs/Characters/Officer.et'
$script:D = '{DDDDDDDDDDDDDDDD}Prefabs/Characters/DRG_Medic.et'
$script:E = '{EEEEEEEEEEEEEEEE}Prefabs/Objects/Box.et'
$script:table = 'C:\Fixture\fixture-remap.json'
function Reset-Fixture {
    $script:files = @{}
    $script:dirs = @{}
    foreach ($path in @('C:\','C:\Fixture','C:\Fixture\Source','C:\Fixture\Source\Mission','C:\Fixture\Addon','C:\Fixture\Addon\Worlds','C:\Fixture\Mod')) { $script:dirs[$path] = $true }
    $script:aliases = @{}; $script:attributes = @{}
    $script:calls = New-Object System.Collections.Generic.List[string]
    $script:files['C:\Fixture\Mod\B.et.meta'] = 'Name "' + $script:B + '"'
    $script:files['C:\Fixture\Mod\C.et.meta'] = 'Name "' + $script:C + '"'
    $script:files['C:\Fixture\Mod\D.et.meta'] = 'Name "' + $script:D + '"'
    $script:files[$script:table] = '{"_meta":{}}'
    Set-RMConfig @{ PrefabsModRoot='C:\Fixture\Mod'; IndexCache='C:\Fixture\cache'; RemapTable=$script:table; AddonRoot='C:\Fixture\Addon'; CatalogNew='C:\Fixture\fixture-new.json'; CatalogOld='C:\Fixture\fixture-old.json'; DefaultSourceRoot='C:\Fixture\Source' } | Out-Null
}
function Test-Path {
    [CmdletBinding()] param($LiteralPath,$Path,$PathType)
    if (-not $LiteralPath) { $LiteralPath = $Path }
    if ($PathType -eq 'Container') { return $script:dirs.ContainsKey($LiteralPath) }
    if ($PathType -eq 'Leaf') { return $script:files.ContainsKey($LiteralPath) }
    return $script:dirs.ContainsKey($LiteralPath) -or $script:files.ContainsKey($LiteralPath)
}
function Get-Item {
    [CmdletBinding()] param($LiteralPath,[switch]$Force)
    if (-not (Test-Path -LiteralPath $LiteralPath)) { throw "Missing fixture item: $LiteralPath" }
    $isDir = $script:dirs.ContainsKey($LiteralPath)
    $attr = if ($isDir) { [System.IO.FileAttributes]::Directory } else { [System.IO.FileAttributes]::Normal }
    if ($script:attributes.ContainsKey($LiteralPath)) { $attr = $attr -bor $script:attributes[$LiteralPath] }
    [pscustomobject]@{ FullName=$LiteralPath; Name=[System.IO.Path]::GetFileName($LiteralPath); PSIsContainer=$isDir; Attributes=$attr }
}
function Get-ChildItem {
    [CmdletBinding()] param($LiteralPath,[switch]$Recurse,[switch]$File,$Include,$Filter,[switch]$Force)
    $prefix = $LiteralPath.TrimEnd('\') + '\'
    $keys = @($script:files.Keys)
    if (-not $File) { $keys += @($script:dirs.Keys) }
    foreach ($key in $keys) {
        if (-not $key.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = $key.Substring($prefix.Length)
        if (-not $Recurse -and $relative.Contains('\')) { continue }
        $name = [System.IO.Path]::GetFileName($key)
        if ($Filter -and $name -notlike $Filter) { continue }
        if ($Include -and @($Include | Where-Object { $name -like $_ }).Count -eq 0) { continue }
        Get-Item -LiteralPath $key
    }
}
function Read-Text([string]$Path) {
    if ([System.IO.Path]::GetFileName($Path) -in @('catalog_new_prefabs.json','catalog_old_prefabs.json','remap_table.json')) { throw 'Forbidden fixture access.' }
    if (-not $script:files.ContainsKey($Path)) { throw "Missing fixture file: $Path" }
    return $script:files[$Path]
}
function Write-Text([string]$Path,[string]$Text) {
    $script:calls.Add('write '+$Path)
    $script:files[$Path] = $Text
}
function Backup-RemapTable([string]$Path) { $script:calls.Add('backup '+$Path); return $Path+'.mock-backup' }
function Get-RemapFileHash([string]$Path) {
    $hash = [System.Security.Cryptography.SHA1]::Create()
    try { return [System.BitConverter]::ToString($hash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes((Read-Text $Path)))) }
    finally { $hash.Dispose() }
}
function Get-RMPhysicalDirectory([string]$Path) {
    foreach ($alias in $script:aliases.Keys) {
        if ([string]::Equals($Path,$alias,[StringComparison]::OrdinalIgnoreCase)) { return $script:aliases[$alias] }
        if (Test-RMPathWithin $Path $alias) { return $script:aliases[$alias] + $Path.Substring($alias.Length) }
    }
    return $Path
}
function Remove-Item {
    [CmdletBinding()] param($LiteralPath,[switch]$Recurse,[switch]$Force)
    $script:calls.Add('delete '+$LiteralPath)
    foreach ($map in @($script:dirs,$script:files)) {
        foreach ($key in @($map.Keys)) { if (Test-RMPathWithin $key $LiteralPath -AllowEqual) { $map.Remove($key) } }
    }
}
function New-Item {
    [CmdletBinding()] param($ItemType,$Path,[switch]$Force)
    $script:calls.Add('mkdir '+$Path); $script:dirs[$Path] = $true
}
function Copy-Item {
    [CmdletBinding()] param($LiteralPath,$Destination,[switch]$Recurse,[switch]$Force)
    $script:calls.Add('copy '+$LiteralPath)
    if (-not $script:dirs.ContainsKey($LiteralPath)) { throw 'Missing copy source.' }
    foreach ($map in @($script:dirs,$script:files)) {
        foreach ($key in @($map.Keys)) {
            if (Test-RMPathWithin $key $LiteralPath -AllowEqual) { $map[$Destination+$key.Substring($LiteralPath.Length)] = $map[$key] }
        }
    }
}
function Set-Table($Object) { $script:files[$script:table] = ConvertTo-Json -InputObject $Object -Depth 60 }
function Save-Ops([object[]]$Ops) { Save-RemapOperations -Path $script:table -Operations $Ops }
function Read-Table { Read-Text $script:table | ConvertFrom-Json }
function Invoke-FixtureRestore { Invoke-Restore -SourceMission 'C:\Fixture\Source\Mission' -DestDir 'C:\Fixture\Addon\Worlds' -AddonRoot 'C:\Fixture\Addon' -RemapTable $script:table -Force }

# Destructive preflight rejects overlap, missing source, and out-of-addon destinations.
Reset-Fixture
foreach ($dest in @('C:\Fixture\Source','C:\Fixture\Source\Mission','C:\Fixture\Addon\..\Source')) {
    Assert-Throws { Invoke-Restore -SourceMission 'C:\Fixture\Source\Mission' -DestDir $dest -AddonRoot 'C:\Fixture' -Force } 'Overlapping destination is rejected.'
}
Assert ($script:calls.Count -eq 0) 'Overlap checks perform no mutation.'
Assert-Throws { Invoke-Restore -SourceMission 'C:\Fixture\Missing' -DestDir 'C:\Fixture\Addon\Worlds' -Force } 'Missing source is rejected.'
Assert-Throws { Invoke-Restore -SourceMission 'C:\Fixture\Source\Mission' -DestDir 'C:\Fixture\Elsewhere' -AddonRoot 'C:\Fixture\Addon' -Force } 'Outside-addon destination is rejected.'
Assert ($script:calls.Count -eq 0) 'Preflight errors preserve existing data.'
Assert (-not (Test-RMPathWithin 'C:\Fixture\Mission2' 'C:\Fixture\Mission' -AllowEqual)) 'Sibling prefix is not containment.'
$script:dirs['C:\Fixture\Alias'] = $true
$script:aliases['C:\Fixture\Alias'] = 'C:\Fixture\Source'
Assert-Throws { Invoke-Restore -SourceMission 'C:\Fixture\Source\Mission' -DestDir 'C:\Fixture\Alias' -AddonRoot 'C:\Fixture' -Force } 'Junction alias overlap is rejected.'
$script:dirs['C:\Fixture\Source\Mission\Link'] = $true
$script:attributes['C:\Fixture\Source\Mission\Link'] = [System.IO.FileAttributes]::ReparsePoint
Assert-Throws { Invoke-FixtureRestore } 'Source tree reparse point is rejected.'
Assert ($script:calls.Count -eq 0) 'Reparse and alias checks perform no mutation.'
Reset-Fixture
$script:dirs['C:\Fixture\Addon\Worlds\Mission'] = $true
$script:files['C:\Fixture\Addon\Worlds\Mission\existing.ent'] = 'preserve'
$script:dirs.Remove('C:\Fixture\Source\Mission')
Assert-Throws { Invoke-FixtureRestore } 'Absent source cannot replace an existing destination.'
Assert ($script:calls.Count -eq 0 -and $script:files['C:\Fixture\Addon\Worlds\Mission\existing.ent'] -eq 'preserve') 'Missing-source preflight preserves existing bytes.'
Reset-Fixture
$script:dirs['C:\Fixture\Addon\Worlds\Mission'] = $true
$script:dirs['C:\Fixture\Addon\Worlds\Mission\Link'] = $true
$script:attributes['C:\Fixture\Addon\Worlds\Mission\Link'] = [System.IO.FileAttributes]::ReparsePoint
Assert-Throws { Invoke-FixtureRestore } 'Existing destination with a reparse child is rejected.'
Assert ($script:calls.Count -eq 0) 'Destination reparse checks run before deletion.'

# Actual GUID-based restore touches both formats, preserves live GUIDs and avoids cascades.
Reset-Fixture
Set-Table ([pscustomobject]@{ Group=[pscustomobject]@{ $script:A=$script:B; $script:B=$script:C; $script:D=$script:C } })
$lower = $script:A.Replace('AAAAAAAAAAAAAAAA','aaaaaaaaaaaaaaaa')
$alternate = '{AAAAAAAAAAAAAAAA}Prefabs/Characters/DRG_OldName.et'
$script:files['C:\Fixture\Source\Mission\Mission.layer'] = '"'+$script:A+'" "'+$alternate+'" "'+$script:B+'" "'+$script:D+'"'
$script:files['C:\Fixture\Source\Mission\Mission.ent'] = '"'+$lower+'" "'+$script:A+'"'
$result = Invoke-FixtureRestore
Assert ($result.Replacements[$script:A] -eq 4) 'GUID matches in ent/layer and alternate paths count correctly.'
Assert ($result.BrokenCount -eq 0 -and $result.Mapped -eq 0) 'Final report only describes resolved output references.'
Assert ($script:files['C:\Fixture\Addon\Worlds\Mission\Mission.ent'] -eq ('"'+$script:B+'" "'+$script:B+'"')) '.ent is remapped.'
Assert ($script:files['C:\Fixture\Addon\Worlds\Mission\Mission.layer'].Contains($script:D)) 'Live original GUID is preserved.'
Assert (-not $script:files['C:\Fixture\Addon\Worlds\Mission\Mission.layer'].Contains($script:C)) 'Replacement targets do not cascade.'
$scan = Scan-Mission -MissionDir 'C:\Fixture\Source\Mission' -RemapTable $script:table
Assert ($scan.Mapped -gt 0) 'Source scans retain replacement-ready status.'

# Conflicts are detected from all raw occurrences, including duplicate full refs.
foreach ($otherKey in @($script:A,$alternate)) {
    Reset-Fixture
    Set-Table ([pscustomobject]@{ A=[pscustomobject]@{ $script:A=$script:B }; B=[pscustomobject]@{ $otherKey=$script:C } })
    $script:files['C:\Fixture\Source\Mission\Mission.ent'] = '"'+$script:A+'"'
    $result = Invoke-FixtureRestore
    Assert ($result.Replacements.Count -eq 0 -and $result.BrokenCount -eq 1) 'Ambiguous target remains broken instead of applying arbitrarily.'
}
Reset-Fixture
Set-Table ([pscustomobject]@{ Group=[pscustomobject]@{ $script:E='' } })
$script:files['C:\Fixture\Source\Mission\Mission.ent'] = '"'+$script:E+'"'
$scan = Scan-Mission -MissionDir 'C:\Fixture\Source\Mission' -RemapTable $script:table
Assert ($scan.External -eq 1 -and $scan.Broken -eq 0) 'External empty stub preserves external classification.'
Set-Table ([pscustomobject]@{ Group=[pscustomobject]@{ $script:E='{FFFFFFFFFFFFFFFF}Prefabs/Objects/Missing.et' } })
$result = Invoke-FixtureRestore
Assert ($result.BrokenCount -eq 1 -and $result.Replacements.Count -eq 0) 'Unavailable filled external replacement remains broken.'
$script:files['C:\Fixture\Source\Mission\Mission.ent'] = '"{EEEEEEEEEEEEEEEE}Prefabs/System/Manager.et"'
$scan = Scan-Mission -MissionDir 'C:\Fixture\Source\Mission' -RemapTable $script:table
Assert ($scan.Ignore -eq 1) 'Invalid replacement preserves ignore precedence.'

# Cache keys include roots; stale contents require manual refresh.
Reset-Fixture
$first = Build-ModIndex
$script:dirs['C:\Fixture\OtherMod'] = $true
$script:files['C:\Fixture\OtherMod\E.et.meta'] = 'Name "'+$script:E+'"'
$other = Build-ModIndex -ModRoots @('C:\Fixture\OtherMod')
Assert ($other.Count -eq 1 -and $other.ContainsKey('EEEEEEEEEEEEEEEE')) 'Custom roots do not reuse a different root cache.'
$script:files['C:\Fixture\OtherMod\F.et.meta'] = 'Name "{FFFFFFFFFFFFFFFF}Prefabs/Objects/New.et"'
Assert ((Build-ModIndex -ModRoots @('C:\Fixture\OtherMod')).Count -eq 1) 'Cache deliberately retains manual-refresh semantics.'
Assert ((Build-ModIndex -ModRoots @('C:\Fixture\OtherMod') -Refresh).Count -eq 2) 'Explicit refresh rebuilds the requested roots.'
$script:ModIndexCache = @{}
Assert ((Build-ModIndex).Count -eq $first.Count) 'Disk cache is isolated by root key.'

# Scoped operations address one group, including root [] and slash-containing segments.
Reset-Fixture
Set-Table ([pscustomobject]@{ A=[pscustomobject]@{ $script:A=$script:B }; B=[pscustomobject]@{ $script:A=$script:C } })
Save-Ops @([pscustomobject]@{op='set';oldRef=$script:A;newRef='';groupPath=@('A')}) | Out-Null
$tree = Read-Table
Assert ($tree.A.PSObject.Properties[$script:A].Value -eq '' -and $tree.B.PSObject.Properties[$script:A].Value -eq $script:C) 'Scoped set affects exactly one duplicate.'
$before = Read-Text $script:table; $script:calls.Clear()
Assert-Throws { Save-Ops @([pscustomobject]@{op='delete';oldRef=$script:A}) } 'Legacy duplicate lookup is rejected as ambiguous.'
Assert-Throws { Set-RemapEntries -Path $script:table -Entries @{$script:A=''} } 'Legacy bulk setter rejects ambiguous writes.'
Assert ((Read-Text $script:table) -eq $before -and $script:calls.Count -eq 0) 'Ambiguous failures create neither backup nor write.'
Save-Ops @([pscustomobject]@{op='delete';oldRef=$script:A;groupPath=@('A')}) | Out-Null
Assert (-not (Read-Table).A.PSObject.Properties[$script:A] -and (Read-Table).B.PSObject.Properties[$script:A]) 'Scoped delete preserves the other duplicate.'
Set-Table ([pscustomobject]@{ $script:A=$script:B; 'A/B'=[pscustomobject]@{$script:D=$script:C} })
Save-Ops @([pscustomobject]@{op='set';oldRef=$script:A;newRef=$script:C;groupPath=[string[]]@()}) | Out-Null
Assert ((Read-Table).PSObject.Properties[$script:A].Value -eq $script:C) 'Empty groupPath addresses root.'
Save-Ops @([pscustomobject]@{op='set';oldRef=$script:D;newRef='';groupPath=@('A/B')}) | Out-Null
Assert ((Read-Table).'A/B'.PSObject.Properties[$script:D].Value -eq '') 'Group path segments do not split embedded slashes.'
Save-Ops @([pscustomobject]@{op='set';oldRef=$script:E;newRef=$script:B}) | Out-Null
Assert ((Read-Table)._Unresolved_Pending.PSObject.Properties[$script:E]) 'Legacy missing set inserts into the default group.'
Save-Ops @([pscustomobject]@{op='set';oldRef='{FFFFFFFFFFFFFFFF}Prefabs/Objects/New.et';newRef='';group='New/Sub'}) | Out-Null
Assert ((Read-Table).New.Sub.PSObject.Properties.Count -gt 0) 'Legacy missing set accepts string destination paths.'

# Ordered batches and destination collisions preserve the on-disk fixture on failure.
Reset-Fixture
Set-Table ([pscustomobject]@{ A=[pscustomobject]@{$script:A=$script:B}; B=[pscustomobject]@{$script:A=$script:C}; $script:D=$script:B })
foreach ($op in @(
    [pscustomobject]@{op='add';oldRef=$script:A;newRef='';group=@('B')},
    [pscustomobject]@{op='move';oldRef=$script:A;groupPath=@('A');targetGroup=@('B')},
    [pscustomobject]@{op='rename';oldRef=$script:D;newOldRef=$script:D;groupPath=[string[]]@();newRef=$script:C}
)) {
    if ($op.op -eq 'rename') {
        Save-Ops @($op) | Out-Null
        Assert ((Read-Table).PSObject.Properties[$script:D].Value -eq $script:C) 'Rename to the same key can update its value.'
        continue
    }
    $before = Read-Text $script:table; $script:calls.Clear()
    Assert-Throws { Save-Ops @($op) } 'Existing destination cannot be overwritten.'
    Assert ((Read-Text $script:table) -eq $before -and $script:calls.Count -eq 0) 'Collision failure leaves bytes and backups untouched.'
}
Save-Ops @([pscustomobject]@{op='move';oldRef=$script:A;groupPath=@('A');targetGroup=@('A')}) | Out-Null
Assert ((Read-Table).A.PSObject.Properties[$script:A]) 'Move to the same group is safe.'
Save-Ops @(
    [pscustomobject]@{op='move';oldRef=$script:A;groupPath=@('A');targetGroup=@('New/Exact')},
    [pscustomobject]@{op='set';oldRef=$script:A;newRef='';groupPath=@('New/Exact')}
) | Out-Null
Assert ((Read-Table).'New/Exact'.PSObject.Properties[$script:A].Value -eq '') 'Move then scoped set follows the new address.'
$before = Read-Text $script:table; $script:calls.Clear()
Assert-Throws { Save-Ops @(
    [pscustomobject]@{op='delete';oldRef=$script:A;groupPath=@('New/Exact')},
    [pscustomobject]@{op='set';oldRef=$script:A;newRef=$script:B;groupPath=@('New/Exact')}
) } 'Scoped set cannot recreate a deleted source.'
Assert ((Read-Text $script:table) -eq $before -and $script:calls.Count -eq 0) 'Failure rolls back the entire in-memory batch.'
Set-Table ([pscustomobject]@{$script:A=$script:B;$script:D=$script:C})
$before = Read-Text $script:table; $script:calls.Clear()
Assert-Throws { Save-Ops @([pscustomobject]@{op='rename';oldRef=$script:A;newOldRef=$script:D;groupPath=[string[]]@()}) } 'Rename collision is rejected.'
Assert ((Read-Text $script:table) -eq $before -and $script:calls.Count -eq 0) 'Rename collision preserves both entries.'
Assert-Throws { Save-Ops @([pscustomobject]@{op='set';oldRef=$script:E;newRef='';groupPath=[string[]]@()}) } 'Scoped missing source is an error.'
Assert-Throws { Save-Ops @([pscustomobject]@{op='set';oldRef=$script:E;newRef='';group=@($script:A)}) } 'A leaf cannot be used as a group.'
$result = Save-Ops @([pscustomobject]@{op='delete';oldRef=$script:E})
Assert ($result.applied -eq 0) 'Legacy missing delete remains a no-op.'
$before = Read-Text $script:table; $script:calls.Clear()
Assert-Throws { Save-RemapOperations -Path $script:table -Operations @() -ExpectedVersionHash 'stale' } 'Version mismatch remains rejected.'
Assert ((Read-Text $script:table) -eq $before -and $script:calls.Count -eq 0) 'Version mismatch does not write.'

# Public collection properties stay arrays at zero, one and multiple elements.
Reset-Fixture
$builtNew = Get-NewPrefabsCatalog
$builtOld = Get-OldPrefabsCatalog
Assert ($builtNew -is [array] -and $builtNew.Count -eq 3 -and $builtNew[0] -isnot [array]) 'Missing new catalog builds a flat array.'
Assert ($builtOld -is [array] -and $builtOld.Count -eq 0) 'Missing old catalog builds a flat empty array.'
foreach ($count in @(0,1,2)) {
    Reset-Fixture
    $items = @()
    for ($i=0; $i -lt $count; $i++) { $items += [pscustomobject]@{guid=$i} }
    $script:files['C:\Fixture\fixture-new.json'] = ConvertTo-Json -InputObject $items -Depth 5
    $script:files['C:\Fixture\fixture-old.json'] = $script:files['C:\Fixture\fixture-new.json']
    Assert ((Get-NewPrefabsCatalog) -is [array] -and (Get-NewPrefabsCatalog).Count -eq $count) 'New catalog result retains array shape.'
    Assert ((Get-OldPrefabsCatalog) -is [array] -and (Get-OldPrefabsCatalog).Count -eq $count) 'Old catalog result retains array shape.'
    $tree = [pscustomobject]@{}
    $texts = @()
    for ($i=0; $i -lt $count; $i++) {
        $key = if ($i -eq 0) {$script:A} else {$script:E}
        $tree | Add-Member -NotePropertyName ('Group'+$i) -NotePropertyValue ([pscustomobject]@{$key=''})
        $texts += '"'+$key+'"'
    }
    Set-Table $tree
    $script:files['C:\Fixture\Source\Mission\Mission.ent'] = $texts -join ' '
    $model = Get-RemapModel -Path $script:table
    $scan = Scan-Mission -MissionDir 'C:\Fixture\Source\Mission' -RemapTable $script:table
    Assert ($model.groups -is [array] -and $model.groups.Count -eq $count) 'Model groups retain array shape.'
    Assert ($model.entries -is [array] -and $model.entries.Count -eq $count) 'Model entries retain array shape.'
    Assert ($scan.Refs -is [array] -and $scan.Refs.Count -eq $count) 'Scan refs retain array shape.'
}
Write-Output ("PASS: {0} assertions; PowerShell {1}; all data IO mocked." -f $script:assertions,$PSVersionTable.PSVersion)
