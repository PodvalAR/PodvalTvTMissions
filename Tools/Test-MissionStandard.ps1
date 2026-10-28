#requires -Version 5.1
<#
.SYNOPSIS
    Валидатор стандарта TvT-миссий Arma Reforger (PodvalTvT Standard).

.DESCRIPTION
    Проверяет структуру слоёв, чистоту разделения пехоты и техники, позывные групп,
    сквозную привязку техники (m_sAttachmentGroupName), маркеры, зоны фризтайма
    и системные слои миссии на соответствие спецификации MISSION_MIGRATION_GUIDE.md.

    По умолчанию ошибки (Errors) вызывают ненулевой код возврата, а предупреждения
    (Warnings) только информируют оператора. Ключ -Strict переводит предупреждения
    в категорию блокирующих проверку.

.PARAMETER MissionPath
    Путь к папке миссии (например: Worlds\\Author\\TvT_MissionName_Map).

.PARAMETER ReportJson
    Необязательный путь для сохранения полного отчёта валидации в формате JSON.

.PARAMETER Strict
    Режим строгой проверки: любые предупреждения (Warnings) считаются ошибкой.

.PARAMETER PassThru
    Возвращает объект отчёта в конвейер PowerShell.

.EXAMPLE
    .\\Test-MissionStandard.ps1 -MissionPath "..\\Worlds\\Banan\\Everon\\TvT_LigthHouse_Everon"

.EXAMPLE
    .\\Test-MissionStandard.ps1 -MissionPath "C:\\MyMission" -ReportJson "report.json" -Strict
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [Alias('MissionDir')]
    [string]$MissionPath,

    [string]$ReportJson,
    [switch]$Strict,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ Структура проблем
function New-Issue {
    param(
        [ValidateSet('ERROR', 'WARNING', 'INFO')][string]$Level,
        [string]$Category,
        [string]$File,
        [int]$Line = 0,
        [string]$Message,
        [string]$Recommendation
    )
    [pscustomobject]@{
        Level          = $Level
        Severity       = $Level
        Category       = $Category
        RuleId         = $Category
        File           = $File
        Line           = $Line
        Message        = $Message
        Recommendation = $Recommendation
    }
}

# ------------------------------------------------------------------ Вспомогательный парсер Enfusion
function Read-FileLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
}

function Read-FileText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

