#requires -Version 5.1
Set-StrictMode -Off

# ------------------------------------------------------------------ role parsing + ranking

$script:SplitKeywords = @('platoon', 'squad', 'team')
$script:ScopeLevel = @{ team=0; squad=1; platoon=2; company=3; all=4 }
$script:ScopeRu = @{ team='огневая группа'; squad='отделение'; platoon='взвод'; company='рота'; all='весь состав' }
$script:RoleRu = @{
    rifleman='стрелок'; machinegunner='пулемётчик'; medic='медик'; sapper='сапёр'
    squadleader='командир отделения'; teamleader='командир группы'; platoonleader='командир взвода'
    commander='командир'; grenadier='гранатомётчик'; antitank='противотанковый стрелок'
    sniper='снайпер'; marksman='марксман'; radioman='радист'; crew='экипаж'; pilot='пилот'
    scout='разведчик'; infantry='пехота'
}

function Expand-RoleToken([string]$t) {
    $value = $t.ToLowerInvariant()
    foreach ($keyword in $script:SplitKeywords) { $value = $value -replace $keyword, "|$keyword|" }
    return @($value -split '\|' | Where-Object { $_ })
}

function Get-GroupScope([string[]]$tokens) {
    if ($tokens -contains 'all') { return 'all' }
    if ($tokens -contains 'company') { return 'company' }
    if ($tokens -contains 'platoon' -or $tokens -contains 'pl') { return 'platoon' }
    if ($tokens -contains 'squad') { return 'squad' }
    if ($tokens -contains 'team') { return 'team' }
    # Base/HQ/Recon are not a formation size. Keep it unknown without an explicit
    # scale instead of inventing a platoon or squad from a generic variant name.
    return ''
}

function Test-ScenarioGroup([string]$path) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($path)
    return ($stem -match '(?i)^dim[_-]' -or $path -match '(?i)/RandomSpawn/' -or
        $path -match '(?i)/(Attack|Defend|Flora)/' -or
        $stem -match '(?i)_(opt|attack|defend|flora|randatt\d*)$')
}

