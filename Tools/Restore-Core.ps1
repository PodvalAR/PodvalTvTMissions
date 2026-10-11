#requires -Version 5.1
<#
.SYNOPSIS
    Shared core logic for restoring legacy PodvalTvT (DRG-era) missions into the
    current addon by remapping only the prefab references that are actually broken.

.DESCRIPTION
    Dot-source this file ( . .\Restore-Core.ps1 ) to get the functions below. It is
    used by BOTH the CLI wrapper (Restore-Mission.ps1) and the local web UI backend
    (UI\Serve-RestoreUI.ps1), so the matching/validation logic lives in exactly one
    place.

    Source of truth for "does this prefab exist" is the MOD PREFAB INDEX, built from
    the *.et.meta files of the PodvalTvTPrefabs addon (GUID -> path). This replaces the
    old self-referential "alive roots" scan, which could mask a restored mission's own
    broken refs when that mission lived under one of the alive roots.

    Reference shape inside .layer/.ent files:  {16-HEX-GUID}Path/To/Prefab.et
    The engine resolves by GUID, so a merely-renamed prefab (same GUID) still works and
    must be left alone.
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ constants
$script:RefRx     = '\{([0-9A-Fa-f]{16})\}([^"]+?\.et)'
$script:RefShape  = '^\{[0-9A-Fa-f]{16}\}.+\.et$'
$script:MetaRefRx = 'Name\s+"\{([0-9A-Fa-f]{16})\}([^"]+?\.et)"'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# A ref whose path matches this "looks like it should ship inside the mod" and, if its
# GUID is not in the mod index and not remapped, is a genuine broken reference.
$script:SuspectRx = '(?i)(drg_|dim_|Char_A2F|Char_RHS|Role_Character|/Group_RHS|/Group_A2F|Ses_|Group_Ses|Group_NAPA|Group_FIA|DRG_)'

# Logic/system prefabs we deliberately DO NOT remap or stub (user rule: restore only
# infantry and some vehicles). Classified as "ignore".
$script:IgnoreRx  = '(?i)(/System/|MissionEndTimer|/Logic/|GameMode|/Modes/|Manager\.et$|Trigger|PerceptionManager|AIWorld)'

# ------------------------------------------------------------------ config
$script:RMC = @{
    AddonRoot      = 'C:\Users\armen\Documents\GitHub\PodvalTvTMissions\PodvalTvTMissions'
    PrefabsModRoot = 'C:\Users\armen\Documents\GitHub\PodvalTvTPrefabs\PodvalTvTPrefabs'
    RemapTable     = (Join-Path $PSScriptRoot 'remap_table.json')
    CatalogNew     = (Join-Path $PSScriptRoot 'catalog_new_prefabs.json')
    CatalogOld     = (Join-Path $PSScriptRoot 'catalog_old_prefabs.json')
    DefaultSourceRoot = 'C:\Users\armen\Desktop\PodvalCommunityEvent\Worlds'
    IndexCache     = (Join-Path $env:TEMP 'podval_mod_index.tsv')
}
function Get-RMConfig { return $script:RMC }
function Set-RMConfig([hashtable]$Overrides) {
    foreach ($k in $Overrides.Keys) { $script:RMC[$k] = $Overrides[$k] }
    return $script:RMC
}

# ------------------------------------------------------------------ io helpers
function Read-Text([string]$Path)  { return [System.IO.File]::ReadAllText($Path) }
function Write-Text([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom) }

# ------------------------------------------------------------------ mod index
# Build GUID(upper) -> relative resource path from all *.et.meta in the prefabs mod.
$script:ModIndexCache = $null
function Build-ModIndex {
    [CmdletBinding()]
    param(
        [string[]]$ModRoots,
        [switch]$Refresh
    )
    if (-not $ModRoots) { $ModRoots = @($script:RMC.PrefabsModRoot) }

    if (-not $Refresh -and $script:ModIndexCache) { return $script:ModIndexCache }

    $cacheFile = $script:RMC.IndexCache
    if (-not $Refresh -and (Test-Path -LiteralPath $cacheFile)) {
        $idx = @{}
        foreach ($line in [System.IO.File]::ReadAllLines($cacheFile, $script:Utf8NoBom)) {
            if ($line) { $p = $line.Split("`t"); if ($p.Length -ge 2) { $idx[$p[0]] = $p[1] } }
        }
        if ($idx.Count -gt 0) { $script:ModIndexCache = $idx; return $idx }
    }

    $idx = @{}
    foreach ($root in $ModRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.et.meta -ErrorAction SilentlyContinue | ForEach-Object {
            $t = [System.IO.File]::ReadAllText($_.FullName)
            $m = [regex]::Match($t, $script:MetaRefRx)
            if ($m.Success) { $idx[$m.Groups[1].Value.ToUpper()] = $m.Groups[2].Value }
        }
    }
    # persist cache
    $lines = foreach ($k in $idx.Keys) { $k + "`t" + $idx[$k] }
    [System.IO.File]::WriteAllLines($cacheFile, [string[]]$lines, $script:Utf8NoBom)
    $script:ModIndexCache = $idx
    return $idx
}

# ------------------------------------------------------------------ catalogs (truth & legacy)

