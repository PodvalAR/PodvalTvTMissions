#requires -Version 5.1
<#
.SYNOPSIS
    Restore a legacy PodvalTvT (DRG-era) mission into the current addon by remapping
    only the prefab references that are actually broken.

.DESCRIPTION
    Thin CLI wrapper over Restore-Core.ps1 (all logic lives there, shared with the
    local web UI). Validation source of truth is the MOD PREFAB INDEX built from the
    PodvalTvTPrefabs *.et.meta files - NOT a self-referential scan of sibling missions.

    Machine-specific paths come from the local, git-ignored tool config
    (Tools\tool.config.json, or the legacy Tools\UI\ui.config.json). Command-line
    parameters override the config. Copy Tools\tool.config.example.json to
    Tools\tool.config.json and fill in PrefabsModRoot on first use.

.EXAMPLE
    .\Restore-Mission.ps1 `
        -SourceMission "D:\PodvalCommunityEvent\Worlds\Peroi\Arland\Bastovich_Arland" `
        -DestDir "D:\Work\PodvalTvTMissions\PodvalTvTMissions\Worlds\RamboKZ\Peroi" `
        -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceMission,
    [Parameter(Mandatory)][string]$DestDir,
    [string]$RemapTable,
    [string]$AddonRoot,
    [string]$PrefabsModRoot,
    [string]$ConfigPath,
    [switch]$RefreshIndex,
    [switch]$WriteStubs,
    [switch]$Normalize,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Restore-Core.ps1')

# Config first, explicit parameters last so they win.
$cfgImport = Import-RMUserConfig -Path $ConfigPath
foreach ($w in $cfgImport.Warnings) { Write-Host "config: $w" -ForegroundColor DarkYellow }
$overrides = @{}
foreach ($name in @('AddonRoot','PrefabsModRoot','RemapTable')) {
    if ($PSBoundParameters.ContainsKey($name) -and $PSBoundParameters[$name]) { $overrides[$name] = $PSBoundParameters[$name] }
}
if ($overrides.Count -gt 0) { Set-RMConfig $overrides | Out-Null }

$resolved = Get-RMConfig
if ($PSBoundParameters.ContainsKey('RemapTable') -or -not $resolved.RemapTable) {
    if (-not $resolved.RemapTable) { $resolved.RemapTable = (Join-Path $PSScriptRoot 'remap_table.json') }
}
if (-not $resolved.AddonRoot) {
    throw 'AddonRoot is not configured. Set it in the local tool config (Tools\tool.config.json).'
}
if (-not $resolved.PrefabsModRoot) {
    throw ("Prefab mod is not configured. Set PrefabsModRoot in {0}." -f $resolved.UserConfig)
}

Write-Host 'Building mod prefab index...' -ForegroundColor Cyan
$idx = Build-ModIndex -Refresh:$RefreshIndex
Write-Host ("  mod prefab GUIDs: {0}" -f $idx.Count)

$remap = Load-RemapTable -Path $resolved.RemapTable
Write-Host ("  remap entries (filled): {0}   stubs (need value): {1}" -f $remap.Map.Count, $remap.Stubs.Count)

$res = Invoke-Restore -SourceMission $SourceMission -DestDir $DestDir -RemapTable $resolved.RemapTable -AddonRoot $resolved.AddonRoot -Force:$Force
Write-Host ("Copied mission -> {0}" -f $res.DestMission) -ForegroundColor Green
if ($res.ResourcePath) { Write-Host ("Updated .ent.meta resource path -> {0}" -f $res.ResourcePath) -ForegroundColor Green }

Write-Host ''
Write-Host '================ REPORT ================' -ForegroundColor Cyan
Write-Host ("Mission : {0}" -f $res.Mission)
Write-Host ("Dest    : {0}" -f $res.DestMission)
Write-Host ''
Write-Host ("Remapped references ({0}):" -f $res.Replacements.Count) -ForegroundColor Green
if ($res.Replacements.Count -eq 0) { Write-Host '  (none)' }
foreach ($k in $res.Replacements.Keys) { Write-Host ("  {0} x{1}  ->  {2}" -f $k, $res.Replacements[$k], $remap.Map[$k]) }

Write-Host ''
Write-Host ("Resolved: {0}   Replaced source refs: {1}   Ignored(logic): {2}   External(base/other mods): {3}" -f $res.Resolved, $res.Replacements.Count, $res.Ignore, $res.External) -ForegroundColor DarkGray
Write-Host ''
if ($res.BrokenCount -gt 0) {
    Write-Host ("!! UNRESOLVED broken refs (not resolved in mod): {0}" -f $res.BrokenCount) -ForegroundColor Red
    $res.Broken | Sort-Object Path | ForEach-Object { Write-Host ("   {0}" -f $_.Ref) -ForegroundColor Red }
    if ($WriteStubs) {
        $stubs = Add-RemapStubs -Broken $res.Broken -RemapTable $resolved.RemapTable
        Write-Host ("   -> wrote {0} stub(s) to remap_table.json ({1}); fill them and re-run." -f $stubs.Added, '_Unresolved_Pending') -ForegroundColor Yellow
    } else {
        Write-Host '   -> add these to remap_table.json and re-run (or use -WriteStubs).' -ForegroundColor Red
    }
} else {
    Write-Host 'OK: no unresolved broken references remain.' -ForegroundColor Green
}

if ($Normalize) {
    $normScript = Join-Path $PSScriptRoot 'Normalize-MissionLayers.ps1'
    if (Test-Path -LiteralPath $normScript) {
        Write-Host ''
        Write-Host 'Running mission layers normalization...' -ForegroundColor Cyan
        & $normScript -MissionPath $res.DestMission
    }
}
Write-Host '=======================================' -ForegroundColor Cyan