function Get-RoleTokens([string]$path) {
    $normalized = ($path -replace '^\{[0-9A-Fa-f]{16}\}', '') -replace '\\', '/'
    $directory = if ($normalized.Contains('/')) { $normalized.Substring(0,$normalized.LastIndexOf('/')) } else { '' }
    $file = [System.IO.Path]::GetFileNameWithoutExtension($normalized)
    $kind = 'other'
    if ($normalized -match '(?i)(^|/)Characters/') { $kind = 'char' }
    elseif ($normalized -match '(?i)(^|/)Groups/') { $kind = 'group' }
    elseif ($normalized -match '(?i)(^|/)Vehicles/') { $kind = 'vehicle' }
    $faction = ''; $sub = ''
    if ($normalized -match '(?i)/(OPFOR|BLUFOR|INDFOR)(?:/|_|$)') { $faction = $Matches[1].ToUpperInvariant() }
    if ($normalized -match '(?i)(RHS_AFRF|RHS_USAF|RHS_GREF|RHS_SAF|(?:Ses_)?CDF|(?:Ses_)?TKR|NAPA|FIA)') {
        $sub = ($Matches[1] -replace '(?i)^Ses_', '').ToUpperInvariant()
    }
    # Split CamelCase while keeping acronyms and vehicle model digits intact.
    $splitName = $file -creplace '([a-z0-9])([A-Z])', '$1_$2' -creplace '([A-Z])([A-Z][a-z])', '$1_$2'
    $equipmentVersion = ''
    $equipmentMatch = [regex]::Match($normalized,'(?i)(?:^|[/_])(vkpo|emr|uniform)[_-]?(\d+(?:\.\d+)?)')
    if ($equipmentMatch.Success) { $equipmentVersion = $equipmentMatch.Groups[1].Value.ToLowerInvariant() + ':' + $equipmentMatch.Groups[2].Value }
    # Equipment versions are a single contextual token; their digits do not mean
    # that the formation itself is variant 3 (VKPO_3.0_PL_Base versus PL_3).
    $splitName = [regex]::Replace($splitName,'(?i)(vkpo|emr|uniform)[_-]?(\d+(?:\.\d+)?)', {
        param($match) $match.Groups[1].Value + ($match.Groups[2].Value -replace '\.','v')
    })
    $raw = New-Object System.Collections.Generic.List[string]
    $hasVariant = $false
    foreach ($piece in ($splitName -split '[_\W]+')) {
        if (-not $piece) { continue }
        $word = $piece.ToLowerInvariant()
        if ($kind -eq 'group' -and $word -match '^\d+$' -and $word -notmatch '^(19|20)\d{2}$') { $hasVariant = $true; continue }
        if ($kind -eq 'group' -and $word -match '^(recon|squad|team|platoon|pl|hq)(\d+)$') {
            $word = $Matches[1]; $hasVariant = $true
        }
        foreach ($part in (Expand-RoleToken $word)) { $raw.Add($part) }
    }
    $joined = '|' + ($raw -join '|') + '|'
    $role = ''
    $rolePatterns = [ordered]@{
        squadleader='sl|squad\|?leader'; teamleader='tl|team\|?leader'; platoonleader='pl\|leader|platoon\|?leader'
        sapper='sapper|engineer|eod'; medic='medic|corpsman'; radioman='radioman|radio\|operator|rto'
        machinegunner='mg|machine\|?gunner|auto\|?rifleman|automatic\|rifleman'
        antitank='at|anti\|?tank|rpg|at\|gunner'; grenadier='grenadier|gl'
        marksman='marksman|dmr'; sniper='sniper'; pilot='pilot'; crew='crew|crewman'
        commander='commander|officer'; rifleman='rifleman|rifl|rifle'; scout='scout|recon'
    }
    # A role describes a character, not an acronym inside a vehicle model name.
    if ($kind -in @('char','group')) {
        foreach ($entry in $rolePatterns.GetEnumerator()) {
            if ($joined -match ('\|(?:' + $entry.Value + ')\|')) { $role = $entry.Key; break }
        }
        if (-not $role) {
            $directoryTokens = ($directory -creplace '([a-z0-9])([A-Z])', '$1_$2').ToLowerInvariant() -split '[_/\\\W]+'
            $directoryJoined = '|' + ($directoryTokens -join '|') + '|'
            foreach ($entry in $rolePatterns.GetEnumerator()) {
                if ($directoryJoined -match ('\|(?:' + $entry.Value + ')\|')) { $role = $entry.Key; break }
            }
        }
        if ($kind -eq 'group' -and $role -eq 'rifleman') { $role = 'infantry' }
    }
    $specialties = @()
    if ($raw -contains 'scout' -or $raw -contains 'recon' -or $normalized -match '(?i)/(Recon|SOCOM)/') { $specialties += 'recon' }
    if ($raw -contains 'ghillie') { $specialties += 'ghillie' }
    $scope = if ($kind -eq 'group') { Get-GroupScope @($raw) } else { '' }
    $vehicleClass = ''; $vehicleModel = ''
    if ($kind -eq 'vehicle') {
        if ($normalized -match '(?i)(?:^|[/_])(btr[_-]?\d+[a-z]*|bmp[_-]?\d+[a-z]*|bmd[_-]?\d+[a-z]*|t[_-]?(?:55|62|64|72|80|90)[a-z]*|m1a\d*|ural\d*|kamaz\d*|uaz\d*|hmmwv|mtvr|mi[_-]?\d+[a-z]*|uh[_-]?\d+[a-z]*)') {
            $vehicleModel = ($Matches[1] -replace '[_-]', '').ToLowerInvariant()
        }
        if ($vehicleModel -match '^(t\d|m1a)' -or $normalized -match '(?i)/Tanks?/' ) { $vehicleClass = 'tank' }
        elseif ($vehicleModel -match '^btr' -or $normalized -match '(?i)/APC/') { $vehicleClass = 'apc' }
        elseif ($vehicleModel -match '^(bmp|bmd)' -or $normalized -match '(?i)/IFV/') { $vehicleClass = 'ifv' }
        elseif ($vehicleModel -match '^(ural|kamaz|mtvr)' -or $normalized -match '(?i)/Trucks?/' ) { $vehicleClass = 'truck' }
        elseif ($vehicleModel -match '^(uaz|hmmwv)' -or $normalized -match '(?i)/(Cars?|Wheeled)/') { $vehicleClass = 'car' }
        elseif ($vehicleModel -match '^(mi|uh)\d' -or $normalized -match '(?i)/Helicopters?/') { $vehicleClass = 'helicopter' }
    }
    $era = ''; $environment = ''
    if ($normalized -match '(?i)(?:/|_)((?:19|20)\d{2}s?|modern|coldwar)(?:/|_|\.)') { $era = $Matches[1].ToLowerInvariant() }
    if ($normalized -match '(?i)(?:/|_)(desert|woodland|winter|summer|arctic)(?:/|_|\.)') { $environment = $Matches[1].ToLowerInvariant() }
    $noise = '^(drg|dim|role|char|character|rhs|afrf|usaf|gref|saf|regular|army|vdv|guard|factions|opfor|blufor|indfor|ussr|us|fia|v2|prefab|group|base|opt)$'
    $tokens = @($raw | Where-Object { $_ -notmatch $noise } | Sort-Object -Unique)
    # Canonical roles participate in overlap, so SL and SquadLeader share a token.
    if ($role) { $tokens = @(@($tokens) + @($role) | Sort-Object -Unique) }
    $familyContext = if ($sub) { $sub } else { $directory.ToLowerInvariant() }
    $family = @($kind,$familyContext,$role,$scope,$vehicleClass,$vehicleModel,($specialties -join ',')) -join ':'
    return [pscustomobject]@{
        FeatureVersion=2; FeatureSource='path'; Path=$normalized
        Faction=$faction; Sub=$sub; UnitFaction=$sub; Kind=$kind; Tokens=$tokens; File=$file
        Role=$role; Specialties=@($specialties); Scope=$scope; HasVariant=$hasVariant
        VehicleClass=$vehicleClass; VehicleModel=$vehicleModel; Era=$era; Environment=$environment
        EquipmentVersion=$equipmentVersion
        Family=$family; Scenario=($kind -eq 'group' -and (Test-ScenarioGroup $normalized))
    }
}

