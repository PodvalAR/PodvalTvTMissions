#requires -Version 5.1
<#
.SYNOPSIS
    Shared core logic for restoring legacy PodvalTvT (DRG-era) missions into the
    current addon by remapping only the prefab references that are actually broken.

.DESCRIPTION
    Dot-source this file ( . .\Restore-Core.ps1 ) to get the functions below. It is
    used by BOTH the CLI wrapper (Restore-Mission.ps1) and the local web UI backend
    (UI\Serve-RestoreUI.ps1), so the matching/validation logic lives in exactly one
    place.

    Source of truth for "does this prefab exist" is the MOD PREFAB INDEX, built from
    the *.et.meta files of the PodvalTvTPrefabs addon (GUID -> path). This replaces the
    old self-referential "alive roots" scan, which could mask a restored mission's own
    broken refs when that mission lived under one of the alive roots.

    Reference shape inside .layer/.ent files:  {16-HEX-GUID}Path/To/Prefab.et
    The engine resolves by GUID, so a merely-renamed prefab (same GUID) still works and
    must be left alone.
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ constants
$script:RefRx     = '\{([0-9A-Fa-f]{16})\}([^"]+?\.et)'
$script:RefShape  = '^\{[0-9A-Fa-f]{16}\}.+\.et$'
$script:MetaRefRx = 'Name\s+"\{([0-9A-Fa-f]{16})\}([^"]+?\.et)"'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# A ref whose path matches this "looks like it should ship inside the mod" and, if its
# GUID is not in the mod index and not remapped, is a genuine broken reference.
$script:SuspectRx = '(?i)(drg_|dim_|Char_A2F|Char_RHS|Role_Character|/Group_RHS|/Group_A2F|Ses_|Group_Ses|Group_NAPA|Group_FIA|DRG_)'

# Logic/system prefabs we deliberately DO NOT remap or stub (user rule: restore only
# infantry and some vehicles). Classified as "ignore".
$script:IgnoreRx  = '(?i)(/System/|MissionEndTimer|/Logic/|GameMode|/Modes/|Manager\.et$|Trigger|PerceptionManager|AIWorld)'

# ------------------------------------------------------------------ config
# Every path here is machine-specific, so nothing may hardcode a user profile or a
# drive. The addon root is auto-detected from the repository layout; the prefab mod
# root and the legacy source root stay EMPTY until the operator supplies them in a
# local, git-ignored config file (see the "user config" section below).
$script:RMToolsRoot = if ($script:RMToolsRoot) {
    $script:RMToolsRoot
} elseif ($PSScriptRoot) {
    if ((Split-Path -Leaf $PSScriptRoot) -ieq 'Core') { Split-Path -Parent $PSScriptRoot } else { $PSScriptRoot }
} else {
    (Get-Location).Path
}
$script:RMRepoRoot = Split-Path -Parent $script:RMToolsRoot

# The addon is the only directory in the repository that holds a .gproj file. Finding
# it keeps this portable even if the repository or addon folder is renamed.
function Get-RMAutoAddonRoot([string]$RepoRoot) {
    if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { return '' }
    $hits = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -Depth 2 -File -Filter *.gproj -ErrorAction SilentlyContinue |
              Select-Object -ExpandProperty DirectoryName -Unique)
    if ($hits.Count -eq 1) { return $hits[0] }
    $fallback = Join-Path $RepoRoot (Split-Path -Leaf $RepoRoot)
    if (Test-Path -LiteralPath $fallback -PathType Container) { return $fallback }
    return ''
}

$script:RMC = @{
    AddonRoot      = (Get-RMAutoAddonRoot $script:RMRepoRoot)
    PrefabsModRoot = ''
    RemapTable     = (Join-Path $script:RMToolsRoot 'remap_table.json')
    CatalogNew     = (Join-Path $script:RMToolsRoot 'catalog_new_prefabs.json')
    LegacyReport   = (Join-Path $script:RMToolsRoot 'legacy_refs_report.json')
    DefaultSourceRoot = ''
    DefaultDestDir    = ''
    IndexCache     = (Join-Path $env:TEMP 'podval_mod_index.tsv')
    UserConfig     = ''
}
# DefaultDestDir is derived from AddonRoot until the operator sets it explicitly.
$script:RMDestDirIsAuto = $true
if ($script:RMC.AddonRoot) { $script:RMC.DefaultDestDir = (Join-Path $script:RMC.AddonRoot 'Worlds') }

