#requires -Version 5.1
param([string]$ToolsRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $ToolsRoot 'Restore-Core.ps1')

$script:Assertions = 0
function Assert-Equal($actual, $expected, [string]$message) {
    $script:Assertions++
    if ($actual -cne $expected) {
        throw "${message}: expected '$expected', got '$actual'"
    }
}
function Assert-True([bool]$actual, [string]$message) {
    $script:Assertions++
    if (-not $actual) { throw $message }
}

# 1. Modular Core Architecture Verification
$coreFiles = @('Config.ps1', 'TableEngine.ps1', 'Ranker.ps1', 'ModIndex.ps1', 'RestoreEngine.ps1', 'AiClient.ps1')
foreach ($f in $coreFiles) {
    $full = Join-Path $ToolsRoot "Core\$f"
    Assert-True (Test-Path -LiteralPath $full) "Module Core\$f exists"
}

# 2. Get-RemapGroupPath tests
$gp1 = Get-RemapGroupPath '{1234567890ABCDEF}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role.et'
Assert-Equal ($gp1 -join '/') '_Unresolved_Pending/Characters/Factions/BLUFOR/RHS_USAF/USAF' 'Hierarchical group path for faction character'

$gp2 = Get-RemapGroupPath '{1234567890ABCDEF}Prefabs/Vehicles/Wheeled/BTR70/BTR70.et'
Assert-Equal ($gp2 -join '/') '_Unresolved_Pending/Vehicles/Wheeled/BTR70' 'Hierarchical group path for vehicle'

$gp3 = Get-RemapGroupPath '{1234567890ABCDEF}Sounds/Misc/Test.et'
Assert-Equal ($gp3 -join '/') '_Unresolved_Pending/Other' 'Non-prefab group path fallback'

