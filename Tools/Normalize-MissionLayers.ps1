#requires -Version 5.1
<#
.SYNOPSIS
    Автоматическая нормализация структуры слоёв TvT-миссий Arma Reforger (PodvalTvT Standard).

.DESCRIPTION
    Автоматизирует шаги 1–8 стандарта MISSION_MIGRATION_GUIDE.md:
    1. Приведение имени миссии к канону: TvT_<ИмяМиссии>_<Карта>
    2. Синхронизация файлов мира (.ent, .ent.meta, папка слоёв _Layers)
    3. Создание структуры папок фракций (BLUFOR, OPFOR, INDFOR) и системных слоёв (_0_.._3_)
    4. Автоматическая сегрегация сущностей (пехота строго в UNITS.layer, техника строго в VEHICLES.layer,
       стационарные турели и остовы в _2_PROPS.layer)
    5. Нормализация позывных отделений: вычисление позывного (C*100 + P*10 + S) и переименование
       в <Faction>_<Callsign> (например: RU_210, USAF_010, CDF_201)
    6. Сквозная привязка техники m_sAttachmentGroupName к пехотным отделениям
    7. Нормализация маркеров: контур флага (m_sImageSetGlow), исправление "undefined",
       скрытие техники в игре (m_aHideOnGameModeStates { 1 }), ремаппинг тегов #DRG-Sq- -> #PDVL_Squad_
    8. Распределение зон фризтайма (FREEZ.layer) по координатам спавна сторон
    9. Удаление устаревших разрозненных слоёв (rus.layer, us.layer, log.layer, etc.)
    10. Опциональная автоматическая проверка чистоты через Test-MissionStandard.ps1

.PARAMETER MissionPath
    Путь к папке миссии (в репозитории мода или распакованной).

.PARAMETER SkipRename
    Не переименовывать имя миссии и файлы мира, нормализовать только слои внутри.

.PARAMETER NoValidate
    Пропустить автоматический запуск Test-MissionStandard.ps1 в конце работы.

.PARAMETER DryRun
    Режим имитации: показывает список действий без реальной записи файлов на диск.

.PARAMETER PassThru
    Возвращает объект с подробными метриками выполненной нормализации.

.EXAMPLE
    .\Normalize-MissionLayers.ps1 -MissionPath "..\Worlds\Banan\ChernarusMinus\TVT_Zavod_Chernorus_Minus"

.EXAMPLE
    .\Normalize-MissionLayers.ps1 -MissionPath "C:\MyMission" -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$MissionPath,

    [switch]$SkipRename,
    [switch]$NoValidate,
    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ Вспомогательные функции файлового ввода/вывода
function Read-FileText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-FileUtf8([string]$Path, [string]$Content) {
    if ($DryRun) {
        Write-Verbose "[DryRun] Запись файла: $Path"
        return
    }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.Encoding]::UTF8)
}

# ------------------------------------------------------------------ Парсер Enfusion синтаксиса
function Parse-EnfusionTopBlocks([string]$text) {
    $blocks = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($text)) { return ,$blocks }

    $len = $text.Length
    $i = 0
    $inQuote = $false
    $escape = $false
    $depth = 0
    $blockStart = -1

    while ($i -lt $len) {
        $ch = $text[$i]

        if ($inQuote) {
            if ($escape) { $escape = $false }
            elseif ($ch -eq '\') { $escape = $true }
            elseif ($ch -eq '"') { $inQuote = $false }
            $i++
            continue
        }

        if ($ch -eq '"') {
            $inQuote = $true
            $i++
            continue
        }

        # Комментарии строк //
        if ($ch -eq '/' -and ($i + 1 -lt $len) -and $text[$i + 1] -eq '/') {
            while ($i -lt $len -and $text[$i] -ne "`n") { $i++ }
            continue
        }

        if ($ch -eq '{') {
            if ($depth -eq 0) {
                if ($blockStart -lt 0) { $blockStart = $i }
            }
            $depth++
        } elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) {
                # Захватываем от начала заголовка (до первой '{')
                # blockStart - это индекс '{'. Найдем реальное начало блока до нее.
                $hdrStart = $blockStart
                while ($hdrStart -gt 0 -and $text[$hdrStart - 1] -notin @("`n", "`r", '}')) {
                    $hdrStart--
                }
                $blockContent = $text.Substring($hdrStart, $i - $hdrStart + 1).Trim()
                if (-not [string]::IsNullOrWhiteSpace($blockContent)) {
                    $blocks.Add($blockContent)
                }
                $blockStart = -1
            }
        }
        $i++
    }

    return ,$blocks
}