function Get-RMConfig { return $script:RMC }
function Set-RMConfig([hashtable]$Overrides) {
    if ($Overrides.ContainsKey('CatalogNew') -or $Overrides.ContainsKey('PrefabsModRoot')) {
        $script:NewCatalogCache = $null
        $script:NewFeatureCache = @{}
    }
    if ($Overrides.ContainsKey('PrefabsModRoot') -or $Overrides.ContainsKey('IndexCache')) {
        $script:ModIndexCache = @{}
        $script:ModIndexWarned = $false
        $script:ModIndexUnavailable = $false
    }
    if ($Overrides.ContainsKey('AddonRoot') -and $script:RMDestDirIsAuto -and -not $Overrides.ContainsKey('DefaultDestDir')) {
        $newAddon = [string]$Overrides['AddonRoot']
        if (-not [string]::IsNullOrWhiteSpace($newAddon)) { $Overrides['DefaultDestDir'] = (Join-Path $newAddon 'Worlds') }
    }
    foreach ($k in $Overrides.Keys) { $script:RMC[$k] = $Overrides[$k] }
    if ($Overrides.ContainsKey('DefaultDestDir')) { $script:RMDestDirIsAuto = $false }
    return $script:RMC
}

# ------------------------------------------------------------------ user config
# Machine-specific settings live in a local JSON file that is deliberately NOT tracked
# by git, so every operator keeps their own paths. The accepted keys are an explicit
# whitelist: a stray key in the file must never silently become configuration.
$script:RMPathKeys = @('AddonRoot','PrefabsModRoot','RemapTable','CatalogNew',
                       'DefaultSourceRoot','DefaultDestDir','IndexCache')
# Machine-owned output paths. They are derived from the repository layout, never read
# from the operator config, and therefore must not appear in the accepted key whitelist.
$script:RMMachineKeys = @('LegacyReport')
# 'Port' is written by the local web UI and consumed by UI\Serve-RestoreUI.ps1; the core
# only has to carry it through import/export without treating it as an unknown key.
$script:RMValueKeys = @('ApiKeyEnv','AiBaseUrl','AiModel','Port')