# ------------------------------------------------------------------ Основной валидатор
function Test-MissionStructure {
    param([string]$Path)

    $issues = New-Object System.Collections.Generic.List[object]

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        $issues.Add((New-Issue -Level 'ERROR' -Category 'Structure' -File $Path `
            -Message "Каталог миссии не найден: $Path" `
            -Recommendation "Укажите существующий путь к папке миссии."))
        return $issues
    }

    $missionDir = (Get-Item -LiteralPath $Path).FullName
    $missionName = (Split-Path -Leaf $missionDir)

    # 1. Проверка именования папки: TvT_<ИмяМиссии>_<Карта>
    if ($missionName -notmatch '^TvT_.+_[A-Za-z0-9]+$') {
        $issues.Add((New-Issue -Level 'WARNING' -Category 'Naming' -File $missionDir `
            -Message "Имя папки '$missionName' не соответствует стандарту 'TvT_<ИмяМиссии>_<Карта>'." `
            -Recommendation "Переименуйте папку в соответствии с форматом: префикс 'TvT_' и суффикс '_<Карта>' (например, TvT_Zavod_Zarichne)."))
    }

    # 2. Синхронизация трёх звеньев (папка, .ent, .ent.meta, папка _Layers)
    $entFile = Join-Path $missionDir "$missionName.ent"
    $metaFile = Join-Path $missionDir "$missionName.ent.meta"
    $layersDir = Join-Path $missionDir "${missionName}_Layers"

    if (-not (Test-Path -LiteralPath $entFile -PathType Leaf)) {
        $anyEnt = @(Get-ChildItem -LiteralPath $missionDir -Filter *.ent -File -ErrorAction SilentlyContinue)
        if ($anyEnt.Count -gt 0) {
            $issues.Add((New-Issue -Level 'ERROR' -Category 'Naming' -File $anyEnt[0].FullName `
                -Message "Файл мира называется '$($anyEnt[0].Name)', а должен совпадать с именем папки '$missionName.ent'." `
                -Recommendation "Переименуйте файл мира в '$missionName.ent'."))
            $entFile = $anyEnt[0].FullName
        } else {
            $issues.Add((New-Issue -Level 'ERROR' -Category 'Structure' -File $missionDir `
                -Message "В корне миссии не найден файл мира '$missionName.ent'." `
                -Recommendation "Убедитесь, что миссия содержит файл мира .ent."))
        }
    }

    if (-not (Test-Path -LiteralPath $metaFile -PathType Leaf)) {
        $anyMeta = @(Get-ChildItem -LiteralPath $missionDir -Filter *.ent.meta -File -ErrorAction SilentlyContinue)
        if ($anyMeta.Count -gt 0) {
            $issues.Add((New-Issue -Level 'WARNING' -Category 'Naming' -File $anyMeta[0].FullName `
                -Message "Мета-файл мира называется '$($anyMeta[0].Name)', а должен совпадать с именем папки '$missionName.ent.meta'." `
                -Recommendation "Переименуйте мета-файл мира в '$missionName.ent.meta'."))
            $metaFile = $anyMeta[0].FullName
        } else {
            $issues.Add((New-Issue -Level 'WARNING' -Category 'Structure' -File $missionDir `
                -Message "В корне миссии не найден мета-файл мира '$missionName.ent.meta'." `
                -Recommendation "Создайте мета-файл .ent.meta с параметром ResourcePath."))
        }
    } else {
        $metaText = Read-FileText $metaFile
        if ($metaText -match 'Name\s+"\{[0-9A-Fa-f]{16}\}([^"]+)"') {
            $resPath = $Matches[1]
            if ($resPath -notmatch "$missionName\.ent$") {
                $issues.Add((New-Issue -Level 'WARNING' -Category 'Metadata' -File $metaFile `
                    -Message "ResourcePath в .ent.meta указывает на '$resPath', а не на '$missionName.ent'." `
                    -Recommendation "Обновите ResourcePath в .ent.meta, чтобы он вёл на правильный .ent."))
            }
        }
    }

    if (-not (Test-Path -LiteralPath $layersDir -PathType Container)) {
        $anyLayers = @(Get-ChildItem -LiteralPath $missionDir -Directory -Filter "*_Layers" -ErrorAction SilentlyContinue)
        if ($anyLayers.Count -gt 0) {
            $issues.Add((New-Issue -Level 'ERROR' -Category 'Naming' -File $anyLayers[0].FullName `
                -Message "Каталог слоёв называется '$($anyLayers[0].Name)', а должен совпадать с именем папки '${missionName}_Layers'." `
                -Recommendation "Переименуйте каталог слоёв в '${missionName}_Layers'."))
            $layersDir = $anyLayers[0].FullName
        } else {
            $issues.Add((New-Issue -Level 'ERROR' -Category 'Structure' -File $missionDir `
                -Message "Не найден каталог слоёв '${missionName}_Layers'." `
                -Recommendation "Все слои мира должны располагаться в каталоге '${missionName}_Layers'."))
            return $issues
        }
    }

    # 3. Проверка отсутствия старых ненормализованных файлов в каталоге слоёв
    $legacyLayerNames = @('rus.layer', 'us.layer', 'log.layer', 'desc.layer', 'domiki.layer', 'friz.layer', 'default.layer', 'zone.layer')
    foreach ($leg in $legacyLayerNames) {
        $legPath = Join-Path $layersDir $leg
        if (Test-Path -LiteralPath $legPath -PathType Leaf) {
            $issues.Add((New-Issue -Level 'WARNING' -Category 'Legacy' -File $legPath `
                -Message "Обнаружен устаревший ненормализованный слой '$leg'." `
                -Recommendation "Перенесите сущности в целевые слои (_0_DESCRIPTION, _1_GAME_MODE, BLUFOR/UNITS и т.д.) и удалите старый файл."))
        }
    }

    # 4. Проверка обязательных глобальных системных слоёв
    $descLayer = Join-Path $layersDir '_0_DESCRIPTION.layer'
    $gameModeLayer = Join-Path $layersDir '_1_GAME_MODE.layer'

    if (-not (Test-Path -LiteralPath $descLayer -PathType Leaf)) {
        $issues.Add((New-Issue -Level 'WARNING' -Category 'Layers' -File $descLayer `
            -Message "Отсутствует стандартный слой брифинга '_0_DESCRIPTION.layer'." `
            -Recommendation "Создайте слой '_0_DESCRIPTION.layer' с сущностями PS_MissionDescription (_0_ABOUT, _1_RULES)."))
    } else {
        $descText = Read-FileText $descLayer
        if ($descText -notmatch '(?i)DescriptionEditableScrollable\.layout|\{B6DE04F7CF7A95DA\}') {
            $issues.Add((New-Issue -Level 'WARNING' -Category 'Briefing' -File $descLayer `
                -Message "В '_0_DESCRIPTION.layer' не используется скролл-лейаут 'DescriptionEditableScrollable.layout'." `
                -Recommendation "Задайте m_sDescriptionLayout `"{B6DE04F7CF7A95DA}UI/MissionDescription/DescriptionEditableScrollable.layout`" для поддержки скролла."))
        }
        if ($descText -notmatch 'm_iOrder\s+\d+') {
            $issues.Add((New-Issue -Level 'WARNING' -Category 'Briefing' -File $descLayer `
                -Message "В '_0_DESCRIPTION.layer' не задан параметр порядка вкладок 'm_iOrder'." `
                -Recommendation "Задайте порядковый номер вкладки m_iOrder (0 для About, 1 для Rules и т.д.)."))
        }
    }

    if (-not (Test-Path -LiteralPath $gameModeLayer -PathType Leaf)) {
        $issues.Add((New-Issue -Level 'ERROR' -Category 'Layers' -File $gameModeLayer `
            -Message "Отсутствует обязательный системный слой '_1_GAME_MODE.layer'." `
            -Recommendation "Создайте слой '_1_GAME_MODE.layer' с PS_GameModeCoop, SCR_AIWorld и PerceptionManager."))
    } else {
        $gmText = Read-FileText $gameModeLayer
        if ($gmText -notmatch '(?i)SCR_AIWorld') {
            $issues.Add((New-Issue -Level 'ERROR' -Category 'GameMode' -File $gameModeLayer `
                -Message "В '_1_GAME_MODE.layer' отсутствует сущность 'SCR_AIWorld'." `
                -Recommendation "Добавьте SCR_AIWorld : `"{E0A05C76552E7F58}Prefabs/AI/SCR_AIWorld.et`"."))
        }
        if ($gmText -notmatch '(?i)PerceptionManager') {
            $issues.Add((New-Issue -Level 'ERROR' -Category 'GameMode' -File $gameModeLayer `
                -Message "В '_1_GAME_MODE.layer' отсутствует сущность 'PerceptionManager'." `
                -Recommendation "Добавьте PerceptionManager : `"{028DAEAD63E056BE}Prefabs/World/Game/PerceptionManager.et`"."))
        }
        if ($gmText -notmatch '(?i)PS_GameModeCoop|PS_GameMode_Lobby') {
            $issues.Add((New-Issue -Level 'ERROR' -Category 'GameMode' -File $gameModeLayer `
                -Message "В '_1_GAME_MODE.layer' отсутствует игровой режим 'PS_GameModeCoop'." `
                -Recommendation "Добавьте PS_GameModeCoop : `"{9C2001FE7A2F2281}Prefabs/MP/Modes/PS_GameMode_Lobby.et`"."))
        } elseif ($gmText -match 'm_iFreezeTime\s+(\d+)') {
            $freezeMs = [int]$Matches[1]
            if ($freezeMs -ne 300000) {
                $issues.Add((New-Issue -Level 'WARNING' -Category 'GameMode' -File $gameModeLayer `
                    -Message "Параметр m_iFreezeTime равен $freezeMs мс (рекомендуется 300000 мс = 5 минут)." `
                    -Recommendation "Установите m_iFreezeTime 300000 в PS_GameModeCoop."))
            }
        } else {
            $issues.Add((New-Issue -Level 'WARNING' -Category 'GameMode' -File $gameModeLayer `
                -Message "В PS_GameModeCoop не задан параметр 'm_iFreezeTime 300000'." `
                -Recommendation "Укажите m_iFreezeTime 300000 для стандартного 5-минутного фризтайма."))
        }
    }

    # 5. Проверка слоёв фракций (BLUFOR, OPFOR, INDFOR)
    $factionDirs = @(Get-ChildItem -LiteralPath $layersDir -Directory | Where-Object { $_.Name -in @('BLUFOR', 'OPFOR', 'INDFOR') })
    $allKnownUnits = @{}
    $allVehicleAttachmentRefs = New-Object System.Collections.Generic.List[object]

    if ($factionDirs.Count -eq 0) {
        $issues.Add((New-Issue -Level 'WARNING' -Category 'Layers' -File $layersDir `
            -Message "В каталоге слоёв не найдены стандартные папки фракций ('BLUFOR', 'OPFOR', 'INDFOR')." `
            -Recommendation "Создайте подпапки фракций для изоляции слоёв сторон."))
    }

    foreach ($fDir in $factionDirs) {
        $factionName = $fDir.Name
        $unitsLayer = Join-Path $fDir.FullName 'UNITS.layer'
        $vehiclesLayer = Join-Path $fDir.FullName 'VEHICLES.layer'
        $markersLayer = Join-Path $fDir.FullName 'MARKERS.layer'
        $freezLayer = Join-Path $fDir.FullName 'FREEZ.layer'

        # --- Проверка UNITS.layer ---
        if (Test-Path -LiteralPath $unitsLayer -PathType Leaf) {
            $unitLines = @(Read-FileLines $unitsLayer)

            for ($i = 0; $i -lt $unitLines.Length; $i++) {
                $line = [string]$unitLines[$i]
                $lineNum = $i + 1

                if ($line -match '^\s*(\$grp\s+)?Vehicle\s+' -or $line -match 'Prefabs/Vehicles/') {
                    $issues.Add((New-Issue -Level 'ERROR' -Category 'UnitsLayerContamination' -File $unitsLayer -Line $lineNum `
                        -Message "В слое '$factionName/UNITS.layer' обнаружена техника (Vehicle)." `
                        -Recommendation "Перенесите всю технику в '$factionName/VEHICLES.layer'. В UNITS.layer должна быть только пехота (SCR_AIGroup)."))
                }

                if ($line -match '(?i)(E_FlagPole|Tripod|NSV|Kord|AGS|TOW|Browning|DShKM|SPG9|Mortar)') {
                    $issues.Add((New-Issue -Level 'WARNING' -Category 'UnitsLayerContamination' -File $unitsLayer -Line $lineNum `
                        -Message "В слое '$factionName/UNITS.layer' обнаружен стационарный объект/турель." `
                        -Recommendation "Станковые пулемёты, турели и статики должны размещаться в '_2_PROPS.layer' или 'DEPLOYABLE.layer'."))
                }

                if ($line -match '^\s*SCR_AIGroup\s+([A-Za-z0-9_]+)\s*:\s*"\{[0-9A-Fa-f]{16}\}') {
                    $gName = $Matches[1]
                    $allKnownUnits[$gName] = $factionName
                } elseif ($line -match '^\s*([A-Za-z0-9_]+)\s*\{' -and $line -notmatch 'components|m_aUnitPrefabSlots|coords|angles') {
                    $candidateName = $Matches[1]
                    if ($candidateName -notin @('components', 'coords', 'angles') -and $candidateName -match '^[A-Za-z0-9_]+$') {
                        $allKnownUnits[$candidateName] = $factionName
                    }
                }
            }

            foreach ($gName in $allKnownUnits.Keys) {
                if ($allKnownUnits[$gName] -ne $factionName) { continue }
                if ($gName -notmatch '^[A-Za-z]+_\d{3}(_[A-Za-z0-9]+)?$') {
                    $issues.Add((New-Issue -Level 'WARNING' -Category 'CallsignNaming' -File $unitsLayer `
                        -Message "Имя группы '$gName' не соответствует каноническому формату '<Faction>_<Callsign>' (например: USAF_010, RU_101, CDF_201)." `
                        -Recommendation "Переименуйте группу в формат '<SimpleFactionKey>_<Callsign>'."))
                }
            }
        } else {
            $issues.Add((New-Issue -Level 'WARNING' -Category 'Layers' -File $unitsLayer `
                -Message "В подпапке '$factionName' отсутствует файл 'UNITS.layer'." `
                -Recommendation "Создайте 'UNITS.layer' для размещения пехотных отделений стороны."))
        }

        # --- Проверка VEHICLES.layer ---
        if (Test-Path -LiteralPath $vehiclesLayer -PathType Leaf) {
            $vehLines = @(Read-FileLines $vehiclesLayer)
            for ($i = 0; $i -lt $vehLines.Length; $i++) {
                $line = [string]$vehLines[$i]
                $lineNum = $i + 1

                if ($line -match '^\s*(\$grp\s+)?SCR_AIGroup\s+' -or $line -match 'Prefabs/Groups/') {
                    $issues.Add((New-Issue -Level 'ERROR' -Category 'VehiclesLayerContamination' -File $vehiclesLayer -Line $lineNum `
                        -Message "В слое '$factionName/VEHICLES.layer' обнаружена пехотная группа (SCR_AIGroup)." `
                        -Recommendation "Пехотные группы должны быть строго в 'UNITS.layer'."))
                }

                if ($line -match 'm_sAttachmentGroupName\s+"([^"]*)"') {
                    $attachedGroup = $Matches[1].Trim()
                    $allVehicleAttachmentRefs.Add([pscustomobject]@{
                        Faction  = $factionName
                        File     = $vehiclesLayer
                        Line     = $lineNum
                        GroupRef = $attachedGroup
                    })
                }
            }
        }
    }

    # 6. Сквозная валидация привязки техники к пехотным группам
    foreach ($att in $allVehicleAttachmentRefs) {
        $grpRef = $att.GroupRef
        if ([string]::IsNullOrWhiteSpace($grpRef)) {
            $issues.Add((New-Issue -Level 'WARNING' -Category 'VehicleAttachment' -File $att.File -Line $att.Line `
                -Message "У техники параметр m_sAttachmentGroupName пуст (техника не закреплена за отделением)." `
                -Recommendation "Укажите имя отделения (например, 'RU_010'), чтобы в лобби слот техники отображался под отделением."))
        } elseif (-not $allKnownUnits.ContainsKey($grpRef)) {
            $issues.Add((New-Issue -Level 'ERROR' -Category 'VehicleAttachment' -File $att.File -Line $att.Line `
                -Message "Техника привязана к несуществующей группе '$grpRef' (m_sAttachmentGroupName '$grpRef' не найден в UNITS.layer)." `
                -Recommendation "Проверьте имя группы: оно должно в точности совпадать с именем отделения в UNITS.layer."))
        }
    }

    # 7. Проверка маркеров
    $markerFiles = @(Get-ChildItem -LiteralPath $layersDir -Recurse -Filter "*MARKER*.layer" -File -ErrorAction SilentlyContinue)
    foreach ($mf in $markerFiles) {
        $mLines = @(Read-FileLines $mf.FullName)
        for ($i = 0; $i -lt $mLines.Length; $i++) {
            $line = [string]$mLines[$i]
            $lineNum = $i + 1

            if ($line -match 'm_sQuadName\s+"undefined"') {
                $issues.Add((New-Issue -Level 'WARNING' -Category 'Markers' -File $mf.FullName -Line $lineNum `
                    -Message "Маркер содержит недопустимое значение m_sQuadName `"undefined`"." `
                    -Recommendation "Замените `"undefined`" на осмысленный квад: `"commander`", `"infantry`", `"recon`", `"motorized`", `"armor`" или тип техники."))
            }

            if ($line -match 'GroupFlags(Blufor|Opfor|Indfor)\.imageset') {
                $windowEnd = [Math]::Min($mLines.Length - 1, $i + 15)
                $hasGlow = $false
                for ($j = [Math]::Max(0, $i - 5); $j -le $windowEnd; $j++) {
                    if ($mLines[$j] -match 'm_sImageSetGlow\s+"\{[0-9A-Fa-f]{16}\}[^"]+-outline\.imageset"') {
                        $hasGlow = $true; break
                    }
                }
                if (-not $hasGlow) {
                    $issues.Add((New-Issue -Level 'WARNING' -Category 'Markers' -File $mf.FullName -Line $lineNum `
                        -Message "Маркер отделения не имеет контура флага (m_sImageSetGlow пуст или отсутствует)." `
                        -Recommendation "Добавьте соответствующий imageset контура: GroupFlags<Side>-outline.imageset."))
                }
            }

            if ($line -match 'm_sDescription\s+.*(#DRG-Sq-[A-Za-z0-9_-]+)') {
                $oldTag = $Matches[1]
                $issues.Add((New-Issue -Level 'WARNING' -Category 'Markers' -File $mf.FullName -Line $lineNum `
                    -Message "Маркер использует устаревший тег позывного '$oldTag'." `
                    -Recommendation "Замените устаревший тег на актуальный стандарт мода: '#PDVL_Squad_...' (например, #PDVL_Squad_PLHQ, #PDVL_Squad_Rifle)."))
            }

            if ($line -match 'm_sImageSet\s+.*PS_Atlas_x64\.imageset') {
                $windowEnd = [Math]::Min($mLines.Length - 1, $i + 25)
                $hasHideState = $false
                for ($k = $i; $k -le $windowEnd; $k++) {
                    if ($mLines[$k] -match 'm_aHideOnGameModeStates\s*\{\s*(GAME|1|\d+)') {
                        $hasHideState = $true; break
                    }
                    if ($mLines[$k] -match 'm_aHideOnGameModeStates' -and $k + 1 -le $windowEnd -and $mLines[$k + 1] -match '^\s*(GAME|1|\d+)\s*$') {
                        $hasHideState = $true; break
                    }
                    if ($k -gt $i -and ($mLines[$k] -match 'm_sImageSet\b' -or $mLines[$k] -match '^\s*(\$grp\s+)?[A-Za-z0-9_]+\s*:\s*"')) {
                        break
                    }
                }
                if (-not $hasHideState) {
                    $issues.Add((New-Issue -Level 'WARNING' -Category 'Markers' -File $mf.FullName -Line $lineNum `
                        -Message "Маркер техники не скрывается при старте игры (отсутствует 'm_aHideOnGameModeStates { GAME }')." `
                        -Recommendation "Добавьте m_aHideOnGameModeStates { GAME } (или 1), чтобы маркер техники не оставался на карте в бою."))
                }
            }
        }
    }

    return $issues
}

# ------------------------------------------------------------------ Точка входа CLI
$findings = @(Test-MissionStructure -Path $MissionPath)

$errorCount = @($findings | Where-Object { $_.Level -eq 'ERROR' }).Count
$warningCount = @($findings | Where-Object { $_.Level -eq 'WARNING' }).Count
$infoCount = @($findings | Where-Object { $_.Level -eq 'INFO' }).Count

Write-Host ''
Write-Host "=================== ПОДВАЛ TVT СТАНДАРТ: ВАЛИДАЦИЯ ===================" -ForegroundColor Cyan
Write-Host ("Миссия : {0}" -f $MissionPath) -ForegroundColor White
Write-Host ("Ошибок : {0}   Предупреждений: {1}" -f $errorCount, $warningCount) `
    -ForegroundColor $(if ($errorCount -gt 0) { 'Red' } elseif ($warningCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "----------------------------------------------------------------------" -ForegroundColor DarkGray

if ($findings.Count -eq 0) {
    Write-Host "OK: Миссия полностью соответствует стандарту PodvalTvTMissions!" -ForegroundColor Green
} else {
    foreach ($issue in $findings) {
        $prefixColor = switch ($issue.Level) {
            'ERROR'   { 'Red' }
            'WARNING' { 'Yellow' }
            default   { 'DarkGray' }
        }
        $loc = if ($issue.Line -gt 0) { " (строка $($issue.Line))" } else { "" }
        $fileName = if ($issue.File) { Split-Path -Leaf $issue.File } else { "" }
        Write-Host ("[{0}] {1}{2}: {3}" -f $issue.Level, $fileName, $loc, $issue.Message) -ForegroundColor $prefixColor
        if ($issue.Recommendation) {
            Write-Host ("   -> {0}" -f $issue.Recommendation) -ForegroundColor DarkGray
        }
    }
}
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ''

if ($ReportJson) {
    $reportObj = [pscustomobject]@{
        MissionPath   = (Resolve-Path $MissionPath).Path
        ValidatedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        ErrorsCount   = $errorCount
        WarningsCount = $warningCount
        Strict        = [bool]$Strict
        Passed        = ($errorCount -eq 0 -and (-not $Strict -or $warningCount -eq 0))
        Issues        = $findings
    }
    $jsonDir = Split-Path -Parent $ReportJson
    if ($jsonDir -and -not (Test-Path -LiteralPath $jsonDir)) { New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($ReportJson, ($reportObj | ConvertTo-Json -Depth 6), [System.Text.Encoding]::UTF8)
    Write-Host ("Отчёт сохранён: {0}" -f $ReportJson) -ForegroundColor DarkCyan
}

$isPassed = ($errorCount -eq 0 -and (-not $Strict -or $warningCount -eq 0))

if ($PassThru) {
    return [pscustomobject]@{
        Passed   = $isPassed
        Valid    = $isPassed
        Errors   = $errorCount
        Warnings = $warningCount
        Issues   = $findings
    }
}

if (-not $isPassed) {
    exit 1
} else {
    exit 0
}