function Split-GrpBlock([string]$grpBlock) {
    $trimmed = $grpBlock.Trim()
    if (-not $trimmed.StartsWith('$grp')) {
        return @{ IsGrp = $false; Header = ''; SubEntities = @($grpBlock) }
    }

    $inQuote = $false
    $escape = $false
    $openBraceIdx = -1

    for ($i = 0; $i -lt $trimmed.Length; $i++) {
        $ch = $trimmed[$i]
        if ($inQuote) {
            if ($escape) { $escape = $false }
            elseif ($ch -eq '\') { $escape = $true }
            elseif ($ch -eq '"') { $inQuote = $false }
            continue
        }
        if ($ch -eq '"') { $inQuote = $true; continue }
        if ($ch -eq '{') {
            $openBraceIdx = $i
            break
        }
    }

    if ($openBraceIdx -lt 0) {
        return @{ IsGrp = $false; Header = ''; SubEntities = @($grpBlock) }
    }

    $header = $trimmed.Substring(0, $openBraceIdx).Trim()
    $lastBraceIdx = $trimmed.LastIndexOf('}')
    if ($lastBraceIdx -le $openBraceIdx) {
        return @{ IsGrp = $false; Header = ''; SubEntities = @($grpBlock) }
    }

    $inner = $trimmed.Substring($openBraceIdx + 1, $lastBraceIdx - $openBraceIdx - 1)
    $subBlocks = Parse-EnfusionTopBlocks $inner

    return @{
        IsGrp = $true
        Header = $header
        SubEntities = $subBlocks
    }
}

# ------------------------------------------------------------------ Извлечение координат и параметров
function Get-BlockCoords([string]$block) {
    if ($block -match 'coords\s+([\-\d\.]+)\s+([\-\d\.]+)\s+([\-\d\.]+)') {
        try {
            return @(
                [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture),
                [double]::Parse($Matches[2], [System.Globalization.CultureInfo]::InvariantCulture),
                [double]::Parse($Matches[3], [System.Globalization.CultureInfo]::InvariantCulture)
            )
        } catch { }
    }
    return $null
}

function Get-EntityName([string]$b) {
    if ($b -match '^\s*(?:\$grp\s+)?[A-Za-z0-9_]+\s+([A-Za-z0-9_]+)\s*:\s*"') {
        return $Matches[1]
    }
    $lines = $b -split "`r?`n"
    foreach ($line in $lines) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*\{') {
            $candidate = $Matches[1]
            if ($candidate -notin @('components', 'coords', 'angles', 'm_aUnitPrefabSlots', 'MultiSlots', 'Points')) {
                return $candidate
            }
        }
    }
    return ''
}

# ------------------------------------------------------------------ Определение категории и фракции
function Classify-Entity([string]$block, [string]$sourceFile) {
    if ($block -match '(?i)PS_MissionDescription|PrefabsEditable/MissionDescription') {
        return 'DESCRIPTION'
    }
    if ($block -match '(?i)PS_Objective|Prefabs/Objective/') {
        return 'OBJECTIVE'
    }
    if ($block -match '(?i)SCR_AIWorld|PerceptionManager|PS_GameModeCoop|PS_GameMode_Lobby|SCR_MapEntity') {
        return 'GAMEMODE'
    }
    if ($block -match '(?i)DRG_MissionEndTimer|DRG_CriticalLoss|GUB_ZoneControl') {
        return 'GAMELOGIC'
    }
    if ($block -match '(?i)SCR_FlagComponent|E_FlagPole') {
        return 'FLAGS'
    }
    if ($block -match '(?i)PolylineShapeEntity|PolyZone_Border|PS_PolyZone') {
        return 'ZONES'
    }
    if ($block -match '(?i)SCR_EditorRestrictionZoneEntity|Prefabs/RestrictionZone') {
        return 'FREEZ'
    }
    if ($block -match '(?i)PS_ManualMarker|PrefabsEditable/Markers/') {
        return 'MARKER'
    }
    if ($block -match '(?i)(Tripod|NSV|Kord|AGS|TOW|Browning|DShKM|SPG9|Mortar|M2HB_Mini|Static)') {
        return 'PROP'
    }
    if ($block -match '^\s*(\$grp\s+)?Vehicle\s+' -or $block -match 'Prefabs/Vehicles/') {
        return 'VEHICLE'
    }
    if ($block -match '^\s*(\$grp\s+)?SCR_AIGroup\s+' -or $block -match 'Prefabs/Groups/') {
        return 'INFANTRY'
    }
    return 'PROP'
}

function Determine-Faction([string]$block, [string]$sourceFile) {
    $src = $sourceFile.ToLowerInvariant()
    $blk = $block.ToLowerInvariant()

    # Сначала по содержимому префабов
    if ($blk -match 'groupflagsblufor|prefabs/groups/blufor|rhs_usaf|ses_cdf|/characters/factions/blufor|prefabs/vehicles/wheeled/m998|/us/') {
        return 'BLUFOR'
    }
    if ($blk -match 'groupflagsopfor|prefabs/groups/opfor|rhs_afrf|ses_chdkz|ses_tka|/characters/factions/opfor|btr70|ural|k17|/ussr/') {
        return 'OPFOR'
    }
    if ($blk -match 'groupflagsindfor|prefabs/groups/indfor|ses_tkr|ses_napa|rhs_ion|/characters/factions/indfor|/fia/') {
        return 'INDFOR'
    }

    # Затем по имени файла источника
    if ($src -match 'blufor|\busaf?\b|\bcdf\b') { return 'BLUFOR' }
    if ($src -match 'opfor|\brusa?\b|\bafrf\b|\bchdkz\b|\btka\b') { return 'OPFOR' }
    if ($src -match 'indfor|\bfia\b|\btkr\b|\bnapa\b|\bion\b') { return 'INDFOR' }

    return 'OPFOR'
}