function Expand-RMPathValue([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $expanded = [System.Environment]::ExpandEnvironmentVariables($Value.Trim())
    if ($expanded.StartsWith('~')) { $expanded = Join-Path $HOME $expanded.Substring(1).TrimStart('\', '/') }
    return $expanded.Trim()
}

# Returns $null when the value is acceptable, otherwise a message explaining the problem.
function Test-RMPathSetting([string]$Kind, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($Kind -eq 'source') { return $null }   # optional: legacy missions may not be present yet
        return 'путь не задан'
    }
    if (-not (Test-Path -LiteralPath $Value -PathType Container)) { return "каталог не найден: $Value" }
    if ($Kind -eq 'addon') {
        $gproj = @(Get-ChildItem -LiteralPath $Value -File -Filter *.gproj -ErrorAction SilentlyContinue)
        if ($gproj.Count -eq 0) { return "в каталоге нет файла .gproj аддона: $Value" }
    }
    return $null
}

function Get-RMUserConfigPath([string]$ExplicitPath) {
    if ($ExplicitPath) { return (Get-RMAbsolutePath $ExplicitPath) }
    if ($script:RMC.UserConfig) { return (Get-RMAbsolutePath $script:RMC.UserConfig) }
    $preferred = Join-Path $script:RMToolsRoot 'tool.config.json'
    $legacy    = Join-Path $script:RMToolsRoot 'UI\ui.config.json'
    if (Test-Path -LiteralPath $preferred -PathType Leaf) { return (Get-RMAbsolutePath $preferred) }
    if (Test-Path -LiteralPath $legacy -PathType Leaf) { return (Get-RMAbsolutePath $legacy) }
    return (Get-RMAbsolutePath $preferred)
}

function Import-RMUserConfig {
    [CmdletBinding()]
    param([string]$Path)

    $resolved = Get-RMUserConfigPath $Path
    $script:RMC.UserConfig = $resolved
    $warnings = New-Object System.Collections.Generic.List[string]
    $applied  = @{}
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        $warnings.Add("Файл локальных настроек не найден: $resolved")
        return [pscustomobject]@{ Path=$resolved; Exists=$false; Applied=$applied; Warnings=@($warnings) }
    }

    try { $fileCfg = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json }
    catch { throw "Не удалось прочитать файл настроек $resolved : $($_.Exception.Message)" }
    if ($null -eq $fileCfg) {
        $warnings.Add("Файл настроек пуст: $resolved")
        return [pscustomobject]@{ Path=$resolved; Exists=$false; Applied=$applied; Warnings=@($warnings) }
    }

    $set = @{}
    foreach ($p in $fileCfg.PSObject.Properties) {
        # Keys starting with "_" are treated as comments: the shipped example file is
        # self-documenting, so its annotations must not be reported as unknown settings.
        if ($p.Name.StartsWith('_')) { continue }
        if (($script:RMPathKeys + $script:RMValueKeys) -notcontains $p.Name) {
            # A machine-owned output path is not "unknown", it is just not configurable.
            # Saying so stops the operator from fighting a setting that cannot take effect.
            if ($script:RMMachineKeys -contains $p.Name) {
                $warnings.Add("Игнорируется машинный путь $($p.Name): он задаётся инструментом, а не настройками.")
            } else {
                $warnings.Add("Игнорируется неизвестный ключ настроек: $($p.Name)")
            }
            continue
        }
        $value = if ($script:RMPathKeys -contains $p.Name) { Expand-RMPathValue ([string]$p.Value) } else { ([string]$p.Value).Trim() }
        # An empty value means "not configured" and must never erase a usable default.
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $set[$p.Name] = $value
    }

    # A stored path that no longer exists (drive letter changed, repo moved) must not
    # break the rest of the tool: drop it and report, so the UI can ask for it again.
    foreach ($pair in @(@('AddonRoot','addon'), @('PrefabsModRoot','prefabs'), @('DefaultSourceRoot','source'))) {
        $key = $pair[0]
        if (-not $set.ContainsKey($key)) { continue }
        $problem = Test-RMPathSetting $pair[1] $set[$key]
        if ($problem) { $warnings.Add("$key : $problem"); $set.Remove($key) }
    }

    if ($set.Count -gt 0) {
        Set-RMConfig $set | Out-Null
        foreach ($k in $set.Keys) { $applied[$k] = $set[$k] }
    }
    return [pscustomobject]@{ Path=$resolved; Exists=$true; Applied=$applied; Warnings=@($warnings) }
}

function Save-RMUserConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [string]$Path
    )
    $resolved = Get-RMUserConfigPath $Path

    # Reject the whole save when a path is wrong, so the operator never ends up with a
    # stored configuration that cannot work.
    $rejected = New-Object System.Collections.Generic.List[string]
    foreach ($pair in @(@('AddonRoot','addon'), @('PrefabsModRoot','prefabs'), @('DefaultSourceRoot','source'))) {
        $key = $pair[0]
        if (-not $Values.ContainsKey($key)) { continue }
        $problem = Test-RMPathSetting $pair[1] (Expand-RMPathValue ([string]$Values[$key]))
        if ($problem) { $rejected.Add("$key : $problem") }
    }
    if ($rejected.Count -gt 0) { throw ("Настройки не сохранены: " + ($rejected -join '; ')) }

    $doc = [ordered]@{}
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        try { $existing = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json } catch { $existing = $null }
        if ($existing) { foreach ($p in $existing.PSObject.Properties) { $doc[$p.Name] = $p.Value } }
    }
    foreach ($k in $Values.Keys) {
        $v = $Values[$k]
        if ($null -eq $v) { $doc[$k] = '' }
        elseif ($script:RMPathKeys -contains $k) { $doc[$k] = Expand-RMPathValue ([string]$v) }
        else { $doc[$k] = ([string]$v).Trim() }
    }

    $dir = Split-Path -Parent $resolved
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $backup = ''
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        $backup = $resolved + '.bak'
        Copy-Item -LiteralPath $resolved -Destination $backup -Force
    }
    Write-Text $resolved (($doc | ConvertTo-Json -Depth 6) + "`n")
    $script:RMC.UserConfig = $resolved
    return [pscustomobject]@{ ok=$true; path=$resolved; backupFile=$backup }
}

# Which required paths are still unset. The UI turns this into a "configure me" banner.
function Get-RMConfigurationState {
    $missing = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($script:RMC.AddonRoot)) { $missing.Add('AddonRoot') }
    if ([string]::IsNullOrWhiteSpace($script:RMC.PrefabsModRoot)) { $missing.Add('PrefabsModRoot') }
    return [pscustomobject]@{ Configured=($missing.Count -eq 0); Missing=@($missing) }
}

# Prefab-dependent operations must fail with an actionable message instead of a stack
# trace when the prefab mod is not configured or not present on this machine.
function Assert-RMModIndex($Index, [string]$Operation) {
    if ($Index -and @($Index.Keys).Count -gt 0) { return }
    $root = [string]$script:RMC.PrefabsModRoot
    $shown = if ([string]::IsNullOrWhiteSpace($root)) { 'не задан' } else { $root }
    throw ("Префабы мода недоступны ($Operation): PrefabsModRoot = $shown. " +
           "Укажите его в локальном файле настроек $($script:RMC.UserConfig) и перезапустите инструмент.")
}