function Build-NewPrefabsCatalog {
    [CmdletBinding()]
    param(
        [string]$Path = $script:RMC.CatalogNew,
        [switch]$Refresh
    )

    $modIndex = Build-ModIndex -Refresh:$Refresh
    $remap = Load-RemapTable

    $mappedCounts = @{}
    foreach ($old in $remap.Map.Keys) {
        $target = $remap.Map[$old]
        $tGuid = Guid-Of $target
        if ($tGuid) {
            $mappedCounts[$tGuid] = [int]$mappedCounts[$tGuid] + 1
        }
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($guid in ($modIndex.Keys | Sort-Object)) {
        $relPath = $modIndex[$guid]
        $name = Split-Path $relPath -Leaf
        $parts = $relPath.Split('/')
        
        $category = 'Other'
        $faction = ''
        $sub = ''
        
        if ($parts[0] -eq 'Prefabs' -and $parts.Length -gt 1) {
            $category = $parts[1]
            if ($parts.Length -gt 3 -and $parts[2] -eq 'Factions') {
                $faction = $parts[3]
                if ($parts.Length -gt 4) { $sub = ($parts[4..($parts.Length - 2)] -join '/') }
            } elseif ($parts.Length -gt 2) {
                $faction = $parts[2]
                if ($parts.Length -gt 3) { $sub = ($parts[3..($parts.Length - 2)] -join '/') }
            }
        }

        $items.Add([pscustomobject]@{
            guid        = $guid
            path        = $relPath
            fullRef     = "{$guid}$relPath"
            name        = $name
            category    = $category
            faction     = $faction
            subCategory = $sub
            mappedCount = if ($mappedCounts.ContainsKey($guid)) { $mappedCounts[$guid] } else { 0 }
        })
    }

    $json = ConvertTo-Json -InputObject $items -Depth 5
    Write-Text $Path $json
    return $items
}

function Build-OldPrefabsCatalog {
    [CmdletBinding()]
    param(
        [string]$Path = $script:RMC.CatalogOld,
        [string]$SourceRoot = $script:RMC.DefaultSourceRoot,
        [switch]$Refresh
    )

    $modIndex = Build-ModIndex
    $remap = Load-RemapTable

    $rx = [regex]'\{([0-9A-Fa-f]{16})\}([^"]+?\.et)'
    $refMap = @{}

    if (Test-Path -LiteralPath $SourceRoot) {
        Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Include *.layer,*.ent -ErrorAction SilentlyContinue | ForEach-Object {
            $t = [System.IO.File]::ReadAllText($_.FullName)
            $mc = $rx.Matches($t)
            if ($mc.Count -gt 0) {
                $rel = $_.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
                $p = $rel.Split([char[]]@('\', '/'))
                $mName = if ($p.Length -gt 1) { $p[0] + '/' + $p[1] } else { $p[0] }
                
                foreach ($m in $mc) {
                    $ref = $m.Value
                    if (-not $refMap.ContainsKey($ref)) {
                        $refMap[$ref] = [pscustomobject]@{ Count = 1; Missions = (New-Object System.Collections.Generic.HashSet[string]) }
                        [void]$refMap[$ref].Missions.Add($mName)
                    } else {
                        $refMap[$ref].Count++
                        [void]$refMap[$ref].Missions.Add($mName)
                    }
                }
            }
        }
    }

    # Ensure any keys already declared in remap_table are included
    foreach ($r in $remap.Map.Keys) {
        if (-not $refMap.ContainsKey($r)) {
            $refMap[$r] = [pscustomobject]@{ Count = 0; Missions = (New-Object System.Collections.Generic.HashSet[string]) }
        }
    }
    foreach ($r in $remap.Stubs.Keys) {
        if (-not $refMap.ContainsKey($r)) {
            $refMap[$r] = [pscustomobject]@{ Count = 0; Missions = (New-Object System.Collections.Generic.HashSet[string]) }
        }
    }

    $oldItems = New-Object System.Collections.Generic.List[object]
    foreach ($ref in $refMap.Keys) {
        $guid = Guid-Of $ref
        $ref -match '^\{[0-9A-Fa-f]{16}\}(.+)$' | Out-Null
        $relPath = if ($Matches) { $Matches[1] } else { $ref }
        $name = Split-Path $relPath -Leaf
        
        $parts = $relPath.Split('/')
        $category = 'Other'
        $faction = ''
        if ($parts[0] -eq 'Prefabs' -and $parts.Length -gt 1) {
            $category = $parts[1]
            if ($parts.Length -gt 3 -and $parts[2] -eq 'Factions') { $faction = $parts[3] }
            elseif ($parts.Length -gt 2) { $faction = $parts[2] }
        }

        $isMod = [bool]($ref -match $script:SuspectRx)
        $isIgnored = [bool]($ref -match $script:IgnoreRx)
        
        $status = 'other'
        $targetRef = ''
        
        if ($remap.Map.Contains($ref) -or ($guid -and $remap.MappedGuids.ContainsKey($guid))) {
            $status = 'mapped'
            $targetRef = if ($remap.Map.Contains($ref)) { $remap.Map[$ref] } else { '' }
        } elseif ($remap.Stubs.Contains($ref)) {
            $status = 'stub'
        } elseif ($guid -and $modIndex.ContainsKey($guid)) {
            $status = 'alive'
        } elseif ($isIgnored) {
            $status = 'system'
        } elseif ($isMod) {
            $status = 'unmapped'
        } else {
            $status = 'external'
        }

        $mList = [string[]]($refMap[$ref].Missions)
        $missionsStr = if ($mList.Length -le 3) { $mList -join ', ' } else { ($mList[0..2] -join ', ') + " (+$($mList.Length - 3))" }

        $oldItems.Add([pscustomobject]@{
            guid        = $guid
            path        = $relPath
            fullRef     = $ref
            name        = $name
            category    = $category
            faction     = $faction
            usageCount  = $refMap[$ref].Count
            missions    = $missionsStr
            status      = $status
            targetRef   = $targetRef
            isModPrefab = $isMod
        })
    }

    $sortedOld = [object[]]@($oldItems | Sort-Object @{ Expression = { $_.isModPrefab }; Descending = $true }, @{ Expression = { $_.usageCount }; Descending = $true })
    $json = ConvertTo-Json -InputObject $sortedOld -Depth 5
    Write-Text $Path $json
    return $sortedOld
}

function Get-NewPrefabsCatalog([string]$Path = $script:RMC.CatalogNew) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return (Build-NewPrefabsCatalog -Path $Path)
    }
    return (Read-Text $Path | ConvertFrom-Json)
}

function Get-OldPrefabsCatalog([string]$Path = $script:RMC.CatalogOld) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return (Build-OldPrefabsCatalog -Path $Path)
    }
    return (Read-Text $Path | ConvertFrom-Json)
}

# ------------------------------------------------------------------ remap table
# Walk the (nested, human-grouped) remap JSON. Any property whose NAME is a full ref is
# an entry; a filled value (also a ref) is an active mapping, an empty/invalid value is
# a stub that is intentionally skipped so it still surfaces as unresolved.
function Load-RemapTable {
    [CmdletBinding()]
    param([string]$Path = $script:RMC.RemapTable)

    $map = [ordered]@{}      # full-old-ref -> full-new-ref (filled only)
    $stubs = [ordered]@{}    # full-old-ref -> '' (declared but unfilled)
    $mappedGuids = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Map=$map; Stubs=$stubs; MappedGuids=$mappedGuids }
    }
    $json = Read-Text $Path | ConvertFrom-Json
    $entries = [ordered]@{}
    $walk = {
        param($node)
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Value -is [string]) {
                if ($p.Name -match $script:RefShape) { $entries[$p.Name] = [string]$p.Value }
            }
            elseif ($null -ne $p.Value -and $p.Value.PSObject -and $p.Value.PSObject.Properties.Count) {
                & $walk $p.Value
            }
        }
    }
    & $walk $json
    foreach ($k in $entries.Keys) {
        if ($entries[$k] -match $script:RefShape) {
            $map[$k] = $entries[$k]
            if ($k -match '^\{([0-9A-Fa-f]{16})\}') { $mappedGuids[$Matches[1].ToUpper()] = $true }
        } else {
            $stubs[$k] = ''
        }
    }
    return [pscustomobject]@{ Map=$map; Stubs=$stubs; MappedGuids=$mappedGuids }
}

function Guid-Of([string]$fullRef) {
    if ($fullRef -match '^\{([0-9A-Fa-f]{16})\}') { return $Matches[1].ToUpper() }
    return $null
}

function Get-RemapFileHash([string]$Path = $script:RMC.RemapTable) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hash = $sha.ComputeHash($bytes)
    return [System.BitConverter]::ToString($hash).Replace('-', '').ToLower()
}

