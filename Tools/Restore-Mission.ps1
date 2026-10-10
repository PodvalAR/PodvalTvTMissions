#requires -Version 5.1
<#
.SYNOPSIS
    Restore a legacy PodvalTvT mission (DRG-mod era) into the current addon by
    remapping only the prefab references that are actually broken.

.DESCRIPTION
    A prefab reference looks like  {16-HEX-GUID}Path/To/Prefab.et  inside .layer files.
    The Enfusion engine resolves prefabs by GUID, not by the path string, so a DRG
    prefab that was merely renamed (same GUID) still works and must be left alone.

    Strategy (file-only, no Workbench):
      1. Build an "alive GUID" index from already-restored mission trees. Any GUID
         referenced there is treated as still valid.
      2. Copy the source mission folder into the destination.
      3. In the copied .layer files, replace ONLY references whose GUID is listed in
         the remap table (the known-removed DRG prefabs). References whose GUID is in
         the alive index are kept verbatim.
      4. Fix the resource path inside <mission>.ent.meta to the new location.
      5. Print a report: replacements made + any remaining DRG reference that is
         neither alive nor mapped (needs manual attention).

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
    [string[]]$AliveRoots,
    [string]$AddonRoot = 'C:\Users\armen\Documents\GitHub\PodvalTvTMissions\PodvalTvTMissions',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
# Matches a full prefab reference: {GUID}path.et  (captures GUID + path)
$refRx  = '\{([0-9A-Fa-f]{16})\}([^"]+?\.et)'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Read-Text([string]$p)  { [System.IO.File]::ReadAllText($p) }
function Write-Text([string]$p, [string]$t) { [System.IO.File]::WriteAllText($p, $t, $utf8NoBom) }

# ---------------------------------------------------------------- alive index
if (-not $AliveRoots) {
    $AliveRoots = @('RamboKZ','sean','TEVAK','Vanya') |
        ForEach-Object { Join-Path $AddonRoot (Join-Path 'Worlds' $_) }
}
Write-Host 'Building alive-GUID index...' -ForegroundColor Cyan
$alive = @{}
foreach ($r in $AliveRoots) {
    if (-not (Test-Path -LiteralPath $r)) { Write-Host "  (skip, not found) $r" -ForegroundColor DarkYellow; continue }
    Get-ChildItem -LiteralPath $r -Recurse -File -Include *.layer,*.ent -ErrorAction SilentlyContinue | ForEach-Object {
        $t = Read-Text $_.FullName
        foreach ($m in [regex]::Matches($t, $refRx)) { $alive[$m.Groups[1].Value.ToUpper()] = $true }
    }
}
Write-Host ("  alive GUIDs: {0}" -f $alive.Count)

# ---------------------------------------------------------------- remap table
# Keys and values are FULL refs:  {16HEXGUID}Path/To/Prefab.et
# A stub entry (empty value, or value that is not a valid ref) is SKIPPED so that
# unfilled placeholders never blank out a reference.
$map = [ordered]@{}
$stubCount = 0
$refShape = '^\{[0-9A-Fa-f]{16}\}.+\.et$'

# The table is nested for readability (Category > Faction > FactionKey > Type).
# Walk it recursively: any property whose NAME is a full ref is an entry; any
# property whose value is another object is a grouping node to descend into.
# _meta and group names are ignored because their names are not refs.
$entries = [ordered]@{}
function Collect-Entries($node) {
    foreach ($p in $node.PSObject.Properties) {
        if ($p.Value -is [string]) {
            if ($p.Name -match $refShape) { $script:entries[$p.Name] = [string]$p.Value }
        }
        elseif ($p.Value -is [psobject] -or $p.Value.PSObject.Properties.Count) {
            Collect-Entries $p.Value
        }
    }
}
if (Test-Path -LiteralPath $RemapTable) {
    $json = Read-Text $RemapTable | ConvertFrom-Json
    Collect-Entries $json
    foreach ($k in $entries.Keys) {
        if ($entries[$k] -match $refShape) { $map[$k] = $entries[$k] } else { $stubCount++ }
    }
}
# GUIDs with a FILLED replacement (stubs are intentionally excluded so they still
# surface in the unresolved report until a value is provided)
$mappedGuids = @{}
foreach ($k in $map.Keys) { if ($k -match '^\{([0-9A-Fa-f]{16})\}') { $mappedGuids[$Matches[1].ToUpper()] = $true } }
Write-Host ("  remap entries (filled): {0}   stubs skipped (need value): {1}" -f $map.Count, $stubCount)