# Keep the array contract used by both UIs. Compatibility is sorted before the
# similarity score: approximate substitutions are manual fallbacks, never leaders.
function Rank-Candidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BrokenPath,
        [Parameter(Mandatory)][hashtable]$ModIndex,
        [hashtable]$CandidateFeatures = @{},
        [ValidateRange(1,2147483647)][int]$Top = 6
    )
    if ([string]::IsNullOrWhiteSpace($BrokenPath)) { throw 'BrokenPath is empty.' }
    $source = Get-RoleTokens $BrokenPath
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($guid in $ModIndex.Keys) {
        $path = $ModIndex[$guid]
        $candidate = $CandidateFeatures[$guid]
        if (-not $candidate -or $candidate.FeatureVersion -ne 2 -or $candidate.Path -ne $path) { $candidate = Get-RoleTokens $path }
        if ($candidate.Kind -ne $source.Kind -or $source.Kind -eq 'other') { continue }
        if ($source.Faction -and $candidate.Faction -and $source.Faction -ne $candidate.Faction) { continue }
        $reasons = New-Object System.Collections.Generic.List[string]
        $warnings = New-Object System.Collections.Generic.List[string]
        $compatibility = 'compatible'; $score = 0.0; $signals = 0
        if ($source.Faction -and $candidate.Faction) { $score += 3; $reasons.Add("сторона: $($source.Faction)") }
        else { $compatibility = 'unknown'; $warnings.Add('сторона определена не полностью') }
        if ($source.Sub -and $candidate.Sub) {
            if ($source.Sub -eq $candidate.Sub) { $score += 4; $reasons.Add("принадлежность: $($source.Sub)") }
            else { $compatibility='approximate'; $score -= 6; $warnings.Add("другая принадлежность: $($source.Sub) → $($candidate.Sub)") }
        } else { $warnings.Add('принадлежность определена не полностью') }
        if ($source.Kind -in @('char','group')) {
            if ($source.Role -and $candidate.Role) {
                if ($source.Role -eq $candidate.Role) { $score += 8; $signals++; $reasons.Add("роль: $($script:RoleRu[$source.Role])") }
                else { $compatibility='approximate'; $score -= 12; $warnings.Add("другая роль: $($script:RoleRu[$source.Role]) → $($script:RoleRu[$candidate.Role])") }
            } else {
                if ($compatibility -ne 'approximate') { $compatibility='unknown' }
                $warnings.Add('роль определена не полностью')
            }
        }
        if ($source.Kind -eq 'group') {
            if ($source.Scope -and $candidate.Scope) {
                if ($source.Scope -eq $candidate.Scope) { $score += 8; $signals++; $reasons.Add("масштаб: $($script:ScopeRu[$source.Scope])") }
                else { $compatibility='approximate'; $score -= 12; $warnings.Add("другой масштаб: $($script:ScopeRu[$source.Scope]) → $($script:ScopeRu[$candidate.Scope])") }
            } else {
                if ($compatibility -ne 'approximate') { $compatibility='unknown' }
                $warnings.Add('масштаб группы определён не полностью')
            }
        }
        if ($source.Kind -eq 'vehicle') {
            if ($source.VehicleClass -and $candidate.VehicleClass) {
                if ($source.VehicleClass -eq $candidate.VehicleClass) { $score += 8; $signals++; $reasons.Add("класс техники: $($source.VehicleClass)") }
                else { $compatibility='approximate'; $score -= 12; $warnings.Add("другой класс техники: $($source.VehicleClass) → $($candidate.VehicleClass)") }
            } else {
                if ($compatibility -ne 'approximate') { $compatibility='unknown' }
                $warnings.Add('класс техники определён не полностью')
            }
            if ($source.VehicleModel -and $candidate.VehicleModel) {
                if ($source.VehicleModel -eq $candidate.VehicleModel) { $score += 8; $signals++; $reasons.Add("модель: $($source.VehicleModel)") }
                else { $score -= 2; $warnings.Add("другая модель: $($source.VehicleModel) → $($candidate.VehicleModel)") }
            }
        }
        foreach ($specialty in $source.Specialties) {
            if ($candidate.Specialties -contains $specialty) { $score += 3; $reasons.Add("специализация: $specialty") }
            else { $score -= 2; $warnings.Add("не подтверждена специализация: $specialty") }
        }
        foreach ($property in @('Era','Environment','EquipmentVersion')) {
            $propertyRu = switch ($property) { 'Era' {'период'} 'Environment' {'окружение'} 'EquipmentVersion' {'версия экипировки'} }
            if ($source.$property -and $candidate.$property) {
                if ($source.$property -eq $candidate.$property) { $score += 2; $reasons.Add("$propertyRu`: $($source.$property)") }
                else { $score -= 2; $warnings.Add("$propertyRu`: $($source.$property) → $($candidate.$property)") }
            }
        }
        if ($candidate.Scenario -ne $source.Scenario) {
            $compatibility='approximate'; $score -= 8; $warnings.Add('различается сценарное назначение группы')
        }
        if ($candidate.HasVariant -and -not $source.HasVariant) { $score -= 1; $warnings.Add('номерной вариант формирования') }
        $overlap = @($source.Tokens | Where-Object { $candidate.Tokens -contains $_ }).Count
        $union = @(@($source.Tokens) + @($candidate.Tokens) | Sort-Object -Unique).Count
        if ($union) { $score += 4.0 * $overlap / $union }
        if ($overlap) { $reasons.Add("совпало признаков названия: $overlap") }
        $order = switch ($compatibility) { 'compatible' {0} 'unknown' {1} default {2} }
        $results.Add([pscustomobject]@{
            Ref=('{' + $guid + '}' + $path); Guid=$guid; Path=$path; Score=[Math]::Round($score,2)
            Compatibility=$compatibility; MatchLevel='low'; MatchLabel='Слабое соответствие'
            Reasons=@($reasons); Warnings=@($warnings); Warn=($warnings -join '; ')
            Scope=$candidate.Scope; ScopeRu=$script:ScopeRu[[string]$candidate.Scope]
            Role=$candidate.Role; Family=$candidate.Family; Features=$candidate; FallbackType=''
            Overlap=$overlap; SortOrder=$order; SemanticSignals=$signals
        })
    }
    $initialRanked = @($results | Sort-Object @{Expression={$_.SortOrder}}, @{Expression={$_.Score};Descending=$true}, Path, Guid)
    $hasSuitableChoice = $false
    if ($source.Kind -eq 'char') {
        if ($source.Role) {
            $hasSuitableChoice = [bool](@($initialRanked | Where-Object { $_.Features.Role -eq $source.Role }).Count)
        }
    } elseif ($source.Kind -eq 'group') {
        $hasSuitableChoice = [bool](@($initialRanked | Where-Object {
            $_.Compatibility -ne 'approximate' -and $source.Scope -and $_.Features.Scope -eq $source.Scope -and
            (-not $source.Role -or $_.Features.Role -eq $source.Role)
        }).Count)
    }
    if (-not $hasSuitableChoice -and $source.Kind -in @('char','group')) {
        foreach ($candidate in $initialRanked) {
            if ($candidate.Compatibility -eq 'approximate' -and $candidate.Warnings -contains 'различается сценарное назначение группы') { continue }
            $isDefaultRole = $false
            if ($source.Kind -eq 'char') {
                $isDefaultRole = $candidate.Features.Role -eq 'rifleman'
            } else {
                $features = $candidate.Features
                $isDefaultRole = ($features.Scope -in @('squad','all') -or $features.Role -eq 'infantry' -or
                    @($features.Tokens | Where-Object { $_ -in @('rifle','rifl','squad','all') }).Count -gt 0) -and -not $features.Scenario
            }
            if (-not $isDefaultRole) { continue }

            # A default rifleman/infantry group is a cautious fallback. Remove the
            # role/scale mismatch penalty only; affiliation and scenario warnings
            # keep their stricter classification.
            $remainingWarnings = @($candidate.Warnings | Where-Object { $_ -notin @('роль определена не полностью') -and $_ -notlike 'другая роль:*' -and $_ -notlike 'другой масштаб:*' -and $_ -notlike 'масштаб группы определён не полностью' })
            if ($candidate.Warnings -contains 'роль определена не полностью' -and $source.Kind -eq 'group' -and $source.Role) {
                $remainingWarnings += 'роль определена не полностью'
            }
            if ($candidate.Warnings -contains 'масштаб группы определён не полностью' -and $source.Kind -eq 'group' -and $source.Scope) {
                $remainingWarnings += 'масштаб группы определён не полностью'
            }
            if ($candidate.Warnings | Where-Object { $_ -like 'другая роль:*' }) { $candidate.Score += 12 }
            if ($candidate.Warnings | Where-Object { $_ -like 'другой масштаб:*' }) { $candidate.Score += 12 }
            $candidate.Warnings = @($remainingWarnings)
            $fallbackText = if ($source.Kind -eq 'char') { 'подходящая роль не найдена — резервный выбор: стрелок (rifleman/rifl/rifle)' } else { 'подходящая группа не найдена — резервный выбор: Squad/Rifl/RifleSquad/All' }
            $candidate.Warnings = @($candidate.Warnings + $fallbackText)
            $candidate.Warn = $candidate.Warnings -join '; '
            $candidate.Reasons = @($candidate.Reasons + $fallbackText)
            $candidate.Compatibility = if (@($remainingWarnings | Where-Object { $_ -like 'другая принадлежность:*' -or $_ -eq 'различается сценарное назначение группы' }).Count) { 'approximate' } else { 'unknown' }
            $candidate.FallbackType = if ($source.Kind -eq 'char') { 'rifleman' } else { 'rifle_group' }
            $candidate.SortOrder = 1
            $candidate.MatchLevel = 'low'
            $candidate.MatchLabel = if ($source.Kind -eq 'char') { 'Резервный стрелок' } else { 'Резервная группа' }
        }
    }
    $ranked = @($initialRanked | Sort-Object @{Expression={$_.SortOrder}}, @{Expression={$_.Score};Descending=$true}, Path, Guid)
    for ($position=0; $position -lt $ranked.Count; $position++) {
        $result = $ranked[$position]
        $knownRole = $source.Kind -eq 'vehicle' -or ($source.Role -and $result.Role)
        if (-not $result.FallbackType -and $result.Compatibility -ne 'approximate' -and $result.SemanticSignals -gt 0 -and $knownRole) {
            $result.MatchLevel='medium'; $result.MatchLabel='Среднее соответствие'
            # This is a rule-based correspondence level, not a probability. A tie
            # and missing metadata cannot become high just because this item is first.
            $margin = if ($ranked.Count -gt 1) { $result.Score - $ranked[1].Score } else { $result.Score }
            if ($position -eq 0 -and $result.Compatibility -eq 'compatible' -and $result.Warnings.Count -eq 0 -and $margin -ge 3) {
                $result.MatchLevel='high'; $result.MatchLabel='Высокое соответствие'
            }
        }
    }
    foreach ($result in @($ranked | Select-Object -First $Top)) {
        $result.PSObject.Properties.Remove('SortOrder')
        $result.PSObject.Properties.Remove('SemanticSignals')
        $result
    }
}