function Validate-RemapEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OldRef,
        [Parameter()][string]$NewRef,
        [Parameter(Mandatory)][hashtable]$ModIndex,
        [Parameter()][hashtable]$OldRefCounts
    )

    if ($OldRef -notmatch $script:RefShape) {
        return [pscustomobject]@{ Status = 'malformed'; Message = 'Старый реф имеет некорректный формат (ожидается {16-HEX-GUID}Path.et)' }
    }
    if ($OldRefCounts -and $OldRefCounts[$OldRef] -gt 1) {
        return [pscustomobject]@{ Status = 'dup'; Message = 'Дубликат: префаб присутствует в нескольких группах базы' }
    }
    if ([string]::IsNullOrWhiteSpace($NewRef)) {
        return [pscustomobject]@{ Status = 'stub'; Message = 'Заглушка (ожидает подбора замены)' }
    }
    if ($NewRef -notmatch $script:RefShape) {
        return [pscustomobject]@{ Status = 'malformed'; Message = 'Новый реф имеет некорректный формат (ожидается {16-HEX-GUID}Path.et)' }
    }
    if ($OldRef -eq $NewRef) {
        return [pscustomobject]@{ Status = 'self-mapping'; Message = 'Старый и новый реф совпадают' }
    }

    $newGuid = Guid-Of $NewRef
    $NewRef -match '^\{[0-9A-Fa-f]{16}\}(.+)$' | Out-Null
    $newRelPath = $Matches[1]

    if (-not $ModIndex.ContainsKey($newGuid)) {
        return [pscustomobject]@{ Status = 'target-missing'; Message = "Целевой префаб {$newGuid} отсутствует в моде" }
    }

    $actualPath = $ModIndex[$newGuid]
    if ($newRelPath -ne $actualPath) {
        return [pscustomobject]@{ Status = 'path-mismatch'; Message = "Путь не совпадает с модом (в моде: $actualPath)" }
    }

    $oldGuid = Guid-Of $OldRef
    if ($ModIndex.ContainsKey($oldGuid)) {
        return [pscustomobject]@{ Status = 'source-alive'; Message = "Исходный префаб найден в текущем моде ($($ModIndex[$oldGuid]))" }
    }

    return [pscustomobject]@{ Status = 'ok'; Message = 'Корректный маппинг' }
}

function Get-RemapModel {
    [CmdletBinding()]
    param([string]$Path = $script:RMC.RemapTable)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            meta        = [pscustomobject]@{ description = ''; status = '' }
            versionHash = ''
            groups      = @()
            tree        = [pscustomobject]@{}
            entries     = @()
            stats       = [pscustomobject]@{ total = 0; filled = 0; stubs = 0; errors = 0; warnings = 0 }
        }
    }

    $raw = Read-Text $Path
    $hash = Get-RemapFileHash $Path
    $json = $raw | ConvertFrom-Json
    $modIndex = Build-ModIndex

    # Count occurrences of old refs to detect dups
    $oldRefCounts = @{}
    $countWalk = {
        param($node)
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Value -is [string] -and $p.Name -match $script:RefShape) {
                $oldRefCounts[$p.Name] = [int]$oldRefCounts[$p.Name] + 1
            } elseif ($null -ne $p.Value -and $p.Value.PSObject -and $p.Value.PSObject.Properties.Count -gt 0 -and $p.Name -notmatch $script:RefShape) {
                & $countWalk $p.Value
            }
        }
    }
    & $countWalk $json

    $entries = New-Object System.Collections.Generic.List[object]
    $groupSet = New-Object System.Collections.Generic.HashSet[string]

    $walk = {
        param($node, [string[]]$trail)
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Name -eq '_meta' -and $trail.Length -eq 0) { continue }
            if ($p.Value -is [string]) {
                if ($p.Name -match $script:RefShape) {
                    $grpStr = $trail -join '/'
                    if ($grpStr) { [void]$groupSet.Add($grpStr) }
                    $v = Validate-RemapEntry -OldRef $p.Name -NewRef $p.Value -ModIndex $modIndex -OldRefCounts $oldRefCounts
                    $entries.Add([pscustomobject]@{
                        oldRef    = $p.Name
                        newRef    = [string]$p.Value
                        group     = $grpStr
                        groupPath = $trail
                        status    = $v.Status
                        statusMsg = $v.Message
                        oldGuid   = (Guid-Of $p.Name)
                        newGuid   = (Guid-Of $p.Value)
                    })
                }
            } elseif ($null -ne $p.Value -and $p.Value.PSObject -and $p.Value.PSObject.Properties.Count -gt 0) {
                $subTrail = $trail + @($p.Name)
                [void]$groupSet.Add(($subTrail -join '/'))
                & $walk $p.Value $subTrail
            }
        }
    }
    & $walk $json @()

    $metaObj = [pscustomobject]@{
        description = if ($json._meta -and $json._meta.description) { [string]$json._meta.description } else { '' }
        status      = if ($json._meta -and $json._meta.status) { [string]$json._meta.status } else { '' }
    }

    $st = @{ total = $entries.Count; filled = 0; stubs = 0; errors = 0; warnings = 0 }
    foreach ($e in $entries) {
        if ($e.status -eq 'stub') { $st.stubs++ }
        elseif ($e.status -eq 'ok') { $st.filled++ }
        elseif ($e.status -in @('target-missing', 'path-mismatch', 'malformed', 'dup')) {
            $st.errors++
            if ($e.newRef) { $st.filled++ }
        }
        elseif ($e.status -in @('source-alive', 'self-mapping')) {
            $st.warnings++
            if ($e.newRef) { $st.filled++ }
        }
    }

    $sortedGroups = @($groupSet) | Sort-Object

    return [pscustomobject]@{
        meta        = $metaObj
        versionHash = $hash
        groups      = $sortedGroups
        tree        = $json
        entries     = $entries.ToArray()
        stats       = [pscustomobject]$st
    }
}


# ------------------------------------------------------------------ ref scan
# Collect unique {GUID}path refs from a mission folder's .layer/.ent files.
function Get-MissionRefs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MissionDir)

    $refs = [ordered]@{}
    Get-ChildItem -LiteralPath $MissionDir -Recurse -File -Include *.layer,*.ent -ErrorAction SilentlyContinue | ForEach-Object {
        $t = Read-Text $_.FullName
        foreach ($m in [regex]::Matches($t, $script:RefRx)) {
            $full = '{' + $m.Groups[1].Value.ToUpper() + '}' + $m.Groups[2].Value
            if (-not $refs.Contains($full)) {
                $refs[$full] = [pscustomobject]@{
                    Ref   = $full
                    Guid  = $m.Groups[1].Value.ToUpper()
                    Path  = $m.Groups[2].Value
                    Count = 0
                }
            }
            $refs[$full].Count++
        }
    }
    return $refs
}

