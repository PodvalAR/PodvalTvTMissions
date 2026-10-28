#requires -Version 5.1
<#
.SYNOPSIS
    Sweep a tree of legacy PodvalTvT (DRG-era) missions and declare broken prefab
    references in the remap table as stubs or automatic replacement proposals.

.DESCRIPTION
    The remap table is the single source of truth for "what replaces what". This sweep is
    how it learns about references it does not know yet: it scans every *.layer/*.ent
    under the legacy root, classifies each reference against the live prefab index, and
    appends the broken ones in remap_table.json.

    With -AutoSuggest, the sweep uses curated overrides (curated_overrides.json), same-GUID
    resolution, and semantic ranking to propose automatic replacements natively in PowerShell,
    completely eliminating the need for Python or generate_remap_table.py.

    Nothing already assigned is touched: refs that resolve in the mod, are already
    mapped, or are declared logic/system prefabs are never written. Running the sweep
    twice is therefore safe and idempotent.

    It is a DRY RUN by default. Pass -Write to persist stubs/proposals and the usage report;
    the usage report records how often and in which missions each reference occurs, and is
    the same data the editor's "Использование" tab displays.

    Machine-specific paths come from the local, git-ignored tool config
    (Tools\tool.config.json, or the legacy Tools\UI\ui.config.json). Command-line
    parameters override the config.

.EXAMPLE
    .\Scan-Legacy.ps1
    Preview what a sweep would declare without writing anything.

.EXAMPLE
    .\Scan-Legacy.ps1 -SourceRoot "D:\PodvalCommunityEvent\Worlds" -AutoSuggest
    Preview automatic replacement proposals and stubs via native PowerShell ranking.

.EXAMPLE
    .\Scan-Legacy.ps1 -SourceRoot "D:\PodvalCommunityEvent\Worlds" -AutoSuggest -Write
    Declare every broken reference found in that tree and populate automatic proposals.
#>
[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$RemapTable,
    [string]$PrefabsModRoot,
    [string]$ConfigPath,
    [string]$OverridesPath,
    [double]$MinScore = 20.0,
    [switch]$AutoSuggest,
    [switch]$Write,
    [switch]$NoReport
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Restore-Core.ps1')

# Config first, explicit parameters last so they win.
$cfgImport = Import-RMUserConfig -Path $ConfigPath
foreach ($w in $cfgImport.Warnings) { Write-Host "config: $w" -ForegroundColor DarkYellow }
$overrides = @{}
foreach ($name in @('RemapTable','PrefabsModRoot')) {
    if ($PSBoundParameters.ContainsKey($name) -and $PSBoundParameters[$name]) { $overrides[$name] = $PSBoundParameters[$name] }
}
if ($overrides.Count -gt 0) { Set-RMConfig $overrides | Out-Null }

$resolved = Get-RMConfig
if (-not $resolved.RemapTable) { $resolved.RemapTable = (Join-Path $PSScriptRoot 'remap_table.json') }
if (-not $resolved.PrefabsModRoot) {
    throw ("Prefab mod is not configured. Set PrefabsModRoot in {0}." -f $resolved.UserConfig)
}

$target = if ($PSBoundParameters.ContainsKey('SourceRoot') -and $SourceRoot) { $SourceRoot } else { $resolved.DefaultSourceRoot }
$mode = if ($Write) { 'WRITE' } else { 'DRY RUN (nothing will be written)' }
Write-Host ("Legacy sweep: {0}" -f $mode) -ForegroundColor Cyan
Write-Host ("  source root : {0}" -f $(if ($target) { $target } else { 'не задан' }))
Write-Host ("  remap table : {0}" -f $resolved.RemapTable)

if ($AutoSuggest) {
    # 1. Run sync to generate usage report if requested
    $res = Sync-LegacyRefsToRemapTable -SourceRoot $target -RemapTable $resolved.RemapTable -Write:$Write -NoReport:$NoReport
    
    # 2. Run native PowerShell auto-suggest engine
    $suggestRes = Invoke-RemapAutoSuggest -SourceRoot $target -RemapTable $resolved.RemapTable -OverridesPath $OverridesPath -MinScore $MinScore -Write:$Write

    Write-Host ''
    Write-Host '================ REPORT ================' -ForegroundColor Cyan
    Write-Host ("Missions : {0}   ({1})" -f @($res.Missions).Count, (($res.Missions | Select-Object -First 5) -join ', '))
    Write-Host ("References: {0}" -f $res.Total) -ForegroundColor Cyan
    Write-Host ("  resolved in mod : {0}" -f $res.Resolved) -ForegroundColor Green
    Write-Host ("  already mapped  : {0}" -f $res.Mapped) -ForegroundColor Green
    Write-Host ("  logic/ignored   : {0}" -f $res.Ignore) -ForegroundColor DarkGray
    Write-Host ("  external        : {0}" -f $res.External) -ForegroundColor DarkGray
    Write-Host ("  broken          : {0}" -f $res.Broken) -ForegroundColor Red
    Write-Host ''
    Write-Host '================ AUTO-SUGGEST ================' -ForegroundColor Cyan
    Write-Host ("Automatic proposals : {0}" -f $suggestRes.ProposedCount) -ForegroundColor Green
    Write-Host ("Unresolved stubs    : {0}" -f $suggestRes.UnresolvedCount) -ForegroundColor Yellow
    Write-Host ''

    if ($suggestRes.SkippedOverrides.Count -gt 0) {
        Write-Host 'Stale curated overrides (target missing from mod catalog):' -ForegroundColor DarkYellow
        foreach ($so in $suggestRes.SkippedOverrides) {
            Write-Host ("   {0} -> {1}" -f $so.OldRef, $so.Target) -ForegroundColor DarkYellow
        }
        Write-Host ''
    }

    if ($suggestRes.ProposedCount -gt 0) {
        Write-Host ("Proposals ({0}):" -f $suggestRes.ProposedCount) -ForegroundColor Green
        foreach ($prop in ($suggestRes.Proposals | Select-Object -First 30)) {
            Write-Host ("   [{0}] {1}`n        -> {2}" -f $prop.Reason, $prop.OldRef, $prop.NewRef) -ForegroundColor Yellow
        }
        if ($suggestRes.ProposedCount -gt 30) {
            Write-Host ("   ... and {0} more" -f ($suggestRes.ProposedCount - 30)) -ForegroundColor DarkGray
        }
        Write-Host ''
    }

    if (-not $Write) {
        Write-Host ('DRY RUN: nothing was written. Re-run with -Write to declare the proposals/stubs.') -ForegroundColor Yellow
        Write-Host ('=======================================' ) -ForegroundColor Cyan
        return
    }

    Write-Host ("Wrote {0} proposals and {1} stubs to {2}" -f $suggestRes.ProposedCount, $suggestRes.UnresolvedCount, $resolved.RemapTable) -ForegroundColor Green
    if ($res.ReportPath) { Write-Host ("Usage report: {0}" -f $res.ReportPath) -ForegroundColor Cyan }
    Write-Host '=======================================' -ForegroundColor Cyan
    return
}

$res = Sync-LegacyRefsToRemapTable -SourceRoot $target -RemapTable $resolved.RemapTable -Write:$Write -NoReport:$NoReport

Write-Host ''
Write-Host '================ REPORT ================' -ForegroundColor Cyan
Write-Host ("Missions : {0}   ({1})" -f @($res.Missions).Count, (($res.Missions | Select-Object -First 5) -join ', '))
Write-Host ("References: {0}" -f $res.Total) -ForegroundColor Cyan
Write-Host ("  resolved in mod : {0}" -f $res.Resolved) -ForegroundColor Green
Write-Host ("  already mapped  : {0}" -f $res.Mapped) -ForegroundColor Green
Write-Host ("  logic/ignored   : {0}" -f $res.Ignore) -ForegroundColor DarkGray
Write-Host ("  external        : {0}" -f $res.External) -ForegroundColor DarkGray
Write-Host ("  broken          : {0}" -f $res.Broken) -ForegroundColor Red
Write-Host ''

if (-not $Write) {
    Write-Host ('DRY RUN: nothing was written. Re-run with -Write to declare the stubs.') -ForegroundColor Yellow
    Write-Host ('=======================================') -ForegroundColor Cyan
    return
}

if ($res.Added -eq 0) {
    Write-Host 'No new stubs: every broken reference is already declared.' -ForegroundColor Green
} else {
    Write-Host ("Declared {0} new stub(s) in _Unresolved_Pending:" -f $res.Added) -ForegroundColor Yellow
    foreach ($ref in @($res.AddedRefs) | Sort-Object) { Write-Host ("   {0}" -f $ref) -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'Assign them in the editor (or directly in remap_table.json).' -ForegroundColor Yellow
}
if ($res.ReportPath) { Write-Host ("Usage report: {0}" -f $res.ReportPath) -ForegroundColor Cyan }
Write-Host '=======================================' -ForegroundColor Cyan
