#requires -Version 5.1
<#
Regression for the machine-independent configuration layer.

Covers three things:
  1. no source file may hardcode a user profile / drive (the reason this layer exists);
  2. addon auto-detection works from the repository layout;
  3. the local, git-ignored config is loaded, validated and saved correctly, and a
     missing prefab mod degrades instead of throwing.
#>
[CmdletBinding()]
param([string]$ToolsRoot)

if (-not $ToolsRoot) { $ToolsRoot = Split-Path -Parent $PSScriptRoot }

$ErrorActionPreference = 'Stop'
. (Join-Path $ToolsRoot 'Restore-Core.ps1')

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

$repoRoot = Split-Path -Parent $ToolsRoot

# ---------------------------------------------------------------- 1. no hardcoded paths
# A committed path like C:\Users\<someone>\... silently breaks every other operator.
$scanned = @(
    (Join-Path $ToolsRoot 'Restore-Core.ps1'),
    (Join-Path $ToolsRoot 'Restore-Mission.ps1'),
    (Join-Path $ToolsRoot 'UI\Serve-RestoreUI.ps1'),
    (Join-Path $ToolsRoot 'UI\Start-RestoreUI.bat'),
    (Join-Path $ToolsRoot 'UI\ui.config.json'),
    (Join-Path $ToolsRoot 'tool.config.example.json'),
    (Join-Path $ToolsRoot 'MISSION_MIGRATION_GUIDE.md'),
    (Join-Path $ToolsRoot 'UI\index.html'),
    (Join-Path $ToolsRoot 'UI\editor.html')
) | Where-Object { Test-Path -LiteralPath $_ }

foreach ($file in $scanned) {
    $text = [System.IO.File]::ReadAllText($file)
    Assert ($text -notmatch '(?i)C:\\Users\\') ("No user-profile path in {0}" -f (Split-Path -Leaf $file))
    Assert ($text -notmatch '(?i)Desktop\\PodvalCommunityEvent') ("No Desktop source path in {0}" -f (Split-Path -Leaf $file))
}
# The local config and its backup must never be committed.
$gitignore = Join-Path $repoRoot '.gitignore'
Assert (Test-Path -LiteralPath $gitignore) 'Repository .gitignore exists.'
$ignoreText = [System.IO.File]::ReadAllText($gitignore)
$ignoreLines = @($ignoreText -split '\r?\n' | ForEach-Object { $_.Trim() })
Assert ($ignoreLines -contains 'Tools/tool.config.json') 'Local tool config is git-ignored.'
Assert ($ignoreLines -contains 'Tools/tool.config.json.bak') 'Local tool config backup is git-ignored.'
Assert ($ignoreLines -contains 'Tools/UI/ui.config.json') 'Legacy local config stays git-ignored.'

# ---------------------------------------------------------------- 2. addon auto-detection
$autoAddon = Get-RMAutoAddonRoot $repoRoot
Assert (-not [string]::IsNullOrWhiteSpace($autoAddon)) 'Addon root is auto-detected from the repository.'
Assert (Test-Path -LiteralPath (Join-Path $autoAddon 'addon.gproj')) 'Auto-detected addon root holds the .gproj file.'
Assert ([string]::IsNullOrWhiteSpace((Get-RMAutoAddonRoot (Join-Path $env:TEMP 'definitely-missing-repository')))) 'Missing repository yields no addon root.'
# Proof that detection follows the layout instead of a memorized location: a repository
# with a completely different name and folder layout must resolve to its own addon.
$syntheticRepo = Join-Path $env:TEMP ("podval-synthetic-repo-" + [guid]::NewGuid().ToString('N'))
$syntheticAddon = Join-Path $syntheticRepo 'SomeOtherAddonName'
$null = New-Item -ItemType Directory -Path $syntheticAddon -Force
Set-Content -LiteralPath (Join-Path $syntheticAddon 'addon.gproj') -Value '<Project/>' -Encoding UTF8
try {
    $syntheticDetected = Get-RMAutoAddonRoot $syntheticRepo
    Assert ($syntheticDetected -eq $syntheticAddon) 'Addon detection follows a differently named repository layout.'
} finally {
    Remove-Item -LiteralPath $syntheticRepo -Recurse -Force -ErrorAction SilentlyContinue
}
$default = Get-RMConfig
Assert ($default.PrefabsModRoot -eq '') 'Prefab mod root is empty by default and never hardcoded.'
Assert ($default.DefaultSourceRoot -eq '') 'Legacy source root is empty by default and never hardcoded.'
Assert ($default.RemapTable -eq (Join-Path $ToolsRoot 'remap_table.json')) 'Remap table defaults to the shipped file next to the tool.'