# 3. Invoke-RemapAutoSuggest Mock Environment
$tempDir = Join-Path $env:TEMP ("podval_autosuggest_test_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    $testCatalogPath = Join-Path $tempDir 'catalog_new_prefabs.json'
    $testTablePath   = Join-Path $tempDir 'remap_table.json'
    $testOverridesPath = Join-Path $tempDir 'curated_overrides.json'

    # Synthetic catalog items
    $catalogItems = @(
        [pscustomobject]@{
            guid     = 'AAAAAAAAAAAAAAAA'
            path     = 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Rifle.et'
            fullRef  = '{AAAAAAAAAAAAAAAA}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Rifle.et'
            name     = 'Char_RHS_USAF_Regular_Rifle.et'
            category = 'Characters'
            faction  = 'BLUFOR'
            subCategory = 'RHS_USAF/Regular'
            mappedCount = 0
        },
        [pscustomobject]@{
            guid     = 'BBBBBBBBBBBBBBBB'
            path     = 'Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Medic.et'
            fullRef  = '{BBBBBBBBBBBBBBBB}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Medic.et'
            name     = 'Char_RHS_USAF_Regular_Medic.et'
            category = 'Characters'
            faction  = 'BLUFOR'
            subCategory = 'RHS_USAF/Regular'
            mappedCount = 0
        },
        [pscustomobject]@{
            guid     = 'CCCCCCCCCCCCCCCC'
            path     = 'Prefabs/Vehicles/Wheeled/BTR70/BTR70_New.et'
            fullRef  = '{CCCCCCCCCCCCCCCC}Prefabs/Vehicles/Wheeled/BTR70/BTR70_New.et'
            name     = 'BTR70_New.et'
            category = 'Vehicles'
            faction  = 'OPFOR'
            subCategory = 'Wheeled'
            mappedCount = 0
        }
    )
    Write-Text $testCatalogPath (ConvertTo-Json -InputObject $catalogItems -Depth 5)

    # Synthetic curated overrides
    $overridesObj = [pscustomobject]@{
        schema = 1
        overrides = [pscustomobject]@{
            '{1111111111111111}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Medic.et' = '{BBBBBBBBBBBBBBBB}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Medic.et'
            '{9999999999999999}Prefabs/Old_Missing.et' = '{0000000000000000}Prefabs/Not_In_Catalog.et'
        }
    }
    Write-Text $testOverridesPath (ConvertTo-Json -InputObject $overridesObj -Depth 5)

    # Synthetic initial remap table
    $initialTable = [pscustomobject]@{
        _meta = [pscustomobject]@{ description='test'; status='test' }
        _Unresolved_Pending = [pscustomobject]@{
            '{1111111111111111}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Medic.et' = ''
        }
    }
    Write-Text $testTablePath (ConvertTo-Json -InputObject $initialTable -Depth 5)

    # Test refs list:
    # 1. Curated override match ({111111...} -> {BBBBBB...})
    # 2. Same-GUID match ({CCCCCCCCCCCCCCCC}Prefabs/Old_Path_BTR70.et -> {CCCCCCCCCCCCCCCC}Prefabs/Vehicles/Wheeled/BTR70/BTR70_New.et)
    # 3. Ranked match ({2222222222222222}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Rifleman.et -> {AAAAAA...})
    # 4. Ignored ref ({3333333333333333}Prefabs/System/AIWorld.et)
    # 5. Stale override ({999999...}) -> unresolved
    $testRefs = @(
        '{1111111111111111}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Medic.et',
        '{CCCCCCCCCCCCCCCC}Prefabs/Old_Path_BTR70.et',
        '{2222222222222222}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Rifleman.et',
        '{3333333333333333}Prefabs/System/AIWorld.et',
        '{9999999999999999}Prefabs/Old_Missing.et'
    )

    $res = Invoke-RemapAutoSuggest -Refs $testRefs -RemapTable $testTablePath -OverridesPath $testOverridesPath -CatalogPath $testCatalogPath -Write

    Assert-Equal $res.Ignored 1 '1 system ref ignored'
    Assert-Equal $res.SkippedOverrides.Count 1 '1 stale override detected'
    Assert-Equal $res.SkippedOverrides[0].OldRef '{9999999999999999}Prefabs/Old_Missing.et' 'Stale override matches expected ref'
    
    # Check proposals
    $curatedProp = $res.Proposals | Where-Object { $_.Reason -eq 'curated-override' }
    Assert-True ($null -ne $curatedProp) 'Curated override proposed'
    Assert-Equal $curatedProp.NewRef '{BBBBBBBBBBBBBBBB}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Medic.et' 'Curated override target ref'

    $sameGuidProp = $res.Proposals | Where-Object { $_.Reason -eq 'same-guid' }
    Assert-True ($null -ne $sameGuidProp) 'Same-GUID proposed'
    Assert-Equal $sameGuidProp.NewRef '{CCCCCCCCCCCCCCCC}Prefabs/Vehicles/Wheeled/BTR70/BTR70_New.et' 'Same-guid target ref'

    $rankedProp = $res.Proposals | Where-Object { $_.OldRef -like '*drg_Role_RHS_USAF_Rifleman.et*' }
    Assert-True ($null -ne $rankedProp) 'Ranked candidate proposed for rifleman'
    Assert-Equal $rankedProp.NewRef '{AAAAAAAAAAAAAAAA}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Rifle.et' 'Ranked target ref'

    # Check written table
    Assert-True $res.Written 'Changes written'
    $loadedTable = Load-RemapTable -Path $testTablePath
    Assert-Equal $loadedTable.Map['{1111111111111111}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Medic.et'] '{BBBBBBBBBBBBBBBB}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Medic.et' 'Table updated with curated proposal'
    Assert-Equal $loadedTable.Map['{CCCCCCCCCCCCCCCC}Prefabs/Old_Path_BTR70.et'] '{CCCCCCCCCCCCCCCC}Prefabs/Vehicles/Wheeled/BTR70/BTR70_New.et' 'Table updated with same-guid proposal'
    Assert-Equal $loadedTable.Map['{2222222222222222}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Rifleman.et'] '{AAAAAAAAAAAAAAAA}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Rifle.et' 'Table updated with ranked proposal'
    Assert-True ($loadedTable.Stubs.Contains('{9999999999999999}Prefabs/Old_Missing.et')) 'Unresolved stale item declared as stub'

} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "PASS auto-suggest-regression: $script:Assertions assertions" -ForegroundColor Green