# ------------------------------------------------------------------ io helpers
function Read-Text([string]$Path)  { return [System.IO.File]::ReadAllText($Path) }
function Write-Text([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom) }

# Resolve physical directory ancestors as well as lexical "..", junction and 8.3 aliases.
function Get-RMAbsolutePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A filesystem path is required.' }
    $provider = $null; $drive = $null
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw "Not a filesystem path: $Path" }
    $full = [System.IO.Path]::GetFullPath($full)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd([char[]]'\/') }
    return $full
}

function Get-RMPhysicalDirectory([string]$Path) {
    if (-not ('PodvalRestore.NativePath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace PodvalRestore {
    public static class NativePath {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access,
            uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,
            StringBuilder path, uint size, uint flags);
        public static string Resolve(string name) {
            using (SafeFileHandle handle = CreateFileW(name, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                StringBuilder path = new StringBuilder(512);
                uint length = GetFinalPathNameByHandleW(handle, path, (uint)path.Capacity, 0);
                if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (length >= path.Capacity) {
                    path = new StringBuilder((int)length + 1);
                    length = GetFinalPathNameByHandleW(handle, path, (uint)path.Capacity, 0);
                    if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return path.ToString();
            }
        }
    }
}
'@
    }
    $final = [PodvalRestore.NativePath]::Resolve($Path)
    if ($final.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $final = '\\' + $final.Substring(8) }
    elseif ($final.StartsWith('\\?\', [StringComparison]::Ordinal)) { $final = $final.Substring(4) }
    return Get-RMAbsolutePath $final
}

function Get-RMCanonicalPath([string]$Path) {
    $cursor = Get-RMAbsolutePath $Path
    $missing = New-Object System.Collections.Generic.List[string]
    while (-not (Test-Path -LiteralPath $cursor)) {
        $missing.Add([System.IO.Path]::GetFileName($cursor))
        $parent = [System.IO.Path]::GetDirectoryName($cursor)
        if (-not $parent -or $parent -eq $cursor) { throw "No accessible directory ancestor: $Path" }
        $cursor = $parent
    }
    if (-not (Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).PSIsContainer) { throw "Not a directory: $cursor" }
    $canonical = Get-RMPhysicalDirectory $cursor
    for ($i = $missing.Count - 1; $i -ge 0; $i--) { $canonical = Join-Path $canonical $missing[$i] }
    return Get-RMAbsolutePath $canonical
}

function Test-RMPathWithin([string]$Path, [string]$Parent, [switch]$AllowEqual) {
    if ([string]::Equals($Path, $Parent, [StringComparison]::OrdinalIgnoreCase)) { return [bool]$AllowEqual }
    $prefix = $Parent.TrimEnd([char[]]'\/') + [System.IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-RMPlainTree([string]$Path) {
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        $dir = Get-Item -LiteralPath ($pending.Pop()) -Force -ErrorAction Stop
        if (-not $dir.PSIsContainer) { throw "Not a mission directory: $($dir.FullName)" }
        if ($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "Reparse points are not supported inside mission trees: $($dir.FullName)" }
        foreach ($item in (Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "Reparse points are not supported inside mission trees: $($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
}

function Get-RMRestorePaths([string]$SourceMission, [string]$DestDir, [string]$AddonRoot, [switch]$Force) {
    $sourcePath = Get-RMAbsolutePath $SourceMission
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Source mission directory not found: $SourceMission" }
    if (-not (Test-Path -LiteralPath $AddonRoot -PathType Container)) { throw "Addon directory not found: $AddonRoot" }
    Assert-RMPlainTree $sourcePath
    $source = Get-RMCanonicalPath $sourcePath
    $addon = Get-RMCanonicalPath $AddonRoot
    $destinationDir = Get-RMCanonicalPath $DestDir
    $name = [System.IO.Path]::GetFileName($source)
    if (-not $name) { throw 'The source must be a mission directory, not a filesystem root.' }
    $destinationPath = Join-Path (Get-RMAbsolutePath $DestDir) $name
    if (Test-Path -LiteralPath $destinationPath) {
        if (-not $Force) { throw "Destination already exists: $destinationPath (use -Force)" }
        Assert-RMPlainTree $destinationPath
    }
    $destination = Get-RMCanonicalPath $destinationPath
    if (-not (Test-RMPathWithin $destination $addon)) { throw "Destination must be beneath the addon directory: $destination" }
    if ((Test-RMPathWithin $source $destination -AllowEqual) -or (Test-RMPathWithin $destination $source -AllowEqual)) {
        throw "Source and destination mission directories must not overlap: $source -> $destination"
    }
    return [pscustomobject]@{ Source=$source; DestDir=$destinationDir; Destination=$destination; AddonRoot=$addon; Name=$name }
}

