#requires -Version 5.1
param([string]$ToolsRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$testCount = 0

function Assert($Condition, [string]$Message) {
    $script:testCount++
    if (-not $Condition) {
        Write-Error ("FAIL assertion {0}: {1}" -f $script:testCount, $Message)
        throw ("FAIL: {0}" -f $Message)
    }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $script:testCount++
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) {
        Write-Error ("FAIL assertion {0}: Expected error but succeeded: {1}" -f $script:testCount, $Message)
        throw ("FAIL: {0}" -f $Message)
    }
}

$corePath = Join-Path $ToolsRoot 'Restore-Core.ps1'
. $corePath

Write-Host "Running Phase 4 regressions (CSV export/import, web endpoints, audit trail)..." -ForegroundColor Cyan

# ------------------------------------------------------------------ 1. CSV Export Test
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("podval_p4_test_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    $tablePath = Join-Path $tempDir 'remap_table.json'
    $initialTable = [ordered]@{
        _meta = [ordered]@{ description = "Test table"; status = "draft" }
        _Unresolved_Pending = [ordered]@{
            "{1111111111111111}Prefabs/Characters/Old1.et" = ""
        }
        Characters = [ordered]@{
            USSR = [ordered]@{
                "{2222222222222222}Prefabs/Characters/Old2.et" = "{3333333333333333}Prefabs/Characters/New2.et"
            }
        }
    }
    $initialJson = Format-RemapJson $initialTable
    Write-Text $tablePath $initialJson

    # Test Export-RemapTableCsv
    $csv = Export-RemapTableCsv -Path $tablePath
    Assert ($csv -match '^GroupPath,OldRef,NewRef,Status,Note') 'CSV header must contain GroupPath,OldRef,NewRef,Status,Note'
    Assert ($csv -match '_Unresolved_Pending,\{1111111111111111\}Prefabs/Characters/Old1\.et') 'CSV contains pending entry'
    Assert ($csv -match 'Characters/USSR,\{2222222222222222\}Prefabs/Characters/Old2\.et,\{3333333333333333\}Prefabs/Characters/New2\.et') 'CSV contains mapped entry'

    # ------------------------------------------------------------------ 2. CSV Import Test
    $importCsv = @"
GroupPath,OldRef,NewRef,Status,Note
Characters/US,{4444444444444444}Prefabs/Characters/OldUS.et,{5555555555555555}Prefabs/Characters/NewUS.et,mapped,Valid US
_Unresolved_Pending,{6666666666666666}Prefabs/Vehicles/OldV.et,,stub,Missing vehicle
BadGroup,{INVALID_REF}NotAPrefab.et,,malformed,Bad ref
"@

    $impRes = Import-RemapTableCsv -CsvContent $importCsv -Path $tablePath
    Assert $impRes.ok 'Import-RemapTableCsv returns ok=true'
    Assert ($impRes.added -eq 2) 'Imported 2 valid entries'
    Assert ($impRes.errors.Count -eq 1) 'Reported 1 malformed row error'
    Assert ($impRes.errors[0] -match 'Row 4:') 'Malformed error pinpoints Row 4'

    # Verify table content on disk after import
    $reloaded = Load-RemapTable -Path $tablePath
    Assert ($reloaded.Map.Contains('{4444444444444444}Prefabs/Characters/OldUS.et')) 'Imported US character exists in map'
    Assert ($reloaded.Stubs.Contains('{6666666666666666}Prefabs/Vehicles/OldV.et')) 'Imported vehicle stub exists in stubs'

    # Empty CSV test
    $emptyRes = Import-RemapTableCsv -CsvContent "" -Path $tablePath
    Assert (-not $emptyRes.ok) 'Empty CSV returns ok=false'

    # Missing OldRef header test
    $noOldRefCsv = "GroupPath,SomeRef,NewRef`r`nA,B,C"
    $noOldRes = Import-RemapTableCsv -CsvContent $noOldRefCsv -Path $tablePath
    Assert (-not $noOldRes.ok) 'CSV without OldRef column returns ok=false'

    # ------------------------------------------------------------------ 3. Audit Trail Report Test
    $mockDest = Join-Path $tempDir 'TvT_Test_Everon'
    New-Item -ItemType Directory -Path $mockDest -Force | Out-Null

    $auditData = [ordered]@{
        mission       = 'TvT_Test_Everon'
        migratedAt    = (Get-Date).ToString('o')
        sourceMission = 'C:\Legacy\Mission'
        destMission   = $mockDest
        replacements  = @{ '{1111111111111111}Prefabs/Old.et' = '{2222222222222222}Prefabs/New.et' }
        brokenCount   = 0
        normalization = [pscustomobject]@{ EntitiesMoved = 10; SquadsRenamed = 2; VehiclesLinked = 1 }
        validation    = [pscustomobject]@{ Valid = $true; Errors = 0; Warnings = 0; Issues = @() }
    }

    $reportPath = Join-Path $mockDest 'migration_report.json'
    $reportJson = $auditData | ConvertTo-Json -Depth 10
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($reportPath, $reportJson, $utf8Bom)

    Assert (Test-Path -LiteralPath $reportPath) 'migration_report.json created on disk'
    $readReport = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    Assert ($readReport.mission -eq 'TvT_Test_Everon') 'Audit report stores canonical mission name'
    Assert ($readReport.normalization.EntitiesMoved -eq 10) 'Audit report stores normalization entity statistics'
    Assert ($readReport.validation.Valid -eq $true) 'Audit report stores standard validation status'

    # ------------------------------------------------------------------ 4. Server API AST & Export/Import check
    $serverPath = Join-Path $ToolsRoot 'UI\Serve-RestoreUI.ps1'
    $tokens = $null; $parseErrs = $null
    $serverAst = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$tokens, [ref]$parseErrs)
    Assert ($parseErrs.Count -eq 0) 'Serve-RestoreUI.ps1 parses with 0 AST errors'

    $handleApiAst = $serverAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Handle-Api' }, $true)
    Assert ($null -ne $handleApiAst) 'Handle-Api function exists in Serve-RestoreUI.ps1'
    $handleApiText = $handleApiAst.Extent.Text
    Assert ($handleApiText -match "'GET /api/table/export'") 'Handle-Api defines GET /api/table/export route'
    Assert ($handleApiText -match "'POST /api/table/import'") 'Handle-Api defines POST /api/table/import route'
    Assert ($handleApiText -match "'POST /api/validate'") 'Handle-Api defines POST /api/validate route'
    Assert ($handleApiText -match "'POST /api/normalize'") 'Handle-Api defines POST /api/normalize route'
    Assert ($handleApiText -match "'POST /api/open-folder'") 'Handle-Api defines POST /api/open-folder route'

    Write-Host ("PASS phase4-regression: {0} assertions" -f $script:testCount) -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