# ---------------------------------------------------------------- 3. value expansion
$env:PODVAL_TEST_ROOT = 'D:\Scoped'
try {
    Assert ((Expand-RMPathValue '%PODVAL_TEST_ROOT%\Addon') -eq 'D:\Scoped\Addon') 'Environment variables expand in stored paths.'
} finally {
    Remove-Item Env:\PODVAL_TEST_ROOT -ErrorAction SilentlyContinue
}
Assert ((Expand-RMPathValue '   ') -eq '') 'Blank path expands to an empty string.'
Assert ((Expand-RMPathValue '  D:\Scoped\Addon  ') -eq 'D:\Scoped\Addon') 'Stored paths are trimmed.'

# ---------------------------------------------------------------- 4. prefab mod degradation
Set-RMConfig @{ PrefabsModRoot='' } | Out-Null
$emptyIndex = Build-ModIndex
Assert ($null -eq $emptyIndex -or $emptyIndex.Count -eq 0) 'Missing prefab mod yields an empty index instead of throwing.'
$degraded = Get-RMEffectiveModIndex
Assert ($degraded.Source -in @('catalog','none')) 'Without the prefab mod the effective index falls back to the catalog snapshot.'
Assert ($degraded.Live -eq $false) 'Catalog fallback is reported as not live.'
Assert-Throws { Assert-RMModIndex $emptyIndex 'test operation' } 'Prefab-dependent operations refuse to run without the prefab mod.'
try { Assert-RMModIndex $emptyIndex 'test operation' } catch {
    Assert ($_.Exception.Message -match 'PrefabsModRoot') 'The refusal names the setting the operator must fill in.'
}