# Keep families represented in the AI prompt rather than filling it with numbered
# versions of a single formation. Approximate replacements remain manual-only.
function Get-AICandidatePool {
    [CmdletBinding()]
    param([object[]]$Candidates, [ValidateRange(1,50)][int]$Top=20, [ValidateRange(1,10)][int]$PerFamily=2)
    $counts=@{}; $selected=New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $Candidates) {
        if ($candidate.Compatibility -eq 'approximate') { continue }
        $family = [string]$candidate.Family
        if (-not $family) { $family = (Get-RoleTokens $candidate.Path).Family }
        if ([int]$counts[$family] -ge $PerFamily) { continue }
        $counts[$family] = [int]$counts[$family] + 1
        $selected.Add($candidate)
        if ($selected.Count -ge $Top) { break }
    }
    return $selected.ToArray()
}


<#
.SYNOPSIS
    Propose automatic replacements for broken prefab references using curated overrides,
    same-GUID resolution, and semantic ranking against the mod catalog. Replaces generate_remap_table.py.
#>
function Invoke-RemapAutoSuggest {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Refs,
        [string]$SourceRoot,
        [string]$RemapTable = $script:RMC.RemapTable,
        [string]$OverridesPath,
        [string]$CatalogPath = $script:RMC.CatalogNew,
        [double]$MinScore = 20.0,
        [switch]$Write,
        [int]$Limit = 200
    )

    if (-not $OverridesPath) {
        $OverridesPath = Join-Path $script:RMToolsRoot 'curated_overrides.json'
    }

    $modIndex = Get-RMEffectiveModIndex -Path $CatalogPath
    if (-not $modIndex.Index -or @($modIndex.Index.Keys).Count -eq 0) {
        if ($CatalogPath -and (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
            $snapshot = Get-NewCatalogModIndex -Path $CatalogPath
            $modIndex = [pscustomobject]@{ Index=$snapshot; Source='catalog'; Live=$false }
        }
    }
    Assert-RMModIndex $modIndex.Index 'remap auto-suggest'

    $newCatalog = Get-NewPrefabsCatalog -Path $CatalogPath
    $catalogByRef = @{}
    $catalogByGuid = @{}
    foreach ($item in $newCatalog) {
        $catalogByRef[$item.fullRef] = $item
        $catalogByGuid[$item.guid.ToUpperInvariant()] = $item
    }

    $candidateFeatures = Get-NewCatalogCandidateFeatures -Path $CatalogPath
    $remap = Load-RemapTable -Path $RemapTable

    $overrides = @{}
    if (Test-Path -LiteralPath $OverridesPath -PathType Leaf) {
        try {
            $doc = Read-Text $OverridesPath | ConvertFrom-Json
            if ($doc -and $doc.PSObject.Properties['overrides'] -and $doc.overrides) {
                foreach ($prop in $doc.overrides.PSObject.Properties) {
                    $overrides[$prop.Name] = [string]$prop.Value
                }
            }
        } catch {
            Write-Warning "Не удалось прочитать curated overrides: $($_.Exception.Message)"
        }
    }

    # Resolve target refs to examine
    $targetRefs = New-Object System.Collections.Generic.List[string]
    if ($Refs -and $Refs.Count -gt 0) {
        foreach ($r in $Refs) {
            $s = if ($r -is [string]) { $r } else { [string]$r.Ref }
            if ($s -and -not $targetRefs.Contains($s)) { $targetRefs.Add($s) }
        }
    } elseif ($SourceRoot) {
        $scan = Get-LegacyRefScan -SourceRoot $SourceRoot
        foreach ($k in $scan.Refs.Keys) {
            if (-not $targetRefs.Contains($k)) { $targetRefs.Add($k) }
        }
    } else {
        # Default: all stubs from remap table
        foreach ($s in $remap.Stubs) {
            if (-not $targetRefs.Contains($s)) { $targetRefs.Add($s) }
        }
    }

    $kept = 0
    $alreadyStubbed = 0
    $alive = 0
    $ignored = 0
    $unresolved = New-Object System.Collections.Generic.List[string]
    $proposals = New-Object System.Collections.Generic.List[object]
    $skippedOverrides = New-Object System.Collections.Generic.List[object]

    foreach ($ref in ($targetRefs | Sort-Object)) {
        $guidMatch = [regex]::Match($ref, '^\{([0-9A-Fa-f]{16})\}')
        $guid = if ($guidMatch.Success) { $guidMatch.Groups[1].Value.ToUpperInvariant() } else { '' }

        # Check if already alive in mod catalog
        if ($guid -and $catalogByGuid.ContainsKey($guid) -and $catalogByGuid[$guid].fullRef -eq $ref) {
            $alive++
            continue
        }

        # Check ignore list
        if ($ref -match $script:IgnoreRx) {
            $ignored++
            continue
        }

        # Priority 0: already decided in the current table (and filled)
        if ($remap.Map.Contains($ref)) {
            $kept++
            continue
        }
        if ($remap.Stubs.Contains($ref)) {
            $alreadyStubbed++
        }

        # Priority 1: curated override
        if ($overrides.ContainsKey($ref)) {
            $target = $overrides[$ref]
            if ($catalogByRef.ContainsKey($target)) {
                $proposals.Add([pscustomobject]@{
                    OldRef = $ref
                    NewRef = $target
                    Reason = 'curated-override'
                    Score  = 100.0
                    Group  = (Get-RemapGroupPath $ref)
                })
                continue
            } else {
                $skippedOverrides.Add([pscustomobject]@{ OldRef=$ref; Target=$target })
            }
        }

        # Priority 2: same GUID in mod catalog under different path
        if ($guid -and $catalogByGuid.ContainsKey($guid)) {
            $item = $catalogByGuid[$guid]
            if ($item.fullRef -ne $ref) {
                $proposals.Add([pscustomobject]@{
                    OldRef = $ref
                    NewRef = $item.fullRef
                    Reason = 'same-guid'
                    Score  = 90.0
                    Group  = (Get-RemapGroupPath $ref)
                })
                continue
            }
        }

        # Priority 3: ranked match against the mod catalog
        $stem = ($ref -replace '^\{[0-9A-Fa-f]{16}\}', '')
        $sourceTokens = Get-RoleTokens $stem
        if ($sourceTokens.Kind -in @('char', 'group', 'vehicle')) {
            $ranked = @(Rank-Candidates -BrokenPath $stem -ModIndex $modIndex.Index -CandidateFeatures $candidateFeatures -Top 3)
            if ($ranked.Count -gt 0) {
                $best = $ranked[0]
                $strong = ($best.Score -ge $MinScore)
                $borderline = ($best.Score -ge 15.0 -and $best.Compatibility -eq 'compatible')
                if ($catalogByRef.ContainsKey($best.Ref) -and ($strong -or $borderline)) {
                    $proposals.Add([pscustomobject]@{
                        OldRef = $ref
                        NewRef = $best.Ref
                        Reason = "ranked $($best.Score) ($($best.MatchLabel))"
                        Score  = $best.Score
                        Group  = (Get-RemapGroupPath $ref)
                    })
                    continue
                }
            }
        }

        $unresolved.Add($ref)
    }

    $written = $false
    if ($Write) {
        $entries = @{}
        $entryGroups = @{}
        foreach ($p in $proposals) {
            $entries[$p.OldRef] = $p.NewRef
            $entryGroups[$p.OldRef] = $p.Group
        }
        foreach ($u in $unresolved) {
            if (-not $remap.Stubs.Contains($u)) {
                $entries[$u] = ''
                $entryGroups[$u] = (Get-RemapGroupPath $u)
            }
        }
        if ($entries.Count -gt 0) {
            Set-RemapEntries -Entries $entries -Path $RemapTable -EntryGroups $entryGroups | Out-Null
            $written = $true
        }
    }

    return [pscustomobject]@{
        Total            = $targetRefs.Count
        Kept             = $kept
        AlreadyStubbed   = $alreadyStubbed
        Alive            = $alive
        Ignored          = $ignored
        ProposedCount    = $proposals.Count
        Proposals        = $proposals.ToArray()
        UnresolvedCount  = $unresolved.Count
        Unresolved       = $unresolved.ToArray()
        SkippedOverrides = $skippedOverrides.ToArray()
        Written          = $written
    }
}
