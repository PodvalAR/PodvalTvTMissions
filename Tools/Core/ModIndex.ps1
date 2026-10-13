#requires -Version 5.1
Set-StrictMode -Off

# ------------------------------------------------------------------ mod index
# Build GUID(upper) -> relative resource path from all *.et.meta in the prefabs mod.
$script:ModIndexCache = @{}
$script:ModIndexWarned = $false
$script:ModIndexUnavailable = $false
function Build-ModIndex {
    [CmdletBinding()]
    param(
        [string[]]$ModRoots,
        [switch]$Refresh
    )
    if (-not $ModRoots) { $ModRoots = @($script:RMC.PrefabsModRoot) }

    # An unconfigured prefab mod is a normal first-run state, not a crash: the UI still
    # starts, the persisted catalog still answers suggestions, and the operations that
    # genuinely need the prefab mod report an actionable error.
    $requested = @($ModRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($requested.Count -eq 0) {
        if (-not $script:ModIndexWarned) {
            Write-Verbose 'Prefab mod root is not configured. Set PrefabsModRoot in the local tool config.'
            $script:ModIndexWarned = $true
        }
        $script:ModIndexUnavailable = $true
        return @{}
    }

    $roots = @($requested | ForEach-Object { Get-RMCanonicalPath $_ } | Sort-Object -Unique)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $key = [System.BitConverter]::ToString($sha.ComputeHash($script:Utf8NoBom.GetBytes(
            (($roots | ForEach-Object { $_.ToLowerInvariant() }) -join "`n")
        ))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    if (-not $Refresh -and $script:ModIndexCache.ContainsKey($key)) { return $script:ModIndexCache[$key] }

    $cacheFile = $script:RMC.IndexCache + '.' + $key + '.tsv'
    if (-not $Refresh -and (Test-Path -LiteralPath $cacheFile)) {
        $idx = @{}
        foreach ($line in ((Read-Text $cacheFile) -split '\r?\n')) {
            if ($line) {
                $p = $line.Split("`t")
                if ($p.Length -eq 2 -and $p[0] -match '^[0-9A-Fa-f]{16}$') { $idx[$p[0].ToUpperInvariant()] = $p[1] }
            }
        }
        if ($idx.Count -gt 0) { $script:ModIndexCache[$key] = $idx; return $idx }
    }

    $idx = @{}
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            if (-not $script:ModIndexWarned) {
                Write-Warning ("Prefab mod directory not found: {0}" -f $root)
                $script:ModIndexWarned = $true
            }
            $script:ModIndexUnavailable = $true
            continue
        }
        Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.et.meta -ErrorAction Stop | ForEach-Object {
            $t = Read-Text $_.FullName
            $m = [regex]::Match($t, $script:MetaRefRx)
            if ($m.Success) { $idx[$m.Groups[1].Value.ToUpper()] = $m.Groups[2].Value }
        }
    }
    if ($idx.Count -gt 0) { $script:ModIndexUnavailable = $false }
    # persist cache
    $lines = foreach ($k in $idx.Keys) { $k + "`t" + $idx[$k] }
    try { Write-Text $cacheFile (($lines -join "`n") + "`n") }
    catch { Write-Verbose "Unable to persist mod index cache: $_" }
    $script:ModIndexCache[$key] = $idx
    return $idx
}

# ------------------------------------------------------------------ catalogs (truth & legacy)

function Build-NewPrefabsCatalog {
    [CmdletBinding()]
    param(
        [string]$Path = $script:RMC.CatalogNew,
        [switch]$Refresh
    )

    # The rebuilt snapshot supersedes whatever was derived from the previous one.
    $script:NewCatalogCache = $null
    $script:NewFeatureCache = @{}
    $modIndex = Build-ModIndex -Refresh:$Refresh
    Assert-RMModIndex $modIndex 'build prefab catalog'
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

        if ($category -notin @('Characters', 'Groups', 'Vehicles')) {
            continue
        }

        if ($relPath -like 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF*') {
            continue
        }

        if ($faction -in @('Vests', 'HeadGear', 'Uniforms', 'HandWear', 'Headwear', 'Eyewear', 'Helmet', 'Vest')) {
            continue
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
            matchingFeatures = Get-RoleTokens $relPath
        })
    }

    $json = ConvertTo-Json -InputObject $items -Depth 8
    Write-Text $Path $json
    return ,($items.ToArray())
}