# ------------------------------------------------------------------ classify
# Status: resolved | mapped | broken | ignore | external
function Classify-Refs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Refs,          # ordered map from Get-MissionRefs
        [Parameter(Mandatory)][hashtable]$ModIndex,
        [Parameter(Mandatory)]$Remap           # object from Load-RemapTable
    )
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($full in $Refs.Keys) {
        $r = $Refs[$full]
        $status = 'external'
        if ($ModIndex.ContainsKey($r.Guid)) {
            $status = 'resolved'
        }
        elseif ($Remap.MappedGuids.ContainsKey($r.Guid)) {
            $status = 'mapped'
        }
        elseif ($r.Path -match $script:IgnoreRx -or $full -match $script:IgnoreRx) {
            $status = 'ignore'
        }
        elseif ($full -match $script:SuspectRx) {
            $status = 'broken'
        }
        $out.Add([pscustomobject]@{
            Ref=$r.Ref; Guid=$r.Guid; Path=$r.Path; Count=$r.Count; Status=$status
        })
    }
    return $out
}

# ------------------------------------------------------------------ role parsing + ranking

# Words that pack two role keywords into a single underscore-free token. Without splitting
# them "RifleSquad" never matches "Squad" and "PlatoonHQ" never matches "PL".
$script:SplitKeywords = @('platoon', 'squad', 'team')

function Expand-RoleToken([string]$t) {
    $s = $t
    foreach ($kw in $script:SplitKeywords) { $s = $s -replace $kw, "|$kw|" }
    $out = @()
    foreach ($p in ($s -split '\|')) {
        $p = $p.Trim()
        if ($p) { $out += $p }
    }
    if ($out.Count -eq 0) { return @($t) }
    return $out
}

# Group "scale", ordered. A squad must never be replaced by a platoon HQ: that silently
# changes how many soldiers the scenario spawns.
$script:ScopeLevel = @{ team = 0; squad = 1; platoon = 2; company = 3; all = 4 }
$script:ScopeRu = @{ team = 'команда'; squad = 'взвод'; platoon = 'рота'; company = 'рота'; all = 'весь состав' }

function Get-GroupScope([string[]]$tokens) {
    if ($tokens -contains 'all')   { return 'all' }
    if ($tokens -contains 'base')  { return 'platoon' }
    if (($tokens -contains 'platoon') -or ($tokens -contains 'hq') -or ($tokens -contains 'pl')) { return 'platoon' }
    if ($tokens -contains 'squad') { return 'squad' }
    # "...SniperGroup" / "...FireGroup": squad-sized. A bare leading "Group" is excluded.
    if ($tokens | Where-Object { $_.Length -gt 5 -and $_ -like '*group' }) { return 'squad' }
    if ($tokens -contains 'team')  { return 'team' }
    # "recon" is stripped as noise, so a bare Recon group lands here. Recon formations in
    # this mod are squad-sized. Checked last so ReconPlatoonHQ still resolves to platoon.
    if ($tokens -contains 'recon') { return 'squad' }
    if ($tokens -contains 'rifle') { return 'squad' }
    return ''
}

# Scenario-only groups: scripted spawn sets, not reusable formations.
function Test-ScenarioGroup([string]$path) {
    # match on the file stem, not the full path (the path ends in .et)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($path)
    return ($stem -match '(?i)^dim' -or $path -match '(?i)/RandomSpawn/' -or
            $path -match '(?i)/(Attack|Defend|Flora)/' -or
            $stem -match '(?i)_(opt|attack|defend|flora|randatt\d*)$')
}

function Get-RoleTokens([string]$path) {
    $file = [System.IO.Path]::GetFileNameWithoutExtension($path)   # strips one .et
    $faction = ''
    if ($path -match '(?i)/(OPFOR|BLUFOR|INDFOR)(?:/|_|$)') { $faction = $Matches[1].ToUpper() }
    $sub = ''
    if ($path -match '(?i)(RHS_AFRF|RHS_USAF|RHS_GREF|RHS_SAF)') { $sub = $Matches[1].ToUpper() }
    $kind = 'char'
    if ($path -match '(?i)/Groups/') { $kind = 'group' }
    elseif ($path -match '(?i)/Vehicles/') { $kind = 'vehicle' }
    $noise = 'drg|dim|role|char|character|rhs|afrf|usaf|gref|saf|regular|army|recon|vdv|guard|factions|opfor|blufor|indfor|ussr|us|fia|v2|prefab|group'
    $tok = New-Object System.Collections.Generic.List[string]
    $raw = New-Object System.Collections.Generic.List[string]
    $hasVariant = $false
    $isGroup = ($kind -eq 'group')
    foreach ($t in ($file -split '[_\W]+')) {
        if (-not $t) { continue }
        if ($isGroup) {
            # bare numbers are variant indexes (PL_3, Squad_7, VKPO_3.0), never roles.
            # Matching on them made "VKPO_3.0" collide with "PL_3".
            if ($t -match '^\d+$') { $hasVariant = $true; continue }
            # a digit glued to a word is still a variant index: Recon2 -> Recon + 2
            $base = $t
            if ($t -match '^([A-Za-z]+)\d+$') { $base = $Matches[1]; $hasVariant = $true }
            $parts = Expand-RoleToken $base.ToLower()
            foreach ($p in $parts) { $raw.Add($p) }
            if ($base -match "^($noise)$") { continue }
            foreach ($p in $parts) { $tok.Add($p) }
        } else {
            # characters keep the original tokenisation untouched: stripping digits here
            # turned "V2" into "v" and made Ghillie_V2 squads outrank the correct leader
            if ($t -match "^($noise)$") { continue }
            $tok.Add($t.ToLower())
        }
    }
    $scope = ''
    # scope is read from the raw tokens: "recon" is noise for scoring but still tells us the scale
    if ($kind -eq 'group') { $scope = Get-GroupScope @($raw) }
    return [pscustomobject]@{
        Faction=$faction; Sub=$sub; Kind=$kind; Tokens=@($tok); File=$file
        Scope=$scope; HasVariant=$hasVariant
        # scenario grouping is a group concept; for characters "_opt" just means the
        # optimised variant, not a scripted spawn set
        Scenario = $(if ($kind -eq 'group') { Test-ScenarioGroup $path } else { $false })
    }
}

