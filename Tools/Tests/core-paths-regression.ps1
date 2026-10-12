#requires -Version 5.1
[CmdletBinding()]
param([string]$FixtureParent = [IO.Path]::GetTempPath(), [switch]$RequireJunction)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Restore-Core.ps1')
$fixtureBase = [IO.Path]::GetFullPath($FixtureParent).TrimEnd('\')
$fixtureName = 'restore-tools-' + [guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $fixtureBase $fixtureName
$aliasPath = Join-Path $fixtureRoot 'Alias'
$innerLink = Join-Path $fixtureRoot 'Addon\Mission\LinkedMod'
$assertions = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:assertions++
}
function Assert-Fails([scriptblock]$Action, [string]$Expected) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert ($message -like "*$Expected*") "Expected failure containing '$Expected'; received '$message'."
}
function Remove-FixtureLink([string]$Link) {
    $absolute = [IO.Path]::GetFullPath($Link)
    if (-not $absolute.StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe junction cleanup target.' }
    if (Test-Path -LiteralPath $absolute) {
        Assert ([bool]((Get-Item -LiteralPath $absolute -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Cleanup only removes a junction.'
        [IO.Directory]::Delete($absolute)
    }
}
try {
    $addon = Join-Path $fixtureRoot 'Addon'
    $source = Join-Path $addon 'Mission'
    $destDir = Join-Path $addon 'Worlds'
    $dest = Join-Path $destDir 'Mission'
    $mod = Join-Path $fixtureRoot 'Mod'
    foreach ($directory in @($source, $dest, $mod)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $old = '{AAAAAAAAAAAAAAAA}Prefabs/drg_Old.et'
    $target = '{BBBBBBBBBBBBBBBB}Prefabs/New.et'
    $missing = '{DDDDDDDDDDDDDDDD}Prefabs/drg_Missing.et'
    $table = Join-Path $fixtureRoot 'fixture.json'
    Write-Text $table (ConvertTo-Json -InputObject ([pscustomobject]@{ Group=[pscustomobject]@{ $old=$target } }))
    Write-Text (Join-Path $mod 'Target.et.meta') ('Name "' + $target + '"')
    Write-Text (Join-Path $source 'Mission.ent') ('Prefab "' + $old.ToLowerInvariant() + '"')
    Write-Text (Join-Path $source 'Objects.layer') ('Prefab "' + $old + '" Live "{BBBBBBBBBBBBBBBB}Prefabs/StillLive.et" Missing "' + $missing + '"')
    Write-Text (Join-Path $source 'Mission.ent.meta') 'Name "{1111111111111111}Worlds/Old/Mission.ent"'
    Write-Text (Join-Path $dest 'sentinel.txt') 'keep until successful restore'
    Set-RMConfig @{ AddonRoot=$addon; PrefabsModRoot=$mod; RemapTable=$table; IndexCache=(Join-Path $fixtureRoot 'index'); CatalogNew=(Join-Path $fixtureRoot 'fixture-new.json'); CatalogOld=(Join-Path $fixtureRoot 'fixture-old.json') } | Out-Null

    Assert-Fails { Invoke-Restore -SourceMission (Join-Path $fixtureRoot 'Missing') -DestDir $destDir -Force } 'Source mission directory not found'
    Assert (Test-Path -LiteralPath (Join-Path $dest 'sentinel.txt')) 'Missing source preserves destination.'
    Assert-Fails { Invoke-Restore -SourceMission ($source.ToUpperInvariant() + '\.') -DestDir $addon -Force } 'overlap'
    Assert (Test-Path -LiteralPath (Join-Path $source 'Mission.ent')) 'Case and dot alias cannot delete source.'
    $hasJunction = $false
    try {
        New-Item -ItemType Junction -Path $aliasPath -Target $addon | Out-Null
        $hasJunction = $true
    } catch {
        $cause = $_.Exception.GetBaseException()
        if ($RequireJunction -or ($cause -isnot [UnauthorizedAccessException] -and ($cause -isnot [ComponentModel.Win32Exception] -or $cause.NativeErrorCode -ne 5))) { throw }
        Write-Warning 'SKIP native junction cases: this environment denies junction creation. Mocked alias checks still run in core-regression.ps1.'
    }
    if ($hasJunction) {
        Assert ([string]::Equals((Get-RMCanonicalPath $aliasPath), (Get-RMCanonicalPath $addon), [StringComparison]::OrdinalIgnoreCase)) 'Native canonicalizer resolves junction alias.'
        Assert-Fails { Invoke-Restore -SourceMission $source -DestDir $aliasPath -Force } 'overlap'
        Assert (Test-Path -LiteralPath (Join-Path $source 'Mission.ent')) 'Junction overlap preserves source.'
        New-Item -ItemType Junction -Path $innerLink -Target $mod | Out-Null
        Assert-Fails { Invoke-Restore -SourceMission $source -DestDir $destDir -Force } 'Reparse points'
        Assert (Test-Path -LiteralPath (Join-Path $dest 'sentinel.txt')) 'Nested junction preflight preserves destination.'
        Remove-FixtureLink $innerLink
    }

    $result = Invoke-Restore -SourceMission $source -DestDir $destDir -Force
    Assert ((Read-Text (Join-Path $dest 'Mission.ent')).Contains($target)) 'Real ent IO remaps lowercase GUID.'
    Assert ((Read-Text (Join-Path $dest 'Objects.layer')).Contains($target)) 'Real layer IO remaps GUID.'
    Assert ((Read-Text (Join-Path $dest 'Objects.layer')).Contains('{BBBBBBBBBBBBBBBB}Prefabs/StillLive.et')) 'Live GUID remains unchanged.'
    Assert ((Read-Text (Join-Path $source 'Mission.ent')).Contains($old.ToLowerInvariant())) 'Source content remains unchanged.'
    Assert ($result.Replacements[$old] -eq 2 -and $result.BrokenCount -eq 1 -and $result.Mapped -eq 0) 'Real restore counts replacements and remaining broken refs.'
    Assert ($result.ResourcePath -eq 'Worlds/Mission/Mission.ent') 'Metadata resource path uses canonical addon boundary.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $dest 'sentinel.txt'))) 'Force replaces destination after successful preflight.'
    Write-Output "PASS native filesystem integration: $assertions assertions; PowerShell $($PSVersionTable.PSVersion)"
} finally {
    Remove-FixtureLink $innerLink
    Remove-FixtureLink $aliasPath
    $absoluteRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path $fixtureBase $fixtureName))
    if (-not [string]::Equals($absoluteRoot, $expectedRoot, [StringComparison]::OrdinalIgnoreCase) -or -not $absoluteRoot.StartsWith($fixtureBase + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup target.' }
    if (Test-Path -LiteralPath $absoluteRoot) { Remove-Item -LiteralPath $absoluteRoot -Recurse -Force }
}