# ------------------------------------------------------------------ legacy usage
# How often and in which legacy missions each old prefab reference occurs. This is the
# only information the remap table cannot hold: the table answers "what replaces what",
# the scan answers "where is the broken reference still sitting".
#
# The scan is deliberately explicit and never runs on a page load. It walks every
# *.layer/*.ent under the operator's legacy root, so it is expensive; instead of being
# repeated forever, its result is written to a machine-owned report and the interesting
# findings are folded into the remap table as stubs.
function Assert-RMLegacySourceRoot([string]$SourceRoot, [string]$Operation = 'scan legacy missions') {
    $shown = if ([string]::IsNullOrWhiteSpace($SourceRoot)) { 'не задан' } else { $SourceRoot }
    if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
        throw ("Корневой каталог старых миссий недоступен ($Operation): DefaultSourceRoot = $shown. " +
               "Укажите его в локальном файле настроек $($script:RMC.UserConfig) и перезапустите инструмент.")
    }
    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw ("Корневой каталог старых миссий не найден ($Operation): $SourceRoot")
    }
    return $SourceRoot
}

# ref -> @{ Count = <occurrences>; Missions = HashSet<string> }
function Get-LegacyRefScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceRoot)

    $root = Assert-RMLegacySourceRoot $SourceRoot
    $rootPrefix = $root.TrimEnd('\', '/')
    $rx = [regex]$script:RefRx
    $refMap = @{}
    $missionSet = New-Object System.Collections.Generic.HashSet[string]

    Get-ChildItem -LiteralPath $root -Recurse -File -Include *.layer,*.ent -ErrorAction SilentlyContinue | ForEach-Object {
        $t = Read-Text $_.FullName
        $mc = $rx.Matches($t)
        if ($mc.Count -eq 0) { return }

        $rel = $_.FullName.Substring($rootPrefix.Length).TrimStart('\', '/')
        $p = $rel.Split([char[]]@('\', '/'))
        # A mission is identified by its first two relative segments (region/folder),
        # which is stable enough to group usages without hardcoding any mission layout.
        $mName = if ($p.Length -gt 1) { $p[0] + '/' + $p[1] } else { $p[0] }
        if (-not $missionSet.Contains($mName)) { $missionSet.Add($mName) }

        foreach ($m in $mc) {
            $guid = $m.Groups[1].Value.ToUpper()
            $ref = '{' + $guid + '}' + $m.Groups[2].Value
            if (-not $refMap.ContainsKey($ref)) {
                # Shaped like Get-MissionRefs so Classify-Refs can consume the sweep
                # result directly; Missions is the only extra the report needs.
                $refMap[$ref] = [pscustomobject]@{
                    Ref      = $ref
                    Guid     = $guid
                    Path     = $m.Groups[2].Value
                    Count    = 0
                    Missions = (New-Object System.Collections.Generic.HashSet[string])
                }
            }
            $refMap[$ref].Count++
            [void]$refMap[$ref].Missions.Add($mName)
        }
    }

    return [pscustomobject]@{ Refs=$refMap; Missions=@($missionSet | Sort-Object) }
}

# The single place that turns "broken references" into declared remap stubs. Every caller
# (mission scan, restore report, legacy sweep) goes through here so the group name, the
# deduplication rule and the optimistic write stay identical.
function Add-RemapStubs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]$Broken,   # objects with a Ref property
        [string]$RemapTable = $script:RMC.RemapTable,
        [string]$Group = '_Unresolved_Pending'
    )
    $remap = Load-RemapTable -Path $RemapTable
    $entries = @{}
    foreach ($b in @($Broken)) {
        $ref = if ($b -is [string]) { $b } else { [string]$b.Ref }
        if (-not $ref) { continue }
        if ($remap.Map.Contains($ref) -or $remap.Stubs.Contains($ref)) { continue }
        $entries[$ref] = ''
    }
    if ($entries.Count -eq 0) { return [pscustomobject]@{ Added=0; Updated=0; Refs=[string[]]@() } }
    $result = Set-RemapEntries -Entries $entries -Path $RemapTable -Group $Group
    return [pscustomobject]@{ Added=$result.Added; Updated=$result.Updated; Refs=[string[]]@($entries.Keys) }
}