function Get-SimpleFactionKey([string]$faction, [string]$block) {
    $blk = $block.ToLowerInvariant()
    switch ($faction) {
        'BLUFOR' {
            if ($blk -match 'cdf') { return 'CDF' }
            return 'USAF'
        }
        'OPFOR' {
            if ($blk -match 'chdkz') { return 'ChDKZ' }
            if ($blk -match 'tka') { return 'TKA' }
            return 'RU'
        }
        'INDFOR' {
            if ($blk -match 'tkr') { return 'TKR' }
            if ($blk -match 'napa') { return 'NAPA' }
            if ($blk -match 'ion') { return 'ION' }
            return 'FIA'
        }
        default { return 'RU' }
    }
}

# ------------------------------------------------------------------ Главная функция нормализации
function Invoke-MissionNormalization {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Каталог миссии не найден: $Path"
    }

    $missionDir = (Get-Item -LiteralPath $Path).FullName
    $missionName = Split-Path -Leaf $missionDir
    $parentDir = Split-Path -Parent $missionDir
    $report = [pscustomobject]@{
        OriginalName    = $missionName
        TargetName      = $missionName
        Renamed         = $false
        EntitiesMoved   = 0
        GroupsRenamed   = 0
        VehiclesAttached = 0
        MarkersFixed    = 0
        LayersCleaned   = New-Object System.Collections.Generic.List[string]
        Validation      = $null
    }

    # 1. Шаг нормализации имени миссии (TvT_<ИмяМиссии>_<Карта>)
    $targetName = $missionName
    if (-not $SkipRename) {
        $canonicalMap = ''
        $knownMaps = @('Everon', 'Arland', 'Zarichne', 'Zargabad', 'Marnivka', 'Ruha', 'Chernorus', 'Chernarus', 'Anizay', 'Gogland', 'Googland', 'Eden', 'Kunar', 'AlHadra')
        foreach ($km in $knownMaps) {
            if ($missionName -match "(?i)$km" -or $missionDir -match "(?i)[\\/_]$km([\\/_]|$)") {
                $canonicalMap = $km; break
            }
        }
        if (-not $canonicalMap) {
            $curr = $parentDir
            while ($curr -and (Split-Path -Leaf $curr) -ne 'Worlds') {
                $leaf = Split-Path -Leaf $curr
                foreach ($km in $knownMaps) {
                    if ($leaf -match "(?i)^$km$") { $canonicalMap = $km; break }
                }
                if ($canonicalMap) { break }
                $curr = Split-Path -Parent $curr
            }
        }
        if (-not $canonicalMap) { $canonicalMap = 'Map' }

        $cleanBase = $missionName
        if ($cleanBase -match '^(?i)TvT_(.+)$') { $cleanBase = $Matches[1] }
        if ($cleanBase -match "^(?i)(.+)_$canonicalMap$") { $cleanBase = $Matches[1] }

        $targetName = "TvT_${cleanBase}_$canonicalMap"

        if ($targetName -ne $missionName) {
            Write-Host "Нормализация имени: '$missionName' -> '$targetName'" -ForegroundColor Cyan
            $report.Renamed = $true
            $report.TargetName = $targetName

            if (-not $DryRun) {
                $oldEnt = Join-Path $missionDir "$missionName.ent"
                $newEnt = Join-Path $missionDir "$targetName.ent"
                if (Test-Path -LiteralPath $oldEnt) { Rename-Item -LiteralPath $oldEnt -NewName "$targetName.ent" -Force }

                $oldMeta = Join-Path $missionDir "$missionName.ent.meta"
                $newMeta = Join-Path $missionDir "$targetName.ent.meta"
                if (Test-Path -LiteralPath $oldMeta) {
                    Rename-Item -LiteralPath $oldMeta -NewName "$targetName.ent.meta" -Force
                    $metaTxt = Read-FileText $newMeta
                    if ($metaTxt -match 'Name\s+"\{[0-9A-Fa-f]{16}\}([^"]+)"') {
                        $oldRes = $Matches[1]
                        $newRes = $oldRes -replace [regex]::Escape("$missionName.ent"), "$targetName.ent"
                        $metaTxt = $metaTxt -replace [regex]::Escape($oldRes), $newRes
                        Write-FileUtf8 $newMeta $metaTxt
                    }
                }

                $oldLayers = Join-Path $missionDir "${missionName}_Layers"
                $newLayers = Join-Path $missionDir "${targetName}_Layers"
                if (Test-Path -LiteralPath $oldLayers) {
                    Rename-Item -LiteralPath $oldLayers -NewName "${targetName}_Layers" -Force
                }

                $newMissionDir = Join-Path $parentDir $targetName
                Rename-Item -LiteralPath $missionDir -NewName $targetName -Force
                $missionDir = $newMissionDir
            }
        }
    }

    $layersDir = Join-Path $missionDir "${targetName}_Layers"
    if (-not (Test-Path -LiteralPath $layersDir -PathType Container)) {
        $anyLayers = @(Get-ChildItem -LiteralPath $missionDir -Directory -Filter "*_Layers")
        if ($anyLayers.Count -gt 0) {
            $layersDir = $anyLayers[0].FullName
        } else {
            $layersDir = Join-Path $missionDir "${targetName}_Layers"
            if (-not $DryRun) { New-Item -ItemType Directory -Path $layersDir -Force | Out-Null }
        }
    }

    # 2. Сбор всех существующих .layer файлов
    $allLayerFiles = if (Test-Path -LiteralPath $layersDir -PathType Container) {
        @(Get-ChildItem -LiteralPath $layersDir -Recurse -Filter "*.layer" -File -ErrorAction SilentlyContinue)
    } else {
        @()
    }
    Write-Host "Обнаружено файлов слоёв для анализа: $($allLayerFiles.Count)" -ForegroundColor Gray

    $entitiesByLayer = @{
        'DESCRIPTION' = New-Object System.Collections.Generic.List[string]
        'OBJECTIVE'   = New-Object System.Collections.Generic.List[string]
        'GAMEMODE'    = New-Object System.Collections.Generic.List[string]
        'GAMELOGIC'   = New-Object System.Collections.Generic.List[string]
        'FLAGS'       = New-Object System.Collections.Generic.List[string]
        'PROPS'       = New-Object System.Collections.Generic.List[string]
        'ZONES'       = New-Object System.Collections.Generic.List[string]
    }

    $factions = @('BLUFOR', 'OPFOR', 'INDFOR')
    $factionUnits = @{}
    $factionVehicles = @{}
    $factionMarkers = @{}
    $restrictionZones = New-Object System.Collections.Generic.List[object]

    foreach ($f in $factions) {
        $factionUnits[$f] = New-Object System.Collections.Generic.List[string]
        $factionVehicles[$f] = New-Object System.Collections.Generic.List[string]
        $factionMarkers[$f] = New-Object System.Collections.Generic.List[string]
    }

    # 3. Разбор каждого .layer файла на сущности
    foreach ($lf in $allLayerFiles) {
        $content = Read-FileText $lf.FullName
        $topBlocks = Parse-EnfusionTopBlocks $content

        foreach ($top in $topBlocks) {
            $spl = Split-GrpBlock $top
            if ($spl.IsGrp) {
                $cat = Classify-Entity $spl.Header $lf.Name
                $fact = Determine-Faction $spl.Header $lf.Name

                if ($cat -in @('INFANTRY', 'VEHICLE', 'MARKER', 'PROP')) {
                    foreach ($sub in $spl.SubEntities) {
                        if ($sub -match '(?i)(Tripod|NSV|Kord|AGS|TOW|Browning|DShKM|SPG9|Mortar|M2HB_Mini|Static)') {
                            $entitiesByLayer['PROPS'].Add($sub)
                            $report.EntitiesMoved++
                            continue
                        }

                        $subCat = $cat
                        $subFact = Determine-Faction $sub $lf.Name
                        if ($subFact -eq 'OPFOR' -and $fact -ne 'OPFOR' -and $sub -notmatch '(?i)blufor|usaf|cdf|indfor') {
                            $subFact = $fact
                        }

                        $rebuilt = "$($spl.Header) {`n $sub`n}"
                        if ($subCat -eq 'VEHICLE') {
                            $factionVehicles[$subFact].Add($rebuilt)
                        } elseif ($subCat -eq 'INFANTRY') {
                            $factionUnits[$subFact].Add($rebuilt)
                        } elseif ($subCat -eq 'MARKER') {
                            $factionMarkers[$subFact].Add($rebuilt)
                        } else {
                            $entitiesByLayer['PROPS'].Add($rebuilt)
                        }
                        $report.EntitiesMoved++
                    }
                } elseif ($cat -eq 'FREEZ') {
                    foreach ($sub in $spl.SubEntities) {
                        $rebuilt = "$($spl.Header) {`n $sub`n}"
                        $coords = Get-BlockCoords $sub
                        $restrictionZones.Add([pscustomobject]@{ Block = $rebuilt; Coords = $coords })
                    }
                } elseif ($cat -eq 'DESCRIPTION') {
                    $entitiesByLayer['DESCRIPTION'].Add($top)
                } elseif ($cat -eq 'OBJECTIVE') {
                    $entitiesByLayer['OBJECTIVE'].Add($top)
                } elseif ($cat -eq 'GAMEMODE') {
                    $entitiesByLayer['GAMEMODE'].Add($top)
                } elseif ($cat -eq 'GAMELOGIC') {
                    $entitiesByLayer['GAMELOGIC'].Add($top)
                } elseif ($cat -eq 'FLAGS') {
                    $entitiesByLayer['FLAGS'].Add($top)
                } elseif ($cat -eq 'ZONES') {
                    $entitiesByLayer['ZONES'].Add($top)
                } else {
                    $entitiesByLayer['PROPS'].Add($top)
                }
            } else {
                $cat = Classify-Entity $top $lf.Name
                $fact = Determine-Faction $top $lf.Name

                if ($cat -eq 'INFANTRY') {
                    $factionUnits[$fact].Add($top)
                } elseif ($cat -eq 'VEHICLE') {
                    $factionVehicles[$fact].Add($top)
                } elseif ($cat -eq 'MARKER') {
                    $factionMarkers[$fact].Add($top)
                } elseif ($cat -eq 'FREEZ') {
                    $coords = Get-BlockCoords $top
                    $restrictionZones.Add([pscustomobject]@{ Block = $top; Coords = $coords })
                } elseif ($cat -eq 'DESCRIPTION') {
                    $entitiesByLayer['DESCRIPTION'].Add($top)
                } elseif ($cat -eq 'OBJECTIVE') {
                    $entitiesByLayer['OBJECTIVE'].Add($top)
                } elseif ($cat -eq 'GAMEMODE') {
                    $entitiesByLayer['GAMEMODE'].Add($top)
                } elseif ($cat -eq 'GAMELOGIC') {
                    $entitiesByLayer['GAMELOGIC'].Add($top)
                } elseif ($cat -eq 'FLAGS') {
                    $entitiesByLayer['FLAGS'].Add($top)
                } elseif ($cat -eq 'ZONES') {
                    $entitiesByLayer['ZONES'].Add($top)
                } else {
                    $entitiesByLayer['PROPS'].Add($top)
                }
                $report.EntitiesMoved++
            }
        }
    }

    # 4. Нормализация пехоты (UNITS.layer) и составление таблицы позывных
    $groupRenameMap = @{}
    $groupCoordsMap = @{}
    $factionCentroids = @{}

    foreach ($fact in $factions) {
        $normUnits = New-Object System.Collections.Generic.List[string]
        $rawUnits = $factionUnits[$fact]
        $usedCallsigns = @{}
        $totalX = 0; $totalZ = 0; $unitCount = 0

        for ($uIdx = 0; $uIdx -lt $rawUnits.Count; $uIdx++) {
            $uBlock = $rawUnits[$uIdx]
            $oldName = Get-EntityName $uBlock
            $coords = Get-BlockCoords $uBlock

            if ($coords) {
                $totalX += $coords[0]; $totalZ += $coords[2]; $unitCount++
            }

            $C = 0; $P = 0; $S = 0
            if ($uBlock -match 'm_iCompanyCallsign\s+(\d+)') { $C = [int]$Matches[1] }
            if ($uBlock -match 'm_iPlatoonCallsign\s+(\d+)') { $P = [int]$Matches[1] }
            if ($uBlock -match 'm_iSquadCallsign\s+(\d+)') { $S = [int]$Matches[1] }

            $callsignStr = "{0}{1}{2}" -f $C, $P, $S
            $factionKey = Get-SimpleFactionKey $fact $uBlock
            $newName = "${factionKey}_$callsignStr"

            if ($usedCallsigns.ContainsKey($newName)) {
                $usedCallsigns[$newName]++
                $newName = "${newName}_$($usedCallsigns[$newName])"
            } else {
                $usedCallsigns[$newName] = 1
            }

            if ($oldName -and $oldName -ne $newName) {
                $groupRenameMap[$oldName] = $newName
                $uBlock = $uBlock -replace "(?m)^\s*$([regex]::Escape($oldName))\s*\{", " $newName {"
                $report.GroupsRenamed++
            }

            if ($coords) {
                $groupCoordsMap[$newName] = $coords
            }

            $normUnits.Add($uBlock)
        }

        $factionUnits[$fact] = $normUnits
        if ($unitCount -gt 0) {
            $avgX = [double]($totalX / $unitCount)
            $avgZ = [double]($totalZ / $unitCount)
            $factionCentroids[$fact] = @($avgX, 0.0, $avgZ)
        }
    }

    # 5. Нормализация техники (VEHICLES.layer) и привязка к группам
    foreach ($fact in $factions) {
        $normVehicles = New-Object System.Collections.Generic.List[string]
        $rawVeh = $factionVehicles[$fact]
        $vehIndexByGroup = @{}

        foreach ($vBlock in $rawVeh) {
            $oldVehName = Get-EntityName $vBlock
            $vCoords = Get-BlockCoords $vBlock
            $targetGroup = ''

            if ($vBlock -match 'm_sAttachmentGroupName\s+"([^"]*)"') {
                $currAttach = $Matches[1].Trim()
                if ($groupRenameMap.ContainsKey($currAttach)) {
                    $targetGroup = $groupRenameMap[$currAttach]
                } elseif ($groupCoordsMap.ContainsKey($currAttach)) {
                    $targetGroup = $currAttach
                }
            }

            if (-not $targetGroup -and $vCoords) {
                $bestDist = [double]::MaxValue
                foreach ($gName in $groupCoordsMap.Keys) {
                    if ($gName.StartsWith((Get-SimpleFactionKey $fact ''))) {
                        $gCoords = $groupCoordsMap[$gName]
                        $dx = $vCoords[0] - $gCoords[0]
                        $dz = $vCoords[2] - $gCoords[2]
                        $dist = [Math]::Sqrt($dx * $dx + $dz * $dz)
                        if ($dist -lt $bestDist) {
                            $bestDist = $dist
                            $targetGroup = $gName
                        }
                    }
                }
            }

            if (-not $targetGroup) {
                foreach ($gName in $groupCoordsMap.Keys) {
                    if ($gName.StartsWith((Get-SimpleFactionKey $fact ''))) {
                        $targetGroup = $gName; break
                    }
                }
            }

            if ($targetGroup) {
                if (-not $vehIndexByGroup.ContainsKey($targetGroup)) {
                    $vehIndexByGroup[$targetGroup] = 1
                    $newVehName = "${targetGroup}_V"
                } else {
                    $vehIndexByGroup[$targetGroup]++
                    $newVehName = "${targetGroup}_V$($vehIndexByGroup[$targetGroup])"
                }

                if ($oldVehName) {
                    $vBlock = $vBlock -replace "(?m)^\s*$([regex]::Escape($oldVehName))\s*\{", " $newVehName {"
                    $vBlock = $vBlock -replace "(?m)^\s*Vehicle\s+$([regex]::Escape($oldVehName))\s*:", "Vehicle $newVehName :"
                }

                if ($vBlock -match 'm_sAttachmentGroupName\s+"[^"]*"') {
                    $vBlock = $vBlock -replace 'm_sAttachmentGroupName\s+"[^"]*"', "m_sAttachmentGroupName `"$targetGroup`""
                } else {
                    $vBlock = $vBlock -replace '(?s)\}\s*$', " m_sAttachmentGroupName `"$targetGroup`"`n}"
                }
                $report.VehiclesAttached++
            }

            $normVehicles.Add($vBlock)
        }
        $factionVehicles[$fact] = $normVehicles
    }

    # 6. Нормализация маркеров (MARKERS.layer)
    foreach ($fact in $factions) {
        $normMarkers = New-Object System.Collections.Generic.List[string]
        $glowImageset = switch ($fact) {
            'BLUFOR' { '{D1BFDF90DD7A4E01}UI/Textures/GroupManagement/FlagIcons/GroupFlagsBlufor-outline.imageset' }
            'OPFOR'  { '{B9356E7B2E974DCD}UI/Textures/GroupManagement/FlagIcons/GroupFlagsOpfor-outline.imageset' }
            'INDFOR' { '{C07D82625600BA21}UI/Textures/GroupManagement/FlagIcons/GroupFlagsIndfor-outline.imageset' }
        }

        foreach ($mBlock in $factionMarkers[$fact]) {
            $fixed = $mBlock

            if ($fixed -match 'GroupFlags(Blufor|Opfor|Indfor)\.imageset') {
                if ($fixed -match 'm_sImageSetGlow\s+"[^"]*"') {
                    $fixed = $fixed -replace 'm_sImageSetGlow\s+"[^"]*"', "m_sImageSetGlow `"$glowImageset`""
                } else {
                    $fixed = $fixed -replace '(?m)(^\s*m_sImageSet\s+.*$)', "`$1`n  m_sImageSetGlow `"$glowImageset`""
                }

                if ($fixed -match 'm_sQuadName\s+"undefined"') {
                    $quad = if ($fixed -match '(?i)hq|command|000|010') { 'commander' } else { 'infantry' }
                    $fixed = $fixed -replace 'm_sQuadName\s+"undefined"', "m_sQuadName `"$quad`""
                    $report.MarkersFixed++
                }

                if ($fixed -match '#DRG-Sq-') {
                    $fixed = $fixed -replace '#DRG-Sq-PlatoonHQ', '#PDVL_Squad_PLHQ'
                    $fixed = $fixed -replace '#DRG-Sq-RifleSquad', '#PDVL_Squad_Rifle'
                    $fixed = $fixed -replace '#DRG-Sq-Recon', '#PDVL_Squad_Recon'
                    $fixed = $fixed -replace '#DRG-Sq-Sniper', '#PDVL_Squad_Sniper'
                    $fixed = $fixed -replace '#DRG-Sq-Crew', '#PDVL_Squad_Crew'
                    $fixed = $fixed -replace '#DRG-Sq-Pilot', '#PDVL_Squad_Pilot'
                    $fixed = $fixed -replace '#DRG-Sq-Medic', '#PDVL_Squad_Medic'
                    $fixed = $fixed -replace '#DRG-Sq-Sapper', '#PDVL_Squad_Sapper'
                    $fixed = $fixed -replace '#DRG-Sq-BigMG', '#PDVL_Squad_BigMG'
                    $fixed = $fixed -replace '#DRG-Sq-PTRK', '#PDVL_Squad_PTRK'
                    $fixed = $fixed -replace '#DRG-Sq-', '#PDVL_Squad_'
                    $report.MarkersFixed++
                }

                if ($fixed -notmatch 'm_bVisibleForEmptyFaction') {
                    $fixed = $fixed -replace '(?m)(^\s*m_sImageSet\s+.*$)', "`$1`n  m_bVisibleForEmptyFaction 1"
                }
                if ($fixed -notmatch 'm_iZOrder') {
                    $fixed = $fixed -replace '(?m)(^\s*m_sImageSet\s+.*$)', "`$1`n  m_iZOrder 10"
                }
            }

            if ($fixed -match 'PS_Atlas_x64\.imageset') {
                if ($fixed -notmatch 'm_aHideOnGameModeStates') {
                    $fixed = $fixed -replace '(?m)(^\s*m_sImageSet\s+.*$)', "`$1`n  m_aHideOnGameModeStates { GAME }"
                    $report.MarkersFixed++
                }
            }

            $normMarkers.Add($fixed)
        }
        $factionMarkers[$fact] = $normMarkers
    }

    # 7. Распределение зон фризтайма по спавнам сторон
    $factionFreez = @{
        'BLUFOR' = New-Object System.Collections.Generic.List[string]
        'OPFOR'  = New-Object System.Collections.Generic.List[string]
        'INDFOR' = New-Object System.Collections.Generic.List[string]
    }

    foreach ($z in $restrictionZones) {
        $bestFaction = 'OPFOR'
        $bestDist = [double]::MaxValue
        if ($z.Coords) {
            foreach ($fact in $factionCentroids.Keys) {
                $fc = $factionCentroids[$fact]
                $dx = $z.Coords[0] - $fc[0]
                $dz = $z.Coords[2] - $fc[2]
                $dist = [Math]::Sqrt($dx * $dx + $dz * $dz)
                if ($dist -lt $bestDist) {
                    $bestDist = $dist
                    $bestFaction = $fact
                }
            }
        }
        $factionFreez[$bestFaction].Add($z.Block)
    }

    # 8. Нормализация системных слоёв
    $normDesc = New-Object System.Collections.Generic.List[string]
    foreach ($dBlock in $entitiesByLayer['DESCRIPTION']) {
        $fixedDesc = $dBlock
        if ($fixedDesc -notmatch 'm_sDescriptionLayout') {
            $fixedDesc = $fixedDesc -replace '(?s)\}\s*$', " m_sDescriptionLayout `"{B6DE04F7CF7A95DA}UI/MissionDescription/DescriptionEditableScrollable.layout`"`n}"
        } else {
            $fixedDesc = $fixedDesc -replace 'm_sDescriptionLayout\s+"[^"]*"', 'm_sDescriptionLayout "{B6DE04F7CF7A95DA}UI/MissionDescription/DescriptionEditableScrollable.layout"'
        }
        if ($fixedDesc -notmatch 'm_bEmptyFactionVisibility') {
            $fixedDesc = $fixedDesc -replace '(?s)\}\s*$', " m_bEmptyFactionVisibility 1`n}"
        }
        if ($fixedDesc -notmatch 'm_bShowForAnyFaction') {
            $fixedDesc = $fixedDesc -replace '(?s)\}\s*$', " m_bShowForAnyFaction 1`n}"
        }
        $normDesc.Add($fixedDesc)
    }
    $entitiesByLayer['DESCRIPTION'] = $normDesc

    $normGM = New-Object System.Collections.Generic.List[string]
    $hasAIWorld = $false
    $hasPerception = $false
    $hasLobby = $false

    foreach ($gmBlock in $entitiesByLayer['GAMEMODE']) {
        $fixedGM = $gmBlock
        if ($fixedGM -match 'SCR_AIWorld') { $hasAIWorld = $true }
        if ($fixedGM -match 'PerceptionManager') { $hasPerception = $true }
        if ($fixedGM -match 'PS_GameModeCoop|PS_GameMode_Lobby') {
            $hasLobby = $true
            if ($fixedGM -match 'm_iFreezeTime\s+\d+') {
                $fixedGM = $fixedGM -replace 'm_iFreezeTime\s+\d+', 'm_iFreezeTime 300000'
            } else {
                $fixedGM = $fixedGM -replace '(?s)\}\s*$', " m_iFreezeTime 300000`n}"
            }
        }
        $normGM.Add($fixedGM)
    }

    if (-not $hasAIWorld) {
        $normGM.Add('SCR_AIWorld : "{E0A05C76552E7F58}Prefabs/AI/SCR_AIWorld.et" { }')
    }
    if (-not $hasPerception) {
        $normGM.Add('PerceptionManager PerceptionManager1 : "{028DAEAD63E056BE}Prefabs/World/Game/PerceptionManager.et" { }')
    }
    if (-not $hasLobby) {
        $normGM.Add('PS_GameModeCoop PS_GameMode_Lobby1 : "{9C2001FE7A2F2281}Prefabs/MP/Modes/PS_GameMode_Lobby.et" {' + "`n" + ' m_iFreezeTime 300000' + "`n}")
    }
    $entitiesByLayer['GAMEMODE'] = $normGM

    # 9. Запись целевых слоёв на диск
    $layerOutputs = @{
        '_0_DESCRIPTION.layer' = ($entitiesByLayer['DESCRIPTION'] -join "`n`n")
        '_0_OBJECTIVES.layer'  = ($entitiesByLayer['OBJECTIVE'] -join "`n`n")
        '_1_GAME_MODE.layer'   = ($entitiesByLayer['GAMEMODE'] -join "`n`n")
        '_1_GAME_LOGIC.layer'  = ($entitiesByLayer['GAMELOGIC'] -join "`n`n")
        '_2_FLAGS.layer'       = ($entitiesByLayer['FLAGS'] -join "`n`n")
        '_2_PROPS.layer'       = ($entitiesByLayer['PROPS'] -join "`n`n")
        '_3_ZONES.layer'       = ($entitiesByLayer['ZONES'] -join "`n`n")
    }

    foreach ($k in $layerOutputs.Keys) {
        $txt = $layerOutputs[$k]
        if (-not [string]::IsNullOrWhiteSpace($txt)) {
            $destPath = Join-Path $layersDir $k
            Write-FileUtf8 $destPath $txt
        }
    }

    foreach ($fact in $factions) {
        $factDir = Join-Path $layersDir $fact
        $hasFactionData = ($factionUnits[$fact].Count + $factionVehicles[$fact].Count + $factionMarkers[$fact].Count + $factionFreez[$fact].Count) -gt 0

        if ($hasFactionData) {
            if (-not $DryRun) {
                if (-not (Test-Path -LiteralPath $factDir -PathType Container)) {
                    New-Item -ItemType Directory -Path $factDir -Force | Out-Null
                }
            }

            if ($factionUnits[$fact].Count -gt 0) {
                Write-FileUtf8 (Join-Path $factDir 'UNITS.layer') ($factionUnits[$fact] -join "`n`n")
            }
            if ($factionVehicles[$fact].Count -gt 0) {
                Write-FileUtf8 (Join-Path $factDir 'VEHICLES.layer') ($factionVehicles[$fact] -join "`n`n")
            }
            if ($factionMarkers[$fact].Count -gt 0) {
                Write-FileUtf8 (Join-Path $factDir 'MARKERS.layer') ($factionMarkers[$fact] -join "`n`n")
            }
            if ($factionFreez[$fact].Count -gt 0) {
                Write-FileUtf8 (Join-Path $factDir 'FREEZ.layer') ($factionFreez[$fact] -join "`n`n")
            }
        }
    }

    # 10. Удаление старых ненормализованных файлов слоёв
    $legacyNames = @(
        'rus.layer', 'us.layer', 'usa.layer', 'fia.layer', 'tkr.layer', 'tka.layer',
        'log.layer', 'desc.layer', 'objdescr.layer', 'domiki.layer', 'friz.layer',
        'default.layer', 'zone.layer', 'polyzone.layer', 'props.layer', 'decor.layer',
        'miscr.layer', 'rus_marker.layer', 'rus_markers.layer', 'usaf_marker.layer',
        'usaf_markers.layer', 'ion.layer', 'ion_markers.layer', 'vehicl.layer',
        'atack', 'def'
    )

    foreach ($lf in $allLayerFiles) {
        $baseName = $lf.Name.ToLowerInvariant()
        $relPath = $lf.FullName.Substring($layersDir.Length).TrimStart('\', '/')
        if ($baseName -in $legacyNames -or $relPath -match '^(?i)(atack|def)\\') {
            if (-not $DryRun) {
                Remove-Item -LiteralPath $lf.FullName -Force -ErrorAction SilentlyContinue
            }
            $report.LayersCleaned.Add($lf.Name)
        }
    }

    if (-not $DryRun) {
        foreach ($oldSub in @('Atack', 'Def', 'atack', 'def')) {
            $sp = Join-Path $layersDir $oldSub
            if (Test-Path -LiteralPath $sp -PathType Container) {
                Remove-Item -LiteralPath $sp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 11. Автоматическая валидация через Test-MissionStandard.ps1
    if (-not $NoValidate) {
        $validatorScript = Join-Path $PSScriptRoot 'Test-MissionStandard.ps1'
        if (Test-Path -LiteralPath $validatorScript -PathType Leaf) {
            Write-Host "`nЗапуск валидации стандарта..." -ForegroundColor Cyan
            $valResult = & $validatorScript -MissionPath $missionDir -PassThru
            $report.Validation = $valResult
        }
    }

    Write-Host "`n=================== НОРМАЛИЗАЦИЯ МИССИИ ЗАВЕРШЕНА ===================" -ForegroundColor Green
    Write-Host "Миссия:           $targetName"
    Write-Host "Сущностей:        $($report.EntitiesMoved) перенесено в целевые слои"
    Write-Host "Отделений:        $($report.GroupsRenamed) переименовано в формат <Faction>_<Callsign>"
    Write-Host "Техники:          $($report.VehiclesAttached) закреплено через m_sAttachmentGroupName"
    Write-Host "Маркеров:         $($report.MarkersFixed) обновлено (контуры, квады, теги)"
    Write-Host "Слоёв очищено:    $($report.LayersCleaned.Count) старых файлов удалено"
    Write-Host "=====================================================================" -ForegroundColor Green

    if ($PassThru) { return $report }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-MissionNormalization -Path $MissionPath
}
