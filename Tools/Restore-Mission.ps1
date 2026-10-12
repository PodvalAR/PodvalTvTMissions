#requires -Version 5.1
<#
.SYNOPSIS
    Restore a legacy PodvalTvT (DRG-era) mission into the current addon by remapping
    only the prefab references that are actually broken.

.DESCRIPTION
    Thin CLI wrapper over Restore-Core.ps1 (all logic lives there, shared with the
    local web UI). Validation source of truth is the MOD PREFAB INDEX built from the
    PodvalTvTPrefabs *.et.meta files - NOT a self-referential scan of sibling missions.

.EXAMPLE
    .\Restore-Mission.ps1 `
        -SourceMission "C:\Users\armen\Desktop\PodvalCommunityEvent\Worlds\Peroi\Arland\Bastovich_Arland" `
        -DestDir "C:\Users\armen\Documents\GitHub\PodvalTvTMissions\PodvalTvTMissions\Worlds\RamboKZ\Peroi" `
        -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceMission,
    [Parameter(Mandatory)][string]$DestDir,
    [string]$RemapTable = (Join-Path $PSScriptRoot 'remap_table.json'),
    [string]$AddonRoot  = 'C:\Users\armen\Documents\GitHub\PodvalTvTMissions\PodvalTvTMissions',
    [string]$PrefabsModRoot,
    [switch]$RefreshIndex,
    [switch]$WriteStubs,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Restore-Core.ps1')

$cfg = @{ AddonRoot = $AddonRoot; RemapTable = $RemapTable }
if ($PrefabsModRoot) { $cfg.PrefabsModRoot = $PrefabsModRoot }
Set-RMConfig $cfg | Out-Null

Write-Host 'Building mod prefab index...' -ForegroundColor Cyan
$idx = Build-ModIndex -Refresh:$RefreshIndex
Write-Host ("  mod prefab GUIDs: {0}" -f $idx.Count)

$remap = Load-RemapTable -Path $RemapTable
Write-Host ("  remap entries (filled): {0}   stubs (need value): {1}" -f $remap.Map.Count, $remap.Stubs.Count)

$res = Invoke-Restore -SourceMission $SourceMission -DestDir $DestDir -RemapTable $RemapTable -AddonRoot $AddonRoot -Force:$Force
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
        $stubEntries = @{}
        foreach ($b in $res.Broken) {
            if (-not $remap.Map.Contains($b.Ref) -and -not $remap.Stubs.Contains($b.Ref)) { $stubEntries[$b.Ref] = '' }
        }
        $w = Set-RemapEntries -Entries $stubEntries -Path $RemapTable
        Write-Host ("   -> wrote {0} stub(s) to remap_table.json ({1}); fill them and re-run." -f $w.Added, '_Unresolved_Pending') -ForegroundColor Yellow
    } else {
        Write-Host '   -> add these to remap_table.json and re-run (or use -WriteStubs).' -ForegroundColor Red
    }
} else {
    Write-Host 'OK: no unresolved broken references remain.' -ForegroundColor Green
}
Write-Host '=======================================' -ForegroundColor Cyan