# Sweep the legacy root, declare every broken reference in the remap table and persist the
# usage report. DryRun performs the full scan but writes nothing, so the operator can see
# what a sweep would change before committing to it.
function Sync-LegacyRefsToRemapTable {
    [CmdletBinding()]
    param(
        [string]$SourceRoot = $script:RMC.DefaultSourceRoot,
        [string]$RemapTable  = $script:RMC.RemapTable,
        [string]$ReportPath  = $script:RMC.LegacyReport,
        [switch]$Write,
        [switch]$NoReport
    )
    Assert-RMLegacySourceRoot $SourceRoot

    $modIndex = Build-ModIndex
    Assert-RMModIndex $modIndex 'scan legacy missions'
    $remap = Load-RemapTable -Path $RemapTable

    $scan = Get-LegacyRefScan -SourceRoot $SourceRoot
    $classified = Classify-Refs -Refs $scan.Refs -ModIndex $modIndex -Remap $remap
    $broken = @($classified | Where-Object { $_.Status -eq 'broken' })

    # Only broken references become stubs. Resolved, mapped, ignored and external refs
    # need no decision and would only add noise to the table the operator maintains.
    $stubs = if ($Write) { Add-RemapStubs -Broken $broken -RemapTable $RemapTable } else { [pscustomobject]@{ Added=0; Updated=0; Refs=[string[]]@() } }

    # The report is a machine-owned artifact: a dry run writes nothing at all.
    $writtenReport = ''
    if ($Write -and -not $NoReport) {
        $statusByRef = @{}
        foreach ($c in $classified) { $statusByRef[$c.Ref] = $c.Status }
        $refs = New-Object System.Collections.Generic.List[object]
        foreach ($ref in $scan.Refs.Keys) {
            $hit = $scan.Refs[$ref]
            $missions = [string[]]@($hit.Missions | Sort-Object)
            $refs.Add([pscustomobject]@{
                fullRef    = $ref
                usageCount = $hit.Count
                missions   = $missions
                status     = [string]$statusByRef[$ref]
            })
        }
        $sorted = [object[]]@($refs | Sort-Object -Property @{ Expression='usageCount'; Descending=$true }, fullRef)
        $doc = [pscustomobject]@{
            _meta = [pscustomobject]@{
                description = 'Отчёт о применении старых префабов в legacy-миссиях. Генерируется сканером (Sync-LegacyRefsToRemapTable), вручную не правится.'
                schema      = 1
                sourceRoot  = $SourceRoot
                scannedAt   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
                missionCount = @($scan.Missions).Count
                refCount    = $sorted.Count
                remapHash   = [string](Get-RemapFileHash -Path $RemapTable)
            }
            refs = $sorted
        }
        Write-Text $ReportPath ((ConvertTo-Json -InputObject $doc -Depth 6) + "`n")
        $writtenReport = $ReportPath
    }

    return [pscustomobject]@{
        SourceRoot = $SourceRoot
        Missions   = [string[]]@($scan.Missions)
        Total      = $classified.Count
        Resolved   = @($classified | Where-Object Status -eq 'resolved').Count
        Mapped     = @($classified | Where-Object Status -eq 'mapped').Count
        Ignore     = @($classified | Where-Object Status -eq 'ignore').Count
        External   = @($classified | Where-Object Status -eq 'external').Count
        Broken     = $broken.Count
        Written    = [bool]$Write
        Added      = $stubs.Added
        AddedRefs  = [string[]]@($stubs.Refs)
        ReportPath = $writtenReport
    }
}