# Rank mod-index candidates for a broken ref path. Returns up to Top scored suggestions.
function Rank-Candidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BrokenPath,
        [Parameter(Mandatory)][hashtable]$ModIndex,
        [int]$Top = 6
    )
    if ([string]::IsNullOrWhiteSpace($BrokenPath)) {
        throw 'BrokenPath is empty. Pass the prefab resource path, e.g. "Prefabs/Characters/.../X.et".'
    }
    $b = Get-RoleTokens $BrokenPath
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($guid in $ModIndex.Keys) {
        $cp = $ModIndex[$guid]
        $c = Get-RoleTokens $cp
        if ($c.Kind -ne $b.Kind) { continue }                       # never cross char/group/vehicle
        $score = 0.0
        if ($b.Faction -and $c.Faction -eq $b.Faction) { $score += 3 } elseif ($b.Faction -and $c.Faction -and $c.Faction -ne $b.Faction) { continue }
        if ($b.Sub -and $c.Sub -eq $b.Sub) { $score += 3 }
        $overlap = 0
        foreach ($t in $b.Tokens) { if ($c.Tokens -contains $t) { $overlap++ } }
        $score += 2.0 * $overlap
        $diff = [Math]::Abs($b.Tokens.Count - $c.Tokens.Count)
        $score -= 0.25 * $diff

        # --- group scale alignment -------------------------------------------
        # Same scale is rewarded; a squad must not be answered with a platoon HQ.
        # Mismatch is a penalty, not a ban, so the list never comes back empty.
        $scopeWarn = ''
        if ($b.Scope -and $c.Scope) {
            $delta = [Math]::Abs($script:ScopeLevel[$b.Scope] - $script:ScopeLevel[$c.Scope])
            if ($delta -eq 0) { $score += 4 }
            elseif ($delta -ge 2) {
                $score -= 8
                $scopeWarn = "масштаб: $($script:ScopeRu[$b.Scope]) -> $($script:ScopeRu[$c.Scope])"
            }
        }
        # numbered variant (PL_9, Squad_7) when the source has no number
        if ($b.Kind -eq 'group' -and $c.Kind -eq 'group' -and $c.HasVariant -and -not $b.HasVariant) { $score -= 2 }
        # scripted scenario set instead of a reusable formation
        if ($c.Scenario -and -not $b.Scenario) { $score -= 3 }

        if ($overlap -eq 0 -and $score -lt 3) { continue }          # keep same-faction candidates (score>=3) for the UI/AI to choose
        $results.Add([pscustomobject]@{
            Ref   = '{' + $guid + '}' + $cp
            Guid  = $guid
            Path  = $cp
            Score = [Math]::Round($score, 2)
            Overlap = $overlap
            Scope = $c.Scope
            ScopeRu = $(if ($c.Scope) { $script:ScopeRu[$c.Scope] } else { '' })
            Warn = $scopeWarn
        })
    }
    $ranked = $results | Sort-Object -Property Score -Descending
    $maxScore = if ($ranked) { ($ranked | Select-Object -First 1).Score } else { 0 }
    $topN = @($ranked | Select-Object -First $Top)
    # Emit invariant numbers. ConvertTo-Json under a non-invariant culture would emit
    # "0,9" and produce invalid JSON for the browser.
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($r in $topN) {
        $conf = if ($maxScore -gt 0) { $r.Score / $maxScore } else { 0 }
        $r.Score = $r.Score.ToString('0.##', $inv)
        # Confidence is not part of the original object -> must be added explicitly
        $r | Add-Member -NotePropertyName Confidence -NotePropertyValue ($conf.ToString('0.##', $inv)) -Force
    }
    return $topN
}

# ------------------------------------------------------------------ remap table writes
function Escape-JsonString([string]$str) {
    if ($null -eq $str) { return '""' }
    $sb = [System.Text.StringBuilder]::new()
    $chars = $str.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $c = $chars[$i]
        switch ($c) {
            '"'  { [void]$sb.Append('\"'); break }
            '\' { [void]$sb.Append('\\'); break }
            "`r" { [void]$sb.Append('\r'); break }
            "`n" { [void]$sb.Append('\n'); break }
            "`t" { [void]$sb.Append('\t'); break }
            "`b" { [void]$sb.Append('\b'); break }
            "`f" { [void]$sb.Append('\f'); break }
            default {
                $code = [int]$c
                if ($code -lt 32) {
                    [void]$sb.Append([string]::Format('\u{0:x4}', $code))
                } else {
                    [void]$sb.Append($c)
                }
            }
        }
    }
    return '"' + $sb.ToString() + '"'
}

function Format-RemapJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$InputObject,
        [int]$Indent = 4
    )

    $sb = [System.Text.StringBuilder]::new()

    function Serialize-Node($node, [int]$depth) {
        $indentStr = ' ' * ($depth * $Indent)
        $nextIndentStr = ' ' * (($depth + 1) * $Indent)

        if ($null -eq $node) {
            [void]$sb.Append("null")
            return
        }

        if ($node -is [System.Collections.IDictionary] -or $node -is [System.Management.Automation.PSCustomObject]) {
            $props = @()
            if ($node -is [System.Collections.IDictionary]) {
                foreach ($k in $node.Keys) {
                    $props += [pscustomobject]@{ Name = [string]$k; Value = $node[$k] }
                }
            } else {
                foreach ($p in $node.PSObject.Properties) {
                    $props += [pscustomobject]@{ Name = [string]$p.Name; Value = $p.Value }
                }
            }

            if ($props.Count -eq 0) {
                [void]$sb.Append("{}")
                return
            }

            $orderedProps = @()
            if ($depth -eq 0) {
                $meta = $props | Where-Object { $_.Name -eq '_meta' }
                $nonMeta = $props | Where-Object { $_.Name -ne '_meta' }
                if ($meta) { $orderedProps += $meta }
                $groups = $nonMeta | Where-Object { $_.Name -ne '_Unresolved_Pending' }
                $orderedProps += $groups
                $pending = $nonMeta | Where-Object { $_.Name -eq '_Unresolved_Pending' }
                if ($pending) { $orderedProps += $pending }
            } else {
                $metaProps = @($props | Where-Object { $_.Name -like '_*' } | Sort-Object Name)
                $leafProps = @($props | Where-Object { $_.Name -notlike '_*' -and ($_.Value -is [string] -or $null -eq $_.Value -or $_.Value.GetType().IsPrimitive) } | Sort-Object Name)
                $subGroups  = @($props | Where-Object { $_.Name -notlike '_*' -and ($_.Value -isnot [string] -and $null -ne $_.Value -and -not $_.Value.GetType().IsPrimitive) } | Sort-Object Name)
                $orderedProps = $metaProps + $leafProps + $subGroups
            }

            [void]$sb.AppendLine("{")
            for ($i = 0; $i -lt $orderedProps.Count; $i++) {
                $p = $orderedProps[$i]
                $isLast = ($i -eq ($orderedProps.Count - 1))
                $keyEscaped = Escape-JsonString $p.Name
                [void]$sb.Append($nextIndentStr)
                [void]$sb.Append($keyEscaped)
                [void]$sb.Append(": ")
                Serialize-Node $p.Value ($depth + 1)
                if (-not $isLast) {
                    [void]$sb.AppendLine(",")
                } else {
                    [void]$sb.AppendLine()
                }
            }
            [void]$sb.Append($indentStr)
            [void]$sb.Append("}")
            return
        }

        if ($node -is [string]) {
            [void]$sb.Append((Escape-JsonString $node))
            return
        }

        if ($node -is [bool]) {
            [void]$sb.Append($(if ($node) { "true" } else { "false" }))
            return
        }

        if ($node.GetType().IsPrimitive) {
            [void]$sb.Append($node.ToString())
            return
        }

        if ($node -is [System.Collections.IEnumerable]) {
            $items = @($node)
            if ($items.Count -eq 0) {
                [void]$sb.Append("[]")
                return
            }
            [void]$sb.AppendLine("[")
            for ($i = 0; $i -lt $items.Count; $i++) {
                $isLast = ($i -eq ($items.Count - 1))
                [void]$sb.Append($nextIndentStr)
                Serialize-Node $items[$i] ($depth + 1)
                if (-not $isLast) {
                    [void]$sb.AppendLine(",")
                } else {
                    [void]$sb.AppendLine()
                }
            }
            [void]$sb.Append($indentStr)
            [void]$sb.Append("]")
            return
        }

        [void]$sb.Append((Escape-JsonString ($node.ToString())))
    }

    Serialize-Node $InputObject 0
    return $sb.ToString()
}

