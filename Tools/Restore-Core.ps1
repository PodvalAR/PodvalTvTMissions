#requires -Version 5.1
<#
.SYNOPSIS
    Shared core logic facade for restoring legacy PodvalTvT (DRG-era) missions into the
    current addon by remapping only the prefab references that are actually broken.

.DESCRIPTION
    Dot-source this file ( . .\Restore-Core.ps1 ) to import the core restoration engine.
    This file acts as a unified facade, loading the modular sub-components from Core/:
      - Core\Config.ps1        : paths, safety, configuration, P/Invoke, and I/O
      - Core\TableEngine.ps1   : remap table model, parser, mutations, and serialization
      - Core\Ranker.ps1        : semantic analysis, tokenization, candidate ranking, and auto-suggest
      - Core\ModIndex.ps1      : mod prefab indexing, catalog parsing, and legacy scanning
      - Core\RestoreEngine.ps1 : mission scanning and entity restoration pipeline
      - Core\AiClient.ps1      : Anthropic/LLM integration and suggestions
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:RMToolsRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

. (Join-Path $script:RMToolsRoot 'Core\Config.ps1')
. (Join-Path $script:RMToolsRoot 'Core\TableEngine.ps1')
. (Join-Path $script:RMToolsRoot 'Core\Ranker.ps1')
. (Join-Path $script:RMToolsRoot 'Core\ModIndex.ps1')
. (Join-Path $script:RMToolsRoot 'Core\RestoreEngine.ps1')
. (Join-Path $script:RMToolsRoot 'Core\AiClient.ps1')

# Explicit AST definitions for static reflection and backward compatibility
function Get-NewPrefabsCatalog {
    [CmdletBinding()]
    param(
        [string]$Path = $script:RMC.CatalogNew,
        [switch]$SkipFeatures
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return ,(Build-NewPrefabsCatalog -Path $Path)
    }
    $fileInfo = Get-Item -LiteralPath $Path
    $signature = "$Path|$($fileInfo.Length)|$($fileInfo.LastWriteTimeUtc.Ticks)|2"
    if ($script:NewCatalogCache -and $script:NewCatalogCache.Signature -eq $signature -and
        ($SkipFeatures -or $script:NewCatalogCache.FeaturesPrepared)) {
        return ,$script:NewCatalogCache.Items
    }
    $parsedItems = Read-Text $Path | ConvertFrom-Json
    $items = @($parsedItems)
    $featuresPrepared = $true
    foreach ($item in $items) {
        $itemModIndex = if ($item.PSObject.Properties['modIndex']) { $item.modIndex } else { $item.path }
        if (-not $item.PSObject.Properties['matchingFeatures']) {
            $item | Add-Member -NotePropertyName matchingFeatures -NotePropertyValue $null
        }
        if (-not $SkipFeatures -and (-not $item.matchingFeatures -or $item.matchingFeatures.FeatureVersion -ne 2 -or
            $item.matchingFeatures.Path -ne $itemModIndex)) {
            $item.matchingFeatures = Get-RoleTokens $itemModIndex
        } elseif (-not $item.matchingFeatures) {
            $featuresPrepared = $false
        }
    }
    $script:NewCatalogCache = [pscustomobject]@{
        Signature = $signature
        Items     = $items
        FeaturesPrepared = $featuresPrepared
    }
    return ,$items
}

function Get-OldPrefabsCatalog([string]$Path = $script:RMC.CatalogOld) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    $items = Read-Text $Path | ConvertFrom-Json
    return ,@($items)
}