# ---------------------------------------------------------------- copy mission
$missionName = Split-Path $SourceMission -Leaf
$destMission = Join-Path $DestDir $missionName
if (Test-Path -LiteralPath $destMission) {
    if (-not $Force) { throw "Destination already exists: $destMission  (re-run with -Force to overwrite)" }
    Remove-Item -LiteralPath $destMission -Recurse -Force
}
New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
Copy-Item -LiteralPath $SourceMission -Destination $destMission -Recurse -Force
Write-Host ("Copied mission -> {0}" -f $destMission) -ForegroundColor Green

# ---------------------------------------------------------------- apply remap
$replacements = [ordered]@{}      # oldRef -> count
$layerFiles = Get-ChildItem -LiteralPath $destMission -Recurse -File -Include *.layer
foreach ($f in $layerFiles) {
    $text = Read-Text $f.FullName
    $changed = $false
    foreach ($old in $map.Keys) {
        $newRef = $map[$old]
        # literal, case-sensitive full-string replacement of the old ref
        $n = ([regex]::Matches($text, [regex]::Escape($old))).Count
        if ($n -gt 0) {
            $text = $text.Replace($old, $newRef)
            if (-not $replacements.Contains($old)) { $replacements[$old] = 0 }
            $replacements[$old] += $n
            $changed = $true
        }
    }
    if ($changed) { Write-Text $f.FullName $text }
}

# ---------------------------------------------------------------- fix .ent.meta
$metaFile = Get-ChildItem -LiteralPath $destMission -Filter *.ent.meta | Select-Object -First 1
if ($metaFile) {
    $meta = Read-Text $metaFile.FullName
    $rel  = $destMission.Substring($AddonRoot.Length).TrimStart('\','/').Replace('\','/')
    $newResourcePath = "$rel/$missionName.ent"
    # Rebuild the resource path inside:  Name "{GUID}<path>"
    $meta = [regex]::Replace($meta, '(Name\s+"\{[0-9A-Fa-f]{16}\})[^"]+(")', { param($mm) $mm.Groups[1].Value + $newResourcePath + $mm.Groups[2].Value })
    Write-Text $metaFile.FullName $meta
    Write-Host ("Updated .ent.meta resource path -> {0}" -f $newResourcePath) -ForegroundColor Green
}

# ---------------------------------------------------------------- report
Write-Host ''
Write-Host '================ REPORT ================' -ForegroundColor Cyan
Write-Host ("Mission : {0}" -f $missionName)
Write-Host ("Dest    : {0}" -f $destMission)
Write-Host ''
Write-Host ("Remapped references ({0}):" -f $replacements.Count) -ForegroundColor Green
if ($replacements.Count -eq 0) { Write-Host '  (none)' }
foreach ($k in $replacements.Keys) { Write-Host ("  {0} x{1}  ->  {2}" -f $k, $replacements[$k], $map[$k]) }

# Scan copied mission for any remaining DRG refs; classify alive vs still-broken
$destRefs = @{}
foreach ($f in (Get-ChildItem -LiteralPath $destMission -Recurse -File -Include *.layer,*.ent)) {
    $t = Read-Text $f.FullName
    foreach ($m in [regex]::Matches($t, $refRx)) { $destRefs[$m.Groups[1].Value.ToUpper()] = $m.Groups[2].Value }
}
$drgLeft    = $destRefs.GetEnumerator() | Where-Object { $_.Value -match '(?i)drg' }
$drgAlive   = @($drgLeft | Where-Object {  $alive.ContainsKey($_.Key) })
$drgBroken  = @($drgLeft | Where-Object { -not $alive.ContainsKey($_.Key) -and -not $mappedGuids.ContainsKey($_.Key) })

Write-Host ''
Write-Host ("DRG refs still present but ALIVE (ok, kept): {0}" -f $drgAlive.Count) -ForegroundColor DarkGray
Write-Host ''
if ($drgBroken.Count -gt 0) {
    Write-Host ("!! UNRESOLVED broken refs (not alive, not mapped): {0}" -f $drgBroken.Count) -ForegroundColor Red
    $drgBroken | Sort-Object Value | ForEach-Object { Write-Host ("   {{{0}}}{1}" -f $_.Key, $_.Value) -ForegroundColor Red }
    Write-Host '   -> add these to remap_table.json and re-run.' -ForegroundColor Red
} else {
    Write-Host 'OK: no unresolved broken DRG references remain.' -ForegroundColor Green
}
Write-Host '=======================================' -ForegroundColor Cyan