function Backup-RemapTable([string]$Path = $script:RMC.RemapTable) {
    if (Test-Path -LiteralPath $Path) {
        $bak = "$Path.bak"
        Copy-Item -LiteralPath $Path -Destination $bak -Force
        $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $bakTs = "$Path.bak.$ts"
        Copy-Item -LiteralPath $Path -Destination $bakTs -Force
        return $bakTs
    }
    return $null
}

# Insert key:value entries into a named top-level group (creating it if missing).
# Used for both stubs (value '') and resolved mappings (value = new ref).
function Set-RemapEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Entries,     # oldRef -> newRef ('' for stub)
        [string]$Path = $script:RMC.RemapTable,
        [string]$Group = '_Unresolved_Pending'
    )
    if ($Entries.Count -eq 0) { return [pscustomobject]@{ Added=0; Updated=0 } }
    Backup-RemapTable $Path | Out-Null

    $json = Read-Text $Path | ConvertFrom-Json
    # locate existing key anywhere; if present update in place, else collect for group add
    $added = 0; $updated = 0
    $existingProps = @{}
    $collect = {
        param($node)
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Value -is [string]) {
                if ($p.Name -match $script:RefShape) { $existingProps[$p.Name] = $p }
            } elseif ($null -ne $p.Value -and $p.Value.PSObject -and $p.Value.PSObject.Properties.Count) {
                & $collect $p.Value
            }
        }
    }
    & $collect $json

    $toAdd = @{}
    foreach ($k in $Entries.Keys) {
        if ($existingProps.ContainsKey($k)) {
            $existingProps[$k].Value = [string]$Entries[$k]; $updated++
        } else {
            $toAdd[$k] = [string]$Entries[$k]
        }
    }
    if ($toAdd.Count -gt 0) {
        $grp = $json.PSObject.Properties[$Group]
        if (-not $grp) {
            $json | Add-Member -NotePropertyName $Group -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        foreach ($k in $toAdd.Keys) {
            $json.$Group | Add-Member -NotePropertyName $k -NotePropertyValue $toAdd[$k] -Force
            $added++
        }
    }

    $text = Format-RemapJson $json
    $null = $text | ConvertFrom-Json
    Write-Text $Path $text
    return [pscustomobject]@{ Added=$added; Updated=$updated }
}

function Save-RemapOperations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Operations,
        [Parameter()][string]$ExpectedVersionHash,
        [Parameter()][string]$Path = $script:RMC.RemapTable
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Таблица ремапа не найдена по пути: $Path"
    }

    $currentHash = Get-RemapFileHash $Path
    if ($ExpectedVersionHash -and $currentHash -and ($ExpectedVersionHash -ne $currentHash)) {
        throw "Конфликт версий: файл на диске был изменён другим процессом (актуальный хеш $currentHash, ожидался $ExpectedVersionHash). Обновите страницу."
    }

    $raw = Read-Text $Path
    $root = $raw | ConvertFrom-Json

    function Find-Leaf($node, [string]$key, $trail = @()) {
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Name -eq $key) {
                return [pscustomobject]@{ Parent = $node; Trail = $trail; Property = $p }
            }
            if ($null -ne $p.Value -and $p.Value.PSObject -and $p.Value.PSObject.Properties.Count -gt 0 -and $p.Name -notmatch '^\{[0-9A-Fa-f]{16}\}') {
                $found = Find-Leaf $p.Value $key ($trail + @($p.Name))
                if ($found) { return $found }
            }
        }
        return $null
    }

    function Resolve-GroupNode($rootNode, $groupSpec, [bool]$create = $true) {
        $parts = if ($groupSpec -is [System.Collections.IEnumerable] -and $groupSpec -isnot [string]) {
            @($groupSpec)
        } else {
            ([string]$groupSpec).Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
        $cur = $rootNode
        foreach ($part in $parts) {
            $p = $cur.PSObject.Properties[$part]
            if (-not $p) {
                if (-not $create) { return $null }
                $cur | Add-Member -NotePropertyName $part -NotePropertyValue ([pscustomobject]@{}) -Force
                $p = $cur.PSObject.Properties[$part]
            }
            $cur = $p.Value
        }
        return $cur
    }

    $applied = 0
    foreach ($op in $Operations) {
        $type = [string]$op.op
        switch ($type.ToLower()) {
            'set' {
                $leaf = Find-Leaf $root ([string]$op.oldRef)
                if ($leaf) {
                    $leaf.Property.Value = [string]$op.newRef
                    $applied++
                } else {
                    $target = Resolve-GroupNode $root (if ($op.group) { $op.group } else { '_Unresolved_Pending' }) $true
                    $target | Add-Member -NotePropertyName ([string]$op.oldRef) -NotePropertyValue ([string]$op.newRef) -Force
                    $applied++
                }
            }
            'add' {
                $grpName = if ($op.group) { $op.group } else { '_Unresolved_Pending' }
                $target = Resolve-GroupNode $root $grpName $true
                $target | Add-Member -NotePropertyName ([string]$op.oldRef) -NotePropertyValue ([string]$op.newRef) -Force
                $applied++
            }
            'delete' {
                $leaf = Find-Leaf $root ([string]$op.oldRef)
                if ($leaf) {
                    $leaf.Parent.PSObject.Properties.Remove([string]$op.oldRef)
                    $applied++
                }
            }
            'move' {
                $leaf = Find-Leaf $root ([string]$op.oldRef)
                if ($leaf) {
                    $val = $leaf.Property.Value
                    $leaf.Parent.PSObject.Properties.Remove([string]$op.oldRef)
                    $target = Resolve-GroupNode $root ([string]$op.targetGroup) $true
                    $target | Add-Member -NotePropertyName ([string]$op.oldRef) -NotePropertyValue $val -Force
                    $applied++
                }
            }
            'rename' {
                $leaf = Find-Leaf $root ([string]$op.oldRef)
                if ($leaf) {
                    $val = if ($op.newRef) { [string]$op.newRef } else { $leaf.Property.Value }
                    $leaf.Parent.PSObject.Properties.Remove([string]$op.oldRef)
                    $leaf.Parent | Add-Member -NotePropertyName ([string]$op.newOldRef) -NotePropertyValue $val -Force
                    $applied++
                }
            }
            'meta' {
                if (-not $root._meta) {
                    $root | Add-Member -NotePropertyName '_meta' -NotePropertyValue ([pscustomobject]@{}) -Force
                }
                if ($null -ne $op.description) {
                    if ($root._meta.PSObject.Properties['description']) { $root._meta.description = [string]$op.description }
                    else { $root._meta | Add-Member -NotePropertyName 'description' -NotePropertyValue ([string]$op.description) -Force }
                }
                if ($null -ne $op.status) {
                    if ($root._meta.PSObject.Properties['status']) { $root._meta.status = [string]$op.status }
                    else { $root._meta | Add-Member -NotePropertyName 'status' -NotePropertyValue ([string]$op.status) -Force }
                }
                $applied++
            }
            'note' {
                $grp = Resolve-GroupNode $root ([string]$op.group) $true
                if ([string]::IsNullOrWhiteSpace([string]$op.note)) {
                    if ($grp.PSObject.Properties['_note']) { $grp.PSObject.Properties.Remove('_note') }
                } else {
                    if ($grp.PSObject.Properties['_note']) { $grp._note = [string]$op.note }
                    else { $grp | Add-Member -NotePropertyName '_note' -NotePropertyValue ([string]$op.note) -Force }
                }
                $applied++
            }
            default {
                Write-Warning "Неизвестная операция: $type"
            }
        }
    }

    $formatted = Format-RemapJson $root
    $null = $formatted | ConvertFrom-Json
    $bak = Backup-RemapTable $Path
    Write-Text $Path $formatted

    return [pscustomobject]@{
        ok         = $true
        applied    = $applied
        newHash    = (Get-RemapFileHash $Path)
        backupFile = $bak
    }
}


