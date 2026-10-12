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
function New-Index([string[]]$Paths) {
    $index = @{}
    for ($i = 0; $i -lt $Paths.Count; $i++) { $index[($i + 1).ToString('X16')] = $Paths[$i] }
    return $index
}
function Find-Candidate($Candidates, [string]$Suffix) {
    return $Candidates | Where-Object { $_.Path.EndsWith($Suffix, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
}

# Canonical roles survive legacy abbreviations, CamelCase and path normalization.
$sl = Get-RoleTokens 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/drg_Role_RHS_USAF_SL.et'
$leader = Get-RoleTokens 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_RHS_USAF_SquadLeader.et'
$mg = Get-RoleTokens 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_RHS_USAF_MG.et'
$gunner = Get-RoleTokens 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_RHS_USAF_MachineGunner.et'
Assert ($sl.Role -eq 'squadleader' -and $leader.Role -eq $sl.Role) 'SL and SquadLeader resolve to the same canonical role.'
Assert ($mg.Role -eq 'machinegunner' -and $gunner.Role -eq $mg.Role) 'MG and MachineGunner resolve to the same canonical role.'
$sapper = Get-RoleTokens 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/SOCOM/drg_Role_RHS_USAF_SOCOM_ScoutSapper.et'
Assert ($sapper.Role -eq 'sapper') 'Compound ScoutSapper keeps the sapper role.'
Assert ($sapper.Specialties -contains 'recon') 'Compound ScoutSapper records the reconnaissance specialty.'
Assert ($sapper.Specialties -is [array]) 'Specialties retain array shape even for one specialty.'
Assert ($sapper.FeatureVersion -eq 2) 'Extracted matching features identify their schema version.'
$normalized = Get-RoleTokens '{ABCDEF1234567890}Prefabs\Characters\Factions\BLUFOR\RHS_USAF\Char_RHS_USAF_SL.et'
Assert ($normalized.Role -eq $sl.Role -and $normalized.Faction -eq $sl.Faction -and $normalized.Kind -eq $sl.Kind) 'Full resource references and backslashes normalize before extraction.'
$folderMedic = Get-RoleTokens 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Medic/Char_RHS_USAF_Default.et'
Assert ($folderMedic.Role -eq 'medic') 'An explicit role folder supplies a missing filename role.'
$unknownRole = Get-RoleTokens 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_RHS_USAF_Unclassified.et'
Assert ($unknownRole.Role -notin @('rifleman','medic','squadleader','machinegunner','sapper')) 'Unknown characters do not receive an invented infantry role.'

# Formation scope must come from its formation token, never from Base or HQ alone.
$squad = Get-RoleTokens 'Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_RifleSquad_Base.et'
$platoon = Get-RoleTokens 'Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_PL_Base.et'
$team = Get-RoleTokens 'Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_FireTeam.et'
Assert ($squad.Scope -eq 'squad') 'RifleSquad_Base remains a squad.'
Assert ($platoon.Scope -eq 'platoon') 'PL_Base resolves to platoon scale.'
Assert ($team.Scope -eq 'team') 'FireTeam resolves to team scale.'
foreach ($stem in @('Base','HQ')) {
    $scope = (Get-RoleTokens ('Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_' + $stem + '.et')).Scope
    Assert ($scope -eq 'unknown' -or [string]::IsNullOrWhiteSpace($scope)) 'Base and HQ alone do not imply platoon scale.'
}
$era = Get-RoleTokens 'Prefabs/Groups/OPFOR/RHS_AFRF/2000s/Group_RHS_AFRF_PL_Base.et'
Assert (([string]$era.Era) -match '2000') 'Era digits in directory names remain meaningful features.'
Assert (-not $era.HasVariant) 'Era digits do not turn an unnumbered formation into a numbered variant.'
$variant = Get-RoleTokens 'Prefabs/Groups/OPFOR/RHS_AFRF/Group_RHS_AFRF_Recon2.et'
Assert ($variant.HasVariant) 'A numbered formation variant is still detected.'
Assert ($variant.Specialties -contains 'recon') 'Removing variant suffixes preserves reconnaissance specialty.'
$equipmentBase = 'Prefabs/Groups/OPFOR/RHS_AFRF/MSV/Group_RHS_RF_MSV_VKPO_3.0_PL_Base.et'
$equipmentNumbered = $equipmentBase -replace 'PL_Base','PL_3'
$equipmentFeatures = Get-RoleTokens $equipmentBase
Assert (-not $equipmentFeatures.HasVariant -and $equipmentFeatures.EquipmentVersion -eq 'vkpo:3.0') 'Equipment decimal versions are retained without inventing a formation variant.'
Assert ((Get-RoleTokens $equipmentNumbered).HasVariant) 'A formation number remains a variant alongside an equipment version.'
$equipmentRanked = @(Rank-Candidates -BrokenPath 'Prefabs/Groups/OPFOR/RHS_AFRF/MSV/Group_RHS_RF_MSV_VKPO_Summer_PL_Base.et' -ModIndex (New-Index @($equipmentNumbered,$equipmentBase)) -Top 20)
Assert ($equipmentRanked[0].Path -eq $equipmentBase) 'An equipment version does not make PL_3 tie with the plain PL_Base formation.'
$yearFeatures = Get-RoleTokens 'Prefabs/Groups/OPFOR/RHS_AFRF/Group_RHS_AFRF_1944_RifleSquad.et'
Assert (-not $yearFeatures.HasVariant -and $yearFeatures.Era -eq '1944') 'Historical years are era information rather than formation numbers.'
$btr70 = Get-RoleTokens 'Prefabs/Vehicles/Wheeled/APC/OPFOR/RHS_AFRF/BTR70/RHS_BTR70.et'
$btr80 = Get-RoleTokens 'Prefabs/Vehicles/Wheeled/APC/OPFOR/RHS_AFRF/BTR80/RHS_BTR80.et'
Assert (-not [string]::IsNullOrWhiteSpace($btr70.VehicleClass)) 'Vehicle directories expose a vehicle class.'
Assert (-not [string]::IsNullOrWhiteSpace($btr70.VehicleModel) -and $btr70.VehicleModel -ne $btr80.VehicleModel) 'Vehicle model numbers distinguish BTR70 from BTR80.'

# Character role compatibility outranks incidental name and faction overlap.
$brokenRifle = 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Desert/drg_Role_RHS_USAF_Rifleman.et'
$riflePath = 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_RHS_USAF_Rifleman.et'
$mgPath = 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Desert/drg_Role_RHS_USAF_MachineGunner.et'
$medicPath = 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Desert/drg_Role_RHS_USAF_Medic.et'
$unknownPath = 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_RHS_USAF_Unclassified.et'
Assert ((Get-RoleTokens $brokenRifle).Environment -eq 'desert') 'Environment directory contributes a prepared feature.'
$ranked = @(Rank-Candidates -BrokenPath $brokenRifle -ModIndex (New-Index @($mgPath,$medicPath,$unknownPath,$riflePath)) -Top 20)
Assert ($ranked.Count -eq 4 -and $ranked[0] -isnot [array]) 'Ranker emits flat candidate objects, including explicit manual fallbacks.'
Assert ($ranked[0].Path -eq $riflePath -and $ranked[0].Compatibility -eq 'compatible') 'A compatible rifleman wins over a better filename match with the wrong role.'
$wrongRole = Find-Candidate $ranked 'MachineGunner.et'
Assert ($wrongRole.Compatibility -eq 'approximate' -and $wrongRole.MatchLevel -eq 'low') 'A machine gunner offered for a rifleman is marked approximate and low confidence.'
Assert ($wrongRole.Warnings.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($wrongRole.Warn)) 'Wrong role includes a visible warning.'
$unknown = Find-Candidate $ranked 'Unclassified.et'
Assert ($unknown.Compatibility -eq 'unknown' -and $unknown.MatchLevel -eq 'low') 'Unknown roles remain candidates with explicit uncertainty.'
Assert ($ranked[0].MatchLevel -in @('high','medium')) 'Known compatible roles can earn useful correspondence levels.'

# A broken role with no suitable counterpart still has to produce something, so the ranker
# offers the plain rifleman as a last resort. That reserve must be advertised as such:
# neither the UI label nor the AI may read it as a real correspondence. The stem is built
# from code points so the assertion survives any source-file encoding.
$reserveWord = -join ([char]0x0440, [char]0x0435, [char]0x0437, [char]0x0435, [char]0x0440, [char]0x0432)
$noMatchChar = @(Rank-Candidates -BrokenPath 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/drg_CompletelyOdd_Thing.et' -ModIndex (New-Index @($riflePath,'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_RHS_USAF_Sniper.et')) -Top 20)
$reserveMan = Find-Candidate $noMatchChar 'Char_RHS_USAF_Rifleman.et'
$otherMan = Find-Candidate $noMatchChar 'Char_RHS_USAF_Sniper.et'
Assert ($reserveMan.FallbackType -eq 'rifleman') 'An unmatched character role falls back to the plain rifleman.'
Assert ($reserveMan.Compatibility -eq 'unknown' -and $reserveMan.MatchLevel -eq 'low') 'A reserve character stays unknown and low confidence.'
Assert ($reserveMan.MatchLabel -match $reserveWord) 'A reserve character gets a user-facing reserve label.'
Assert (@($reserveMan.Warnings | Where-Object { $_ -match $reserveWord }).Count -gt 0) 'A reserve character explains why the fallback was used.'
Assert ([string]::IsNullOrEmpty([string]$otherMan.FallbackType)) 'Only the rifleman is a reserve; another role offered for an unknown role is not.'
foreach ($candidate in $ranked) {
    Assert ($candidate.Score -isnot [string] -and $candidate.Score -is [ValueType]) 'Scores are JSON-compatible numbers rather than formatted strings.'
    Assert ($candidate.Reasons -is [array] -and $candidate.Warnings -is [array]) 'Explanation fields remain arrays at every cardinality.'
    Assert (-not [string]::IsNullOrWhiteSpace($candidate.MatchLabel)) 'Every correspondence level has a user-facing label.'
    Assert ($candidate.Ref -eq ('{' + $candidate.Guid + '}' + $candidate.Path)) 'Candidate references retain their GUID and normalized resource path.'
}
$serialized = ConvertTo-Json -InputObject $ranked -Depth 10 | ConvertFrom-Json
Assert ($serialized.Count -eq $ranked.Count -and $serialized[0].Score -isnot [string]) 'Public JSON preserves flat objects and numeric score types.'

# Exclusion rules prevent unsafe cross-kind and known cross-side suggestions.
$mixedIndex = New-Index @($riflePath,
    'Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Char_RHS_AFRF_Rifleman.et',
    'Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_RifleSquad.et',
    'Prefabs/Vehicles/Wheeled/BLUFOR/RHS_USAF/Car.et')
$mixed = @(Rank-Candidates -BrokenPath $brokenRifle -ModIndex $mixedIndex -Top 20)
Assert ($mixed.Count -eq 1 -and $mixed[0].Path -eq $riflePath) 'Different prefab kinds and opposing known sides are excluded.'
$leaderRanked = @(Rank-Candidates -BrokenPath 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/drg_Role_SL.et' -ModIndex (New-Index @($mgPath,'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_RHS_USAF_SquadLeader.et')) -Top 20)
Assert ($leaderRanked[0].Path.EndsWith('SquadLeader.et') -and $leaderRanked[0].Compatibility -eq 'compatible') 'Alias equivalence affects actual ranking, not just feature extraction.'
$sapperRanked = @(Rank-Candidates -BrokenPath 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/drg_ScoutSapper.et' -ModIndex (New-Index @('Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_ScoutRifleman.et','Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_Recon_Sapper.et')) -Top 20)
Assert ($sapperRanked[0].Path.EndsWith('Sapper.et') -and $sapperRanked[0].Compatibility -eq 'compatible') 'ScoutSapper chooses a sapper with recon specialty rather than a scout rifleman.'
$groupRanked = @(Rank-Candidates -BrokenPath 'Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_FireTeam.et' -ModIndex (New-Index @('Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_RifleSquad_Base.et','Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_PL_Base.et')) -Top 20)
Assert ($groupRanked.Count -eq 2) 'Scale mismatches remain explicit manual alternatives.'
foreach ($candidate in $groupRanked) {
    Assert ($candidate.MatchLevel -eq 'low' -and $candidate.Warnings.Count -gt 0) 'Team to squad or platoon is a low correspondence with an explicit warning.'
}

# The plain rifle squad is the reserve default for a fire team. It is reported as
# "unknown" rather than "approximate" on purpose: the scale still does not match and the
# operator has to confirm the substitution. The platoon keeps "approximate" because it is
# a worse, purely scale-driven manual choice rather than the default.
$reserveGroup = Find-Candidate $groupRanked 'RifleSquad_Base.et'
$platoon = Find-Candidate $groupRanked 'PL_Base.et'
Assert ($reserveGroup.FallbackType -eq 'rifle_group') 'The plain rifle squad is flagged as the reserve group.'
Assert ($reserveGroup.Compatibility -eq 'unknown') 'A reserve group is unknown, never presented as an approximate match.'
Assert ($reserveGroup.MatchLabel -match $reserveWord) 'A reserve group gets a user-facing reserve label.'
Assert (@($reserveGroup.Warnings | Where-Object { $_ -match $reserveWord }).Count -gt 0) 'A reserve group explains why the fallback was used.'
Assert ([string]::IsNullOrEmpty([string]$platoon.FallbackType) -and $platoon.Compatibility -eq 'approximate') 'A platoon stays an approximate scale mismatch rather than a reserve.'
$unknownGroupRanked = @(Rank-Candidates -BrokenPath 'Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_CustomSquad_Base.et' -ModIndex (New-Index @('Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_OtherSquad_Base.et')))
Assert ($unknownGroupRanked[0].Compatibility -eq 'unknown' -and $unknownGroupRanked[0].MatchLevel -eq 'low' -and $unknownGroupRanked[0].Warnings.Count -gt 0) 'Scale alone cannot fabricate confidence in groups with unknown roles.'
$missingGroupRole = @(Rank-Candidates -BrokenPath 'Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_RifleSquad_Base.et' -ModIndex (New-Index @('Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_OtherSquad_Base.et')))
Assert ($missingGroupRole[0].MatchLevel -eq 'low') 'A candidate with an unknown group role remains low despite matching scale.'
$scenarioRanked = @(Rank-Candidates -BrokenPath 'Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_RifleSquad.et' -ModIndex (New-Index @('Prefabs/Groups/BLUFOR/RHS_USAF/dim_RHS_USAF_RifleSquad_Attack.et','Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_RifleSquad_Base.et')) -Top 20)
Assert ($scenarioRanked[0].Path.EndsWith('RifleSquad_Base.et') -and $scenarioRanked[0].Compatibility -eq 'compatible') 'Reusable groups rank ahead of equivalent-looking scripted formations.'
$scenarioFallback = Find-Candidate $scenarioRanked 'RifleSquad_Attack.et'
Assert ($scenarioFallback.Compatibility -eq 'approximate' -and $scenarioFallback.MatchLevel -eq 'low') 'Scenario groups remain manual fallbacks for ordinary formations.'
Assert (-not (Get-RoleTokens 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_Rifleman_OPT.et').Scenario) 'A character optimization suffix does not mean scripted group.'
$vehicleRanked = @(Rank-Candidates -BrokenPath 'Prefabs/Vehicles/Wheeled/APC/OPFOR/RHS_AFRF/BTR70/drg_BTR70.et' -ModIndex (New-Index @('Prefabs/Vehicles/Tanks/OPFOR/RHS_AFRF/T72/RHS_T72.et','Prefabs/Vehicles/Wheeled/APC/OPFOR/RHS_AFRF/BTR80/RHS_BTR80.et','Prefabs/Vehicles/Wheeled/APC/OPFOR/RHS_AFRF/BTR70/RHS_BTR70.et')) -Top 20)
Assert ($vehicleRanked[0].Path.EndsWith('RHS_BTR70.et') -and $vehicleRanked[0].Compatibility -eq 'compatible') 'Vehicle selection prefers the same model within a compatible class.'
$tankFallback = Find-Candidate $vehicleRanked 'RHS_T72.et'
Assert ($tankFallback.Compatibility -eq 'approximate' -and $tankFallback.MatchLevel -eq 'low') 'An APC to tank substitution remains a low manual fallback.'

# Identical evidence yields deterministic order, independent of hashtable enumeration.
$tieA = 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_Rifleman_A.et'
$tieB = 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_Rifleman_B.et'
$orderOne = @{'AAAAAAAAAAAAAAAA'=$tieA;'BBBBBBBBBBBBBBBB'=$tieB}
$orderTwo = @{'BBBBBBBBBBBBBBBB'=$tieB;'AAAAAAAAAAAAAAAA'=$tieA}
$refsOne = @((Rank-Candidates -BrokenPath $brokenRifle -ModIndex $orderOne -Top 20) | ForEach-Object {$_.Ref})
$refsTwo = @((Rank-Candidates -BrokenPath $brokenRifle -ModIndex $orderTwo -Top 20) | ForEach-Object {$_.Ref})
Assert (($refsOne -join '|') -eq ($refsTwo -join '|')) 'Tie sorting does not depend on dictionary insertion order.'
$originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
    $localized = @(Rank-Candidates -BrokenPath $brokenRifle -ModIndex $orderOne -Top 20)
    $roundTrip = ConvertTo-Json -InputObject $localized -Depth 10 | ConvertFrom-Json
    Assert ($roundTrip[0].Score -isnot [string]) 'Locale changes do not stringify score values or break JSON.'
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture }

# All catalog IO below is synthetic: no user catalog or remap file is opened.
$script:fixtureCatalog = 'C:\RankingFixture\synthetic-new.json'
$script:fixtureFiles = @{}
$script:fixtureMtimes = @{}
$script:fixtureReads = 0
$script:fixtureWrites = New-Object System.Collections.Generic.List[string]
$script:fixtureIndex = @{}
$script:fixtureRefreshes = 0
function Test-Path {
    [CmdletBinding()] param($LiteralPath,$Path,$PathType)
    if (-not $LiteralPath) { $LiteralPath = $Path }
    return $script:fixtureFiles.ContainsKey($LiteralPath)
}
function Get-Item {
    [CmdletBinding()] param($LiteralPath,[switch]$Force)
    if (-not $script:fixtureFiles.ContainsKey($LiteralPath)) { throw "Missing fixture: $LiteralPath" }
    return [pscustomobject]@{FullName=$LiteralPath;Length=$script:fixtureFiles[$LiteralPath].Length;LastWriteTimeUtc=$script:fixtureMtimes[$LiteralPath];PSIsContainer=$false}
}
function Read-Text([string]$Path) {
    if ([IO.Path]::GetFileName($Path) -in @('catalog_new_prefabs.json','catalog_old_prefabs.json','remap_table.json')) { throw 'Forbidden production data access.' }
    if (-not $script:fixtureFiles.ContainsKey($Path)) { throw "Missing fixture file: $Path" }
    $script:fixtureReads++
    return $script:fixtureFiles[$Path]
}
function Write-Text([string]$Path,[string]$Text) {
    if ([IO.Path]::GetFileName($Path) -in @('catalog_new_prefabs.json','catalog_old_prefabs.json','remap_table.json')) { throw 'Forbidden production data write.' }
    $script:fixtureFiles[$Path] = $Text
    $script:fixtureMtimes[$Path] = [DateTime]::UtcNow.AddSeconds($script:fixtureWrites.Count + 1)
    $script:fixtureWrites.Add($Path)
}
function Build-ModIndex { [CmdletBinding()] param([switch]$Refresh) if ($Refresh) {$script:fixtureRefreshes++}; return $script:fixtureIndex }
function Load-RemapTable { return [pscustomobject]@{Map=@{}} }
function Set-FixtureCatalog([object[]]$Items) {
    $script:fixtureFiles[$script:fixtureCatalog] = ConvertTo-Json -InputObject $Items -Depth 12
    $previous = $script:fixtureMtimes[$script:fixtureCatalog]
    $script:fixtureMtimes[$script:fixtureCatalog] = if ($previous) {$previous.AddSeconds(1)} else {[DateTime]::UtcNow}
}
Set-RMConfig @{CatalogNew=$script:fixtureCatalog;IndexCache='C:\RankingFixture\synthetic-index.tsv';PrefabsModRoot='C:\RankingFixture\Mod'} | Out-Null
Set-FixtureCatalog @([pscustomobject]@{guid='AAAAAAAAAAAAAAAA';path=$riflePath;fullRef=('{AAAAAAAAAAAAAAAA}' + $riflePath);name='Char_RHS_USAF_Rifleman.et';category='Characters';faction='BLUFOR';subCategory='RHS_USAF'})
$legacyCatalog = Get-NewPrefabsCatalog -Path $script:fixtureCatalog
Assert ($legacyCatalog -is [array] -and $legacyCatalog.Count -eq 1 -and $legacyCatalog[0] -isnot [array]) 'Legacy catalog reads retain a flat array.'
Assert ($legacyCatalog[0].matchingFeatures.FeatureVersion -eq 2 -and $legacyCatalog[0].matchingFeatures.Role -eq 'rifleman') 'Legacy catalog entries receive derived version 2 features at runtime.'
Assert ($script:fixtureWrites.Count -eq 0) 'Reading a legacy catalog does not rewrite it.'
$catalogIndex = Get-NewCatalogModIndex -Path $script:fixtureCatalog
$catalogFeatures = Get-NewCatalogCandidateFeatures -Path $script:fixtureCatalog
Assert ($catalogIndex -is [hashtable] -and $catalogIndex['AAAAAAAAAAAAAAAA'] -eq $riflePath) 'Catalog index remains a GUID to path map.'
Assert ($catalogFeatures -is [hashtable] -and $catalogFeatures['AAAAAAAAAAAAAAAA'].Role -eq 'rifleman') 'Catalog matching features expose a separate GUID map.'
$readsBefore = $script:fixtureReads
$cachedCatalog = Get-NewPrefabsCatalog -Path $script:fixtureCatalog
Assert ($script:fixtureReads -eq $readsBefore) 'Unchanged catalog metadata reuses the prepared snapshot.'
Set-FixtureCatalog @([pscustomobject]@{guid='AAAAAAAAAAAAAAAA';path=($riflePath -replace 'Rifleman','Radioman');fullRef=('{AAAAAAAAAAAAAAAA}' + ($riflePath -replace 'Rifleman','Radioman'));name='Char_RHS_USAF_Radioman.et';category='Characters';faction='BLUFOR';subCategory='RHS_USAF'})
$sameLengthFeatures = Get-NewCatalogCandidateFeatures -Path $script:fixtureCatalog
Assert ($sameLengthFeatures['AAAAAAAAAAAAAAAA'].Role -eq 'radioman') 'Timestamp changes invalidate a same-length catalog snapshot.'
$sameStamp = $script:fixtureMtimes[$script:fixtureCatalog]
Set-FixtureCatalog @([pscustomobject]@{guid='AAAAAAAAAAAAAAAA';path=$medicPath;fullRef=('{AAAAAAAAAAAAAAAA}' + $medicPath)})
$script:fixtureMtimes[$script:fixtureCatalog] = $sameStamp
$newLengthFeatures = Get-NewCatalogCandidateFeatures -Path $script:fixtureCatalog
Assert ($newLengthFeatures['AAAAAAAAAAAAAAAA'].Role -eq 'medic') 'Length changes invalidate a snapshot even if its timestamp is unchanged.'
Set-FixtureCatalog @([pscustomobject]@{guid='AAAAAAAAAAAAAAAA';path=$mgPath;fullRef=('{AAAAAAAAAAAAAAAA}' + $mgPath)})
$changedFeatures = Get-NewCatalogCandidateFeatures -Path $script:fixtureCatalog
Assert ($changedFeatures['AAAAAAAAAAAAAAAA'].Role -eq 'machinegunner') 'Changed catalog length or timestamp invalidates cached features.'
Assert ($script:fixtureReads -gt $readsBefore) 'Changed catalog metadata reloads the snapshot.'
$script:fixtureIndex = @{'BBBBBBBBBBBBBBBB'=$riflePath;'CCCCCCCCCCCCCCCC'='Prefabs/Groups/BLUFOR/RHS_USAF/Group_RHS_USAF_RifleSquad_Base.et';'DDDDDDDDDDDDDDDD'='Prefabs/Objects/Box.et'}
$rebuilt = Build-NewPrefabsCatalog -Path $script:fixtureCatalog -Refresh
Assert ($script:fixtureRefreshes -eq 1) 'Explicit catalog refresh refreshes the source metadata index.'
Assert ($rebuilt.Count -eq 2) 'Catalog rebuild includes supported prefab kinds only.'
Assert ($script:fixtureWrites.Count -eq 1 -and $script:fixtureWrites[0] -eq $script:fixtureCatalog) 'Catalog rebuild persists the synthetic snapshot once.'
$persisted = $script:fixtureFiles[$script:fixtureCatalog] | ConvertFrom-Json
Assert (@($persisted | Where-Object {$_.matchingFeatures.FeatureVersion -eq 2}).Count -eq 2) 'Rebuilt catalog persists prepared matching features.'
$afterRefresh = Get-NewCatalogCandidateFeatures -Path $script:fixtureCatalog
Assert ($afterRefresh.ContainsKey('BBBBBBBBBBBBBBBB') -and -not $afterRefresh.ContainsKey('AAAAAAAAAAAAAAAA')) 'Rebuild removes obsolete candidates from the feature cache.'
$withPrepared = @(Rank-Candidates -BrokenPath $brokenRifle -ModIndex (Get-NewCatalogModIndex -Path $script:fixtureCatalog) -CandidateFeatures $afterRefresh -Top 20)
Assert ($withPrepared.Count -eq 1 -and $withPrepared[0].Compatibility -eq 'compatible') 'Prepared catalog features participate in actual ranking.'

# The AI sees a wider but family-balanced pool; approximate substitutions are manual.
$poolCandidates = @()
foreach ($family in @('Rifleman','Medic','MachineGunner')) {
    for ($i = 1; $i -le 8; $i++) {
        $path = 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_' + $family + '_' + $i + '.et'
        $guid = ($poolCandidates.Count + 1).ToString('X16')
        $poolCandidates += [pscustomobject]@{Ref=('{' + $guid + '}' + $path);Guid=$guid;Path=$path;Score=(100 - $poolCandidates.Count);Compatibility='compatible';MatchLevel='high';MatchLabel='high';Reasons=@('fixture');Warnings=@();Warn=''}
    }
}
$poolCandidates += [pscustomobject]@{Ref='{FFFFFFFFFFFFFFFF}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_Officer.et';Guid='FFFFFFFFFFFFFFFF';Path='Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Char_Officer.et';Score=999;Compatibility='approximate';MatchLevel='low';MatchLabel='low';Reasons=@();Warnings=@('wrong role');Warn='wrong role'}
$pool = @(Get-AICandidatePool -Candidates $poolCandidates -Top 20 -PerFamily 2)
Assert ($pool.Count -le 20 -and $pool.Count -ge 3) 'AI candidate pool has a bounded useful selection.'
Assert (@($pool | Where-Object {$_.Compatibility -eq 'approximate'}).Count -eq 0) 'Approximate matches are excluded from the AI shortlist.'
foreach ($family in @('Rifleman','Medic','MachineGunner')) {
    $familyCount = @($pool | Where-Object {$_.Path -match ('Char_' + $family + '_')}).Count
    Assert ($familyCount -gt 0 -and $familyCount -le 2) 'The AI shortlist limits duplicate family variants and retains different families.'
}
$largePool = @()
for ($i = 0; $i -lt 25; $i++) {
    $path = 'Prefabs/Characters/Factions/BLUFOR/Fixture' + $i + '/Char_Rifleman.et'
    $guid = (100 + $i).ToString('X16')
    $largePool += [pscustomobject]@{Ref=('{' + $guid + '}' + $path);Guid=$guid;Path=$path;Family=('fixture-family-' + $i);Score=(100 - $i);Compatibility='compatible';MatchLevel='medium';MatchLabel='medium';Reasons=@();Warnings=@();Warn=''}
}
$widerPool = @(Get-AICandidatePool -Candidates $largePool -Top 20 -PerFamily 2)
Assert ($widerPool.Count -eq 20) 'The AI shortlist can use twenty distinct families instead of the former eight.'

# Mock the network and a dedicated process-only key to exercise safe response handling.
$script:aiBody = ''
$script:aiReply = ''
$script:aiCalls = 0
function Invoke-AnthropicJson { [CmdletBinding()] param($Uri,$BodyJson,$ApiKey) $script:aiBody=$BodyJson; $script:aiCalls++; return [pscustomobject]@{content=@([pscustomobject]@{type='text';text=$script:aiReply})} }
$keyName = 'PODVAL_RANKING_TEST_KEY'
$previousKey = [Environment]::GetEnvironmentVariable($keyName,'Process')
[Environment]::SetEnvironmentVariable($keyName,'synthetic-regression-key','Process')
try {
    $compatible = $ranked[0]
    $script:aiReply = '{"status":"no_match","ref":"","confidence":0,"reason":"No reliable equivalent."}'
    $noMatch = Invoke-AISuggest -BrokenRef ('{ABCDEF1234567890}' + $brokenRifle) -Candidates @($compatible) -ApiKeyEnv $keyName
    Assert ([string]::IsNullOrWhiteSpace($noMatch.Ref) -and $noMatch.Status -eq 'no_match') 'An explicit AI no_match is a normal result with no prefab assignment.'
    Assert ($script:aiCalls -eq 1) 'AI tests call only the mocked network transport.'
    $promptBody = $script:aiBody | ConvertFrom-Json
    Assert ($promptBody.system -match 'no_match') 'AI instructions explicitly allow refusal to recommend a replacement.'
    Assert ($promptBody.messages[0].content -match '(?i)compatib' -and $promptBody.messages[0].content -match '(?i)rifleman') 'AI receives structured compatibility and role evidence.'
    $script:aiReply = '{"status":"match","ref":"{EEEEEEEEEEEEEEEE}Prefabs/Characters/Invented.et","confidence":1,"reason":"Invented."}'
    Assert-Throws { Invoke-AISuggest -BrokenRef ('{ABCDEF1234567890}' + $brokenRifle) -Candidates @($compatible) -ApiKeyEnv $keyName } 'AI references outside the provided shortlist are rejected.'
    $script:aiReply = ConvertTo-Json -InputObject @{status='match';ref=$wrongRole.Ref;confidence=1;reason='Wrong role.'} -Compress
    Assert-Throws { Invoke-AISuggest -BrokenRef ('{ABCDEF1234567890}' + $brokenRifle) -Candidates @($wrongRole) -ApiKeyEnv $keyName } 'AI cannot promote an approximate role mismatch to a recommended match.'
    $script:aiReply = ConvertTo-Json -InputObject @{status='match';ref=$unknown.Ref;confidence=1;reason='Unknown role.'} -Compress
    $uncertain = Invoke-AISuggest -BrokenRef ('{ABCDEF1234567890}' + $brokenRifle) -Candidates @($unknown) -ApiKeyEnv $keyName
    Assert ($uncertain.Ref -eq $unknown.Ref -and $uncertain.Status -eq 'uncertain') 'Unknown compatibility stays uncertain even if AI claims a match.'
    $script:aiReply = ConvertTo-Json -InputObject @{status='match';ref=$compatible.Ref;confidence='0,9';reason='Matching role.'} -Compress
    $accepted = Invoke-AISuggest -BrokenRef ('{ABCDEF1234567890}' + $brokenRifle) -Candidates @($compatible) -ApiKeyEnv $keyName
    Assert ($accepted.Ref -eq $compatible.Ref -and $accepted.Confidence -ge 0 -and $accepted.Confidence -le 1) 'A known compatible AI recommendation remains within confidence bounds.'
    Assert ([Math]::Abs($accepted.Confidence - 0.9) -lt 0.00001) 'Decimal-comma AI confidence is parsed as 0.9 rather than thousands or a clamp.'
} finally { [Environment]::SetEnvironmentVariable($keyName,$previousKey,'Process') }
Write-Output ("PASS: {0} assertions; ranking, catalog and AI data IO mocked." -f $script:assertions)