# ---------------------------------------------------------------- 5. path validation
$fixture = Join-Path $env:TEMP ("podval-config-regression-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture -Force
$addonFixture = Join-Path $fixture 'Addon'
$null = New-Item -ItemType Directory -Path $addonFixture -Force
Set-Content -LiteralPath (Join-Path $addonFixture 'addon.gproj') -Value '<Project/>' -Encoding UTF8
$plainFixture = Join-Path $fixture 'Plain'
$null = New-Item -ItemType Directory -Path $plainFixture -Force
try {
    Assert ($null -eq (Test-RMPathSetting 'addon' $addonFixture)) 'An addon directory containing a .gproj is accepted.'
    Assert ($null -eq (Test-RMPathSetting 'prefabs' $plainFixture)) 'A prefab directory only has to exist.'
    Assert ($null -eq (Test-RMPathSetting 'source' '')) 'An empty source root is allowed (optional setting).'
    Assert ($null -ne (Test-RMPathSetting 'addon' $plainFixture)) 'An addon directory without a .gproj is rejected.'
    Assert ($null -ne (Test-RMPathSetting 'addon' (Join-Path $fixture 'Missing'))) 'A missing addon directory is rejected.'
    Assert ($null -ne (Test-RMPathSetting 'prefabs' '')) 'A missing required prefab path is rejected.'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 6. import local config
$cfgFile = Join-Path $env:TEMP ("podval-tool-config-" + [guid]::NewGuid().ToString('N') + '.json')
$importFixture = Join-Path $env:TEMP ("podval-config-import-" + [guid]::NewGuid().ToString('N'))
$importAddon = Join-Path $importFixture 'Addon'
$importMod = Join-Path $importFixture 'PrefabsMod'
$null = New-Item -ItemType Directory -Path $importAddon -Force
$null = New-Item -ItemType Directory -Path $importMod -Force
Set-Content -LiteralPath (Join-Path $importAddon 'addon.gproj') -Value '<Project/>' -Encoding UTF8
try {
    Set-RMConfig @{ AddonRoot=''; PrefabsModRoot=''; DefaultSourceRoot='' } | Out-Null

    # Missing file: reported, never fatal, and the tool keeps its built-in defaults.
    $missing = Import-RMUserConfig -Path $cfgFile
    Assert ($missing.Exists -eq $false) 'A missing local config is reported as absent.'
    Assert ($missing.Warnings.Count -gt 0) 'A missing local config produces an explanatory warning.'

    $json = @{
        AddonRoot          = $importAddon
        PrefabsModRoot     = $importMod
        DefaultSourceRoot  = ''
        DefaultDestDir     = $importMod
        UnknownSetting     = 'ignored'
        ApiKeyEnv          = 'PODVAL_TEST_KEY_ENV'
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($cfgFile, $json, [System.Text.UTF8Encoding]::new($false))

    $imported = Import-RMUserConfig -Path $cfgFile
    Assert ($imported.Exists) 'The local config is loaded.'
    Assert ($imported.Applied['AddonRoot'] -eq $importAddon) 'Stored addon root is applied.'
    Assert ($imported.Applied['PrefabsModRoot'] -eq $importMod) 'Stored prefab mod root is applied.'
    Assert ($imported.Applied['ApiKeyEnv'] -eq 'PODVAL_TEST_KEY_ENV') 'Stored AI key environment variable name is applied.'
    Assert (-not $imported.Applied.ContainsKey('UnknownSetting')) 'An unknown key never becomes configuration.'
    Assert (($imported.Warnings -join ' ') -match 'UnknownSetting') 'An unknown key is reported instead of silently ignored.'
    # An empty stored value means "not configured" and must not erase the default.
    Assert ([string]$imported.Applied['DefaultSourceRoot'] -eq '') 'An empty stored value leaves the setting unset.'

    # The usage report path is machine-owned: setting it in the config must be refused
    # with its own explanation, not with a generic "unknown key" complaint. Both messages
    # are Cyrillic, which Windows PowerShell 5.1 cannot read from a BOM-less UTF-8 file,
    # so the check compares the two texts instead of matching their wording.
    $withMachine = @{ RemapTable = 'C:\ignored\remap.json'; LegacyReport = 'C:\ignored\report.json' } | ConvertTo-Json
    [System.IO.File]::WriteAllText($cfgFile, $withMachine, [System.Text.UTF8Encoding]::new($false))
    $machineImport = Import-RMUserConfig -Path $cfgFile
    Assert (-not $machineImport.Applied.ContainsKey('LegacyReport')) 'A machine-owned path never becomes configuration.'
    Assert (($machineImport.Warnings -join ' ') -match 'LegacyReport') 'A machine-owned path is named in the warning.'
    $withoutMachine = @{ RemapTable = 'C:\ignored\remap.json' } | ConvertTo-Json
    [System.IO.File]::WriteAllText($cfgFile, $withoutMachine, [System.Text.UTF8Encoding]::new($false))
    $plainImport = Import-RMUserConfig -Path $cfgFile
    Assert ($plainImport.Warnings.Count -eq 0) 'A config without machine-owned keys produces no warning.'
    Assert ($machineImport.Warnings.Count -eq 1) 'The machine-owned key is reported exactly once.'

    # A stored path that no longer exists is dropped with a warning instead of throwing.
    Set-RMConfig @{ PrefabsModRoot='' } | Out-Null
    $stale = @{ AddonRoot = $importAddon; PrefabsModRoot = (Join-Path $importFixture 'Gone') } | ConvertTo-Json
    [System.IO.File]::WriteAllText($cfgFile, $stale, [System.Text.UTF8Encoding]::new($false))
    $reimported = Import-RMUserConfig -Path $cfgFile
    Assert ($null -eq $reimported.Applied['PrefabsModRoot']) 'A stale prefab mod path is dropped.'
    Assert ($reimported.Applied['AddonRoot'] -eq $importAddon) 'A stale entry does not discard the valid ones.'
    Assert (($reimported.Warnings -join ' ') -match 'PrefabsModRoot') 'A stale entry is reported to the operator.'

    # Malformed JSON must fail loudly rather than half-loading.
    [System.IO.File]::WriteAllText($cfgFile, '{ not json', [System.Text.UTF8Encoding]::new($false))
    Assert-Throws { Import-RMUserConfig -Path $cfgFile } 'A malformed local config is rejected.'
} finally {
    Remove-Item -LiteralPath $cfgFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $importFixture -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 7. save local config
$cfgFile2 = Join-Path $env:TEMP ("podval-tool-config-" + [guid]::NewGuid().ToString('N') + '.json')
$fixture2 = Join-Path $env:TEMP ("podval-config-regression-" + [guid]::NewGuid().ToString('N'))
$addon2 = Join-Path $fixture2 'Addon'
$null = New-Item -ItemType Directory -Path $addon2 -Force
Set-Content -LiteralPath (Join-Path $addon2 'addon.gproj') -Value '<Project/>' -Encoding UTF8
try {
    $saved = Save-RMUserConfig -Path $cfgFile2 -Values @{ AddonRoot=$addon2; PrefabsModRoot=$addon2; AiModel='test-model' }
    Assert ($saved.ok) 'Valid settings are saved.'
    Assert (Test-Path -LiteralPath $cfgFile2) 'The local config file is created.'
    $roundTrip = Get-Content -LiteralPath $cfgFile2 -Raw | ConvertFrom-Json
    Assert ($roundTrip.AddonRoot -eq $addon2) 'Saved addon root round-trips through JSON.'
    Assert ($roundTrip.AiModel -eq 'test-model') 'Saved AI model round-trips through JSON.'

    # Saving again keeps unrelated keys and produces a backup.
    [System.IO.File]::WriteAllText($cfgFile2, '{"Port":8787}', [System.Text.UTF8Encoding]::new($false))
    $saved2 = Save-RMUserConfig -Path $cfgFile2 -Values @{ PrefabsModRoot=$addon2 }
    Assert ($saved2.backupFile) 'Overwriting the local config writes a backup first.'
    $roundTrip2 = Get-Content -LiteralPath $cfgFile2 -Raw | ConvertFrom-Json
    Assert ($roundTrip2.Port -eq 8787) 'Saving preserves keys it does not manage.'

    # An invalid path must be rejected as a whole, so no broken config is ever stored.
    Assert-Throws { Save-RMUserConfig -Path $cfgFile2 -Values @{ PrefabsModRoot=(Join-Path $fixture2 'Nope') } } 'Saving rejects a non-existent prefab mod path.'
    $afterReject = Get-Content -LiteralPath $cfgFile2 -Raw | ConvertFrom-Json
    Assert ($afterReject.PrefabsModRoot -eq $addon2) 'A rejected save leaves the previous configuration intact.'
} finally {
    Remove-Item -LiteralPath $cfgFile2 -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$cfgFile2.bak" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixture2 -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 8. configuration state
Set-RMConfig @{ AddonRoot=''; PrefabsModRoot='' } | Out-Null
$state = Get-RMConfigurationState
Assert ($state.Configured -eq $false) 'An unconfigured tool reports itself as not configured.'
Assert (($state.Missing -contains 'AddonRoot') -and ($state.Missing -contains 'PrefabsModRoot')) 'The missing settings are listed by name.'
Set-RMConfig @{ AddonRoot=$addon2; PrefabsModRoot=$addon2 } | Out-Null
$readyState = Get-RMConfigurationState
Assert ($readyState.Configured -eq $true) 'A fully configured tool reports itself as configured.'

# ---------------------------------------------------------------- 9. shipped example
$example = Join-Path $ToolsRoot 'tool.config.example.json'
Assert (Test-Path -LiteralPath $example) 'A tracked example config is shipped.'
$exampleText = [System.IO.File]::ReadAllText($example)
Assert ($exampleText -notmatch '(?i)C:\\Users\\') 'The example config contains no real user paths.'
$null = $exampleText | ConvertFrom-Json
Assert $true 'The example config is valid JSON.'

Write-Host ("PASS config regressions ({0} assertions)" -f $script:assertions)