# ------------------------------------------------------------------ scan (no copy)
function Scan-Mission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MissionDir,
        [string]$RemapTable = $script:RMC.RemapTable,
        [switch]$WriteStubs
    )
    $modIndex = Build-ModIndex
    $remap    = Load-RemapTable -Path $RemapTable
    $refs     = Get-MissionRefs -MissionDir $MissionDir
    $classified = Classify-Refs -Refs $refs -ModIndex $modIndex -Remap $remap

    $broken = @($classified | Where-Object { $_.Status -eq 'broken' })
    if ($WriteStubs -and $broken.Count -gt 0) {
        $stubEntries = @{}
        foreach ($b in $broken) { if (-not $remap.Stubs.Contains($b.Ref) -and -not $remap.Map.Contains($b.Ref)) { $stubEntries[$b.Ref] = '' } }
        if ($stubEntries.Count -gt 0) { Set-RemapEntries -Entries $stubEntries -Path $RemapTable | Out-Null }
    }

    return [pscustomobject]@{
        Mission   = (Split-Path $MissionDir -Leaf)
        Dir       = $MissionDir
        Total     = $classified.Count
        Resolved  = @($classified | Where-Object Status -eq 'resolved').Count
        Mapped    = @($classified | Where-Object Status -eq 'mapped').Count
        Ignore    = @($classified | Where-Object Status -eq 'ignore').Count
        External  = @($classified | Where-Object Status -eq 'external').Count
        Broken    = $broken.Count
        Refs      = $classified
    }
}

# ------------------------------------------------------------------ restore
function Invoke-Restore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceMission,
        [Parameter(Mandatory)][string]$DestDir,
        [string]$RemapTable = $script:RMC.RemapTable,
        [string]$AddonRoot  = $script:RMC.AddonRoot,
        [switch]$Force
    )
    $modIndex = Build-ModIndex
    $remap    = Load-RemapTable -Path $RemapTable
    $map      = $remap.Map

    $missionName = Split-Path $SourceMission -Leaf
    $destMission = Join-Path $DestDir $missionName
    if (Test-Path -LiteralPath $destMission) {
        if (-not $Force) { throw "Destination already exists: $destMission (use -Force)" }
        Remove-Item -LiteralPath $destMission -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    Copy-Item -LiteralPath $SourceMission -Destination $destMission -Recurse -Force

    # apply remap to .layer files
    $replacements = [ordered]@{}
    foreach ($f in (Get-ChildItem -LiteralPath $destMission -Recurse -File -Include *.layer)) {
        $text = Read-Text $f.FullName
        $changed = $false
        foreach ($old in $map.Keys) {
            $n = ([regex]::Matches($text, [regex]::Escape($old))).Count
            if ($n -gt 0) {
                $text = $text.Replace($old, $map[$old])
                if (-not $replacements.Contains($old)) { $replacements[$old] = 0 }
                $replacements[$old] += $n
                $changed = $true
            }
        }
        if ($changed) { Write-Text $f.FullName $text }
    }

    # fix .ent.meta resource path to new location
    $metaFile = Get-ChildItem -LiteralPath $destMission -Filter *.ent.meta | Select-Object -First 1
    $newResourcePath = $null
    if ($metaFile) {
        $meta = Read-Text $metaFile.FullName
        $rel  = $destMission.Substring($AddonRoot.Length).TrimStart('\','/').Replace('\','/')
        $newResourcePath = "$rel/$missionName.ent"
        $meta = [regex]::Replace($meta, '(Name\s+"\{[0-9A-Fa-f]{16}\})[^"]+(")', { param($mm) $mm.Groups[1].Value + $newResourcePath + $mm.Groups[2].Value })
        Write-Text $metaFile.FullName $meta
    }

    # reclassify destination against the mod index
    $destRefs = Get-MissionRefs -MissionDir $destMission
    $remap2   = Load-RemapTable -Path $RemapTable
    $classified = Classify-Refs -Refs $destRefs -ModIndex $modIndex -Remap $remap2
    $broken = @($classified | Where-Object Status -eq 'broken')

    return [pscustomobject]@{
        Mission      = $missionName
        DestMission  = $destMission
        ResourcePath = $newResourcePath
        Replacements = $replacements
        Resolved     = @($classified | Where-Object Status -eq 'resolved').Count
        Mapped       = @($classified | Where-Object Status -eq 'mapped').Count
        Ignore       = @($classified | Where-Object Status -eq 'ignore').Count
        External     = @($classified | Where-Object Status -eq 'external').Count
        Broken       = $broken
        BrokenCount  = $broken.Count
    }
}

# ------------------------------------------------------------------ AI transport
# Invoke-RestMethod in PS 5.1 decodes responses using the ANSI codepage unless the
# server sends charset=utf-8, which mangles all Cyrillic. Use WebClient with explicit
# UTF-8 on both request and response instead.
function Invoke-AnthropicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$BodyJson,
        [Parameter(Mandatory)][string]$ApiKey
    )
    $req = [System.Net.WebRequest]::Create($Uri)
    $req.Method = 'POST'
    $req.ContentType = 'application/json; charset=utf-8'
    $req.Headers.Add('x-api-key', $ApiKey)
    $req.Headers.Add('anthropic-version', '2023-06-01')
    $req.Timeout = 120000
    $req.ReadWriteTimeout = 120000
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($BodyJson)
    $req.ContentLength = $bytes.Length
    $rs = $req.GetRequestStream()
    $rs.Write($bytes, 0, $bytes.Length)
    $rs.Close()
    $resp = $req.GetResponse()
    $stream = $resp.GetResponseStream()
    $ms = New-Object System.IO.MemoryStream
    $stream.CopyTo($ms)
    $respText = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    $resp.Close()
    return ($respText | ConvertFrom-Json)
}