# Read the persisted usage report. Staleness is judged against the remap table hash, not
# against a timestamp: a table edited after the sweep is the only thing that can make the
# usage numbers misleading.
function Get-LegacyRefReport {
    [CmdletBinding()]
    param(
        [string]$Path = $script:RMC.LegacyReport,
        [string]$RemapTable = $script:RMC.RemapTable
    )
    $empty = [pscustomobject]@{
        Exists=$false; Stale=$false; SourceRoot=''; ScannedAt=''; MissionCount=0; RefCount=0
        Refs=[object[]]@(); Path=$Path
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $empty }

    $doc = $null
    try { $doc = Read-Text $Path | ConvertFrom-Json }
    catch { return $empty }
    if (-not $doc -or $null -eq $doc.PSObject.Properties['refs']) { return $empty }

    $meta = if ($null -ne $doc.PSObject.Properties['_meta']) { $doc._meta } else { $null }
    $refItems = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($doc.refs)) {
        if (-not $item -or -not $item.PSObject.Properties['fullRef']) { continue }
        $refItems.Add([pscustomobject]@{
            fullRef    = [string]$item.fullRef
            usageCount = [int]$item.usageCount
            missions   = [string[]]@($item.missions)
            status     = [string]$item.status
        })
    }
    $recordedHash = if ($meta) { [string]$meta.remapHash } else { '' }
    $currentHash = [string](Get-RemapFileHash -Path $RemapTable)

    return [pscustomobject]@{
        Exists       = $true
        Stale        = ($recordedHash -ne $currentHash)
        SourceRoot   = if ($meta) { [string]$meta.sourceRoot } else { '' }
        ScannedAt    = if ($meta) { [string]$meta.scannedAt } else { '' }
        MissionCount = if ($meta) { [int]$meta.missionCount } else { 0 }
        RefCount     = $refItems.Count
        Refs         = [object[]]$refItems.ToArray()
        Path         = $Path
    }
}

# Deriving matchingFeatures is the single most expensive thing a page load can ask for:
# Get-RoleTokens costs ~3ms per prefab, so a full mod catalog is seconds of wall clock and
# roughly 5MB of JSON. Only the ranker consumes those features, and it runs on demand
# behind a single "Подобрать" click. Every reader that merely lists prefabs therefore passes
# -SkipFeatures and stays cheap; the ranker derives what it needs on its own via
# Get-NewCatalogCandidateFeatures, which fills $script:NewFeatureCache so a second
# suggestion costs nothing.
function Get-NewPrefabsCatalog {
    [CmdletBinding()]
    param(
        [string]$Path = $script:RMC.CatalogNew,
        [switch]$SkipFeatures
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return ,(Build-NewPrefabsCatalog -Path $Path)
    }
    $fileInfo = Get-Item -LiteralPath $Path
    $signature = "$Path|$($fileInfo.Length)|$($fileInfo.LastWriteTimeUtc.Ticks)|2"
    if ($script:NewCatalogCache -and $script:NewCatalogCache.Signature -eq $signature -and
        ($SkipFeatures -or $script:NewCatalogCache.FeaturesPrepared)) {
        return ,$script:NewCatalogCache.Items
    }
    $parsedItems = Read-Text $Path | ConvertFrom-Json
    $items = @($parsedItems)
    $featuresPrepared = $true
    foreach ($item in $items) {
        # Old catalogs remain usable without being rewritten. Never trust features
        # copied from a different path or generated by a different parser version.
        $prepared = $item.matchingFeatures
        if ($prepared -and $prepared.FeatureVersion -eq 2 -and $prepared.Path -eq $item.path) { continue }
        if ($SkipFeatures) { $featuresPrepared = $false; continue }
        $prepared = Get-RoleTokens $item.path
        $item | Add-Member -NotePropertyName matchingFeatures -NotePropertyValue $prepared -Force
    }
    $script:NewCatalogCache = [pscustomobject]@{
        Signature=$signature; Items=$items; FeaturesPrepared=$featuresPrepared
    }
    return ,$items
}

