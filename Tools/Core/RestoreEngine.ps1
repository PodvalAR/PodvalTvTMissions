#requires -Version 5.1
Set-StrictMode -Off

# ------------------------------------------------------------------ ref scan
# Collect unique {GUID}path refs from a mission folder's .layer/.ent files.
function Get-MissionRefs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MissionDir)

    if (-not (Test-Path -LiteralPath $MissionDir -PathType Container)) { throw "Mission directory not found: $MissionDir" }
    $refs = [ordered]@{}
    Get-ChildItem -LiteralPath $MissionDir -Recurse -File -Include *.layer,*.ent -ErrorAction Stop | ForEach-Object {
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
        [Parameter(Mandatory)]$Remap,          # object from Load-RemapTable
        [switch]$FinalValidation,
        $ReplacementIndex
    )
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $ReplacementIndex) { $ReplacementIndex = Get-RMReplacementIndex $Remap $ModIndex }
    foreach ($full in $Refs.Keys) {
        $r = $Refs[$full]
        $status = 'external'
        if ($ModIndex.ContainsKey($r.Guid)) {
            $status = 'resolved'
        }
        elseif (-not $FinalValidation -and $ReplacementIndex.ByGuid.ContainsKey($r.Guid)) {
            $status = 'mapped'
        }
        elseif ($r.Path -match $script:IgnoreRx -or $full -match $script:IgnoreRx) {
            $status = 'ignore'
        }
        elseif ($full -match $script:SuspectRx -or $ReplacementIndex.SourceGuids.ContainsKey($r.Guid)) {
            $status = 'broken'
        }
        $out.Add([pscustomobject]@{
            Ref=$r.Ref; Guid=$r.Guid; Path=$r.Path; Count=$r.Count; Status=$status
        })
    }
    return ,($out.ToArray())
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
    Assert-RMModIndex $modIndex 'scan mission'
    $remap    = Load-RemapTable -Path $RemapTable
    $refs     = Get-MissionRefs -MissionDir $MissionDir
    $classified = Classify-Refs -Refs $refs -ModIndex $modIndex -Remap $remap

    $broken = @($classified | Where-Object { $_.Status -eq 'broken' })
    $stubs = if ($WriteStubs) { Add-RemapStubs -Broken $broken -RemapTable $RemapTable }
             else { [pscustomobject]@{ Added=0; Updated=0; Refs=[string[]]@() } }

    return [pscustomobject]@{
        Mission    = (Split-Path $MissionDir -Leaf)
        Dir        = $MissionDir
        Total      = $classified.Count
        Resolved   = @($classified | Where-Object Status -eq 'resolved').Count
        Mapped     = @($classified | Where-Object Status -eq 'mapped').Count
        Ignore     = @($classified | Where-Object Status -eq 'ignore').Count
        External   = @($classified | Where-Object Status -eq 'external').Count
        Broken     = $broken.Count
        StubsAdded = $stubs.Added
        StubRefs   = [string[]]@($stubs.Refs)
        Refs       = [object[]]$classified
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
    $paths = Get-RMRestorePaths -SourceMission $SourceMission -DestDir $DestDir -AddonRoot $AddonRoot -Force:$Force
    $modIndex = Build-ModIndex
    Assert-RMModIndex $modIndex 'restore mission'
    $remap    = Load-RemapTable -Path $RemapTable
    $lookup   = Get-RMReplacementIndex $remap $modIndex
    # Read the source files before replacing an existing destination.
    $null = Get-MissionRefs -MissionDir $paths.Source

    $missionName = $paths.Name
    $destMission = $paths.Destination
    if (Test-Path -LiteralPath $destMission) {
        if (-not $Force) { throw "Destination already exists: $destMission (use -Force)" }
        Remove-Item -LiteralPath $destMission -Recurse -Force
    }
    New-Item -ItemType Directory -Path $paths.DestDir -Force | Out-Null
    Copy-Item -LiteralPath $paths.Source -Destination $destMission -Recurse -Force

    # Replace each original reference once; generated targets are never remapped again.
    $replacements = [ordered]@{}
    foreach ($f in (Get-ChildItem -LiteralPath $destMission -Recurse -File -Include *.layer,*.ent -ErrorAction Stop)) {
        $text = Read-Text $f.FullName
        $rewritten = [regex]::Replace($text, $script:RefRx, [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $guid = $match.Groups[1].Value.ToUpperInvariant()
            if ($modIndex.ContainsKey($guid) -or -not $lookup.ByGuid.ContainsKey($guid)) { return $match.Value }
            $entry = $lookup.ByGuid[$guid]
            if (-not $replacements.Contains($entry.OldRef)) { $replacements[$entry.OldRef] = 0 }
            $replacements[$entry.OldRef]++
            return $entry.NewRef
        })
        if ($rewritten -cne $text) { Write-Text $f.FullName $rewritten }
    }

    # fix .ent.meta resource path to new location
    $metaFile = Get-ChildItem -LiteralPath $destMission -Filter *.ent.meta | Select-Object -First 1
    $newResourcePath = $null
    if ($metaFile) {
        $meta = Read-Text $metaFile.FullName
        $rel  = $destMission.Substring($paths.AddonRoot.Length).TrimStart('\','/').Replace('\','/')
        $newResourcePath = "$rel/$missionName.ent"
        $meta = [regex]::Replace($meta, '(Name\s+"\{[0-9A-Fa-f]{16}\})[^"]+(")', { param($mm) $mm.Groups[1].Value + $newResourcePath + $mm.Groups[2].Value })
        Write-Text $metaFile.FullName $meta
    }

    # reclassify destination against the mod index
    $destRefs = Get-MissionRefs -MissionDir $destMission
    $classified = Classify-Refs -Refs $destRefs -ModIndex $modIndex -Remap $remap -ReplacementIndex $lookup -FinalValidation
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