# ------------------------------------------------------------------ AI suggest (optional)
# Calls the justwoker (Anthropic-format) endpoint. API key is read from an env var only.
function Invoke-AISuggest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BrokenRef,
        [Parameter(Mandatory)][object[]]$Candidates,   # from Rank-Candidates
        [string]$ApiKeyEnv = 'JUSTWOKER_API_KEY',
        [string]$BaseUrl   = 'https://api.justwoker.icu/v1',
        [string]$Model     = 'claude-opus-4-8'
    )
    $key = [System.Environment]::GetEnvironmentVariable($ApiKeyEnv)
    if (-not $key) { $key = [System.Environment]::GetEnvironmentVariable($ApiKeyEnv, 'User') }
    if (-not $key) { $key = [System.Environment]::GetEnvironmentVariable($ApiKeyEnv, 'Machine') }
    if (-not $key) { throw "Env var $ApiKeyEnv is not set. AI assist disabled." }
    if (-not $Candidates -or $Candidates.Count -eq 0) { throw "No candidates to choose from." }

    $list = ($Candidates | ForEach-Object {
        $tag = ''
        if ($_.ScopeRu) { $tag = "  [$($_.ScopeRu)]" }
        if ($_.Warn)     { $tag += "  !! $($_.Warn)" }
        "- $($_.Ref)$tag  (score $($_.Score))"
    }) -join "`n"
    $bTok = Get-RoleTokens (($BrokenRef -split '\}',2)[1])
    $bScope = if ($bTok.Scope) { "$($bTok.Scope) ($($script:ScopeRu[$bTok.Scope]))" } else { 'не определён' }

    $sys = "You map a removed Arma Reforger prefab reference to its best replacement. " +
           "You MUST pick exactly one Ref from the provided candidate list (never invent a GUID). " +
           "RULES: " +
           "(1) The TYPE keyword at the end of the filename is authoritative. RifleSquad -> a Squad group, " +
           "PlatoonHQ -> a platoon group (PL/HQ). " +
           "(2) Squad and Platoon are DIFFERENT SCALES. Never answer a squad with a platoon/HQ group or " +
           "a platoon with a squad; a platoon HQ contains several squads and would spawn far too many soldiers. " +
           "(3) Prefer the plain base variant; avoid numbered variants (_3, _7, _9) unless nothing else fits. " +
           "(4) Avoid scripted scenario sets (dim_, RandomSpawn, Attack, Defend, Flora, _OPT) unless nothing else fits. " +
           "(5) If no candidate is a genuine equivalent, answer with the closest one but set confidence <= 0.4. " +
           "Reply ONLY with compact JSON: {""ref"":""<chosen full ref>"",""confidence"":0..1,""reason"":""short""}."
    $user = "Broken reference:`n$BrokenRef`nDetected group scale: $bScope`n`nCandidates (same faction/role family):`n$list"

    $body = @{
        model = $Model
        max_tokens = 400
        system = $sys
        messages = @(@{ role='user'; content=$user })
    } | ConvertTo-Json -Depth 10

    $headers = @{
        'x-api-key'         = $key
        'anthropic-version' = '2023-06-01'
        'content-type'      = 'application/json'
    }
    $resp = Invoke-AnthropicJson -Uri "$BaseUrl/messages" -BodyJson $body -ApiKey $key
    $text = ''
    if ($resp.content) { foreach ($blk in $resp.content) { if ($blk.type -eq 'text') { $text += $blk.text } } }
    # extract JSON object from the reply
    $m = [regex]::Match($text, '\{[\s\S]*\}')
    if (-not $m.Success) { throw "AI reply had no JSON: $text" }
    $parsed = $m.Value | ConvertFrom-Json
    # normalize confidence to an invariant number. The model may answer "0,9" or "0.9";
    # a comma must be normalized BEFORE parsing, otherwise .NET reads it as a thousands
    # separator and turns 0,9 into 9.
    $rawConf = ("{0}" -f $parsed.confidence).Trim() -replace ',', '.'
    $conf = 0.0
    if (-not [double]::TryParse($rawConf, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$conf)) { $conf = 0.0 }
    if ($conf -lt 0) { $conf = 0.0 }
    if ($conf -gt 1) { $conf = 1.0 }
    # guard: chosen ref must be one of the candidates (case-insensitive)
    $validRefs = @($Candidates | ForEach-Object { $_.Ref })
    $match = $validRefs | Where-Object { $_ -eq $parsed.ref -or $_.ToUpper() -eq ("{0}" -f $parsed.ref).ToUpper() } | Select-Object -First 1
    if (-not $match) { throw "AI chose a ref not in candidate list: $($parsed.ref)" }
    return [pscustomobject]@{ Ref=$match; Confidence=[double]$conf.ToString('0.##',[System.Globalization.CultureInfo]::InvariantCulture); Reason=$parsed.reason; Raw=$text }
}

# ------------------------------------------------------------------ AI chat (simple Q&A)
# Same endpoint/key as AI suggest; just a free-form system prompt about this tool.
function Invoke-AIChat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$ApiKeyEnv = 'JUSTWOKER_API_KEY',
        [string]$BaseUrl   = 'https://api.justwoker.icu/v1',
        [string]$Model     = 'claude-opus-4-8'
    )
    $key = [System.Environment]::GetEnvironmentVariable($ApiKeyEnv)
    if (-not $key) { $key = [System.Environment]::GetEnvironmentVariable($ApiKeyEnv, 'User') }
    if (-not $key) { $key = [System.Environment]::GetEnvironmentVariable($ApiKeyEnv, 'Machine') }
    if (-not $key) { throw "Env var $ApiKeyEnv is not set. AI chat disabled." }

    $sys = "Ты помощник по инструменту восстановления миссий Arma Reforger (PodvalTvT). " +
           "Инструмент копирует старые миссии и заменяет ссылки на удалённые префабы на существующие в моде. " +
           "Отвечай кратко и по-русски. Объясняй статусы ссылок (есть в моде / сломано / есть замена / служебное / внешнее) и как подобрать замену."
    $body = @{
        model = $Model
        max_tokens = 700
        system = $sys
        messages = @(@{ role='user'; content = $Message })
    } | ConvertTo-Json -Depth 10

    $headers = @{ 'x-api-key'=$key; 'anthropic-version'='2023-06-01'; 'content-type'='application/json' }
    $resp = Invoke-AnthropicJson -Uri "$BaseUrl/messages" -BodyJson $body -ApiKey $key
    $text = ''
    if ($resp.content) { foreach ($blk in $resp.content) { if ($blk.type -eq 'text') { $text += $blk.text } } }
    return $text
}