# Candidate suggestions use the persisted truth catalog so the picker and ranker
# operate on the same refreshed snapshot. The catalog is rebuilt from *.et.meta by
# the explicit catalog refresh action in the UI.
function Get-NewCatalogModIndex([string]$Path = $script:RMC.CatalogNew) {
    $catalog = Get-NewPrefabsCatalog -Path $Path -SkipFeatures
    $index = @{}
    foreach ($item in $catalog) {
        $guid = [string]$item.guid
        $prefabPath = [string]$item.path
        if ($guid -match '^[0-9A-Fa-f]{16}$' -and $prefabPath -match '(?i)\.et$') {
            $index[$guid.ToUpperInvariant()] = $prefabPath
        }
    }
    if ($index.Count -eq 0) {
        throw "Prefab catalog is empty or invalid: $Path. Refresh the prefab catalog and try again."
    }
    return $index
}

# Only the ranker needs the derived features, so this is the single place that pays for
# them. Features already persisted in the catalog are reused as-is; anything missing is
# derived once and kept in $script:NewFeatureCache, keyed by the same catalog signature so
# a rebuild drops them automatically. Reusing the persisted value also means a catalog that
# was prepared once by Build-NewPrefabsCatalog never needs deriving at all.
function Get-NewCatalogCandidateFeatures([string]$Path = $script:RMC.CatalogNew) {
    $catalog = Get-NewPrefabsCatalog -Path $Path -SkipFeatures
    if (-not $script:NewFeatureCache -or $script:NewFeatureCache.Signature -ne $script:NewCatalogCache.Signature) {
        $script:NewFeatureCache = [pscustomobject]@{ Signature=$script:NewCatalogCache.Signature; Features=@{} }
    }
    $cached = $script:NewFeatureCache.Features
    $features = @{}
    foreach ($item in $catalog) {
        $guid = [string]$item.guid
        if ($guid -notmatch '^[0-9A-Fa-f]{16}$' -or [string]$item.path -notmatch '(?i)\.et$') { continue }
        $key = $guid.ToUpperInvariant()
        if (-not $cached.ContainsKey($key)) {
            $prepared = $item.matchingFeatures
            if (-not $prepared -or $prepared.FeatureVersion -ne 2 -or $prepared.Path -ne $item.path) {
                $prepared = Get-RoleTokens $item.path
            }
            $cached[$key] = $prepared
        }
        $features[$key] = $cached[$key]
    }
    return $features
}

# The read-only remap table must stay usable when the prefab mod is absent. Validating
# against an EMPTY index would report every filled entry as "target missing", which is
# a false alarm, so fall back to the persisted catalog snapshot and report that the
# result came from a snapshot rather than from the live mod.
function Get-RMEffectiveModIndex([string]$Path = $script:RMC.CatalogNew) {
    $live = Build-ModIndex
    if ($live -and @($live.Keys).Count -gt 0) {
        return [pscustomobject]@{ Index=$live; Source='mod'; Live=$true }
    }
    $catalogPath = if (-not [string]::IsNullOrWhiteSpace($Path)) { $Path } else { [string]$script:RMC.CatalogNew }
    if (-not [string]::IsNullOrWhiteSpace($catalogPath) -and (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        try {
            $snapshot = Get-NewCatalogModIndex -Path $catalogPath
            return [pscustomobject]@{ Index=$snapshot; Source='catalog'; Live=$false }
        } catch { }
    }
    return [pscustomobject]@{ Index=@{}; Source='none'; Live=$false }
}

function Get-OldPrefabsCatalog([string]$Path = $script:RMC.CatalogOld) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    $items = Read-Text $Path | ConvertFrom-Json
    return ,@($items)
}
