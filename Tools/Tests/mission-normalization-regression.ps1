#requires -Version 5.1
<#
.SYNOPSIS
    Регрессионные тесты автоматической нормализации миссий Normalize-MissionLayers.ps1
#>
$ErrorActionPreference = 'Stop'

$script:assertions = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:assertions++
}

$toolsRoot = Split-Path $PSScriptRoot -Parent
$normalizerScript = Join-Path $toolsRoot 'Normalize-MissionLayers.ps1'
$validatorScript  = Join-Path $toolsRoot 'Test-MissionStandard.ps1'

# Создание временной директории для синтетических тестов
$testSandbox = Join-Path $env:TEMP ("podval_norm_test_" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testSandbox -Force | Out-Null

try {
    # ------------------------------------------------------------------ Сценарий 1: Полная нормализация legacy DRG миссии
    $legacyMissionDir = Join-Path $testSandbox 'Zavod_Zarichne'
    $legacyLayersDir  = Join-Path $legacyMissionDir 'Zavod_Zarichne_Layers'
    New-Item -ItemType Directory -Path $legacyLayersDir -Force | Out-Null

    [System.IO.File]::WriteAllText((Join-Path $legacyMissionDir 'Zavod_Zarichne.ent'), 'SubScene { }', [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $legacyMissionDir 'Zavod_Zarichne.ent.meta'), 'Name "{1111111111111111}Worlds/Author/Zavod_Zarichne/Zavod_Zarichne.ent"', [System.Text.Encoding]::UTF8)

    # desc.layer (устаревший брифинг)
    $legacyDesc = @'
$grp PS_MissionDescription : "{3136BE42592F3B1B}PrefabsEditable/MissionDescription/EditableMissionDescription.et" {
 _0_ABOUT {
  m_sDescriptionLayout "{OldLayout}UI/Old.layout"
  m_iOrder 0
 }
}
'@
    [System.IO.File]::WriteAllText((Join-Path $legacyLayersDir 'desc.layer'), $legacyDesc, [System.Text.Encoding]::UTF8)

    # default.layer (гейммод)
    $legacyDefault = @'
SCR_AIWorld : "{E0A05C76552E7F58}Prefabs/AI/SCR_AIWorld.et" { }
PerceptionManager : "{028DAEAD63E056BE}Prefabs/World/Game/PerceptionManager.et" { }
PS_GameModeCoop : "{9C2001FE7A2F2281}Prefabs/MP/Modes/PS_GameMode_Lobby.et" {
 m_iFreezeTime 120000
}
'@
    [System.IO.File]::WriteAllText((Join-Path $legacyLayersDir 'default.layer'), $legacyDefault, [System.Text.Encoding]::UTF8)

    # rus.layer (смесь техники, пехоты и стационарных орудий)
    $legacyRus = @'
$grp Vehicle : "{3EA6F47D95867114}Prefabs/Vehicles/Wheeled/BTR70/BTR70.et" {
 BTR70_1 {
  coords 5000 100 5000
  m_sAttachmentGroupName "bb"
 }
}
$grp SCR_AIGroup : "{955623450C88D6F3}Prefabs/Groups/OPFOR/RHS_AFRF/Group_RHS_AFRF_Squad.et" {
 bb {
  components {
   PS_GroupCallsignAssigner "{68A0FE57278C3493}" {
    m_iCompanyCallsign 2
    m_iPlatoonCallsign 1
   }
  }
  coords 5010 100 5005
 }
}
Vehicle Tripod_Kord : "{F5EF4223ACA6169C}Prefabs/Props/Kord_Tripod.et" {
 coords 5020 100 5010
}
'@
    [System.IO.File]::WriteAllText((Join-Path $legacyLayersDir 'rus.layer'), $legacyRus, [System.Text.Encoding]::UTF8)

    # us.layer (пехота и техника США)
    $legacyUs = @'
$grp Vehicle : "{3EA6F47D95867114}Prefabs/Vehicles/Wheeled/M998/M1025.et" {
 Humvee_1 {
  coords 1000 50 1000
  m_sAttachmentGroupName "squad_us"
 }
}
$grp SCR_AIGroup : "{955623450C88D6F3}Prefabs/Groups/BLUFOR/RHS_USAF/Regular/Group_RHS_USAF_Regular_Squad.et" {
 squad_us {
  components {
   PS_GroupCallsignAssigner "{68A0FE57278C3493}" {
    m_iCompanyCallsign 0
    m_iPlatoonCallsign 1
   }
  }
  coords 1005 50 1005
 }
}
'@
    [System.IO.File]::WriteAllText((Join-Path $legacyLayersDir 'us.layer'), $legacyUs, [System.Text.Encoding]::UTF8)

    # rus_markers.layer (устаревшие маркеры с undefined и #DRG-Sq-)
    $legacyMarkers = @'
$grp PS_ManualMarker : "{CD85ADE9E0F54679}PrefabsEditable/Markers/EditableMarker.et" {
 Marker_Rus {
  m_sImageSet "{7CD99D22C7AE8195}UI/Textures/GroupManagement/FlagIcons/GroupFlagsOpfor.imageset"
  m_sQuadName "undefined"
  m_sDescription "(#DRG-Sq-PlatoonHQ) HQ"
 }
 Marker_Veh {
  m_sImageSet "{F3A9B47F55BE8D2B}UI/Textures/Icons/PS_Atlas_x64.imageset"
  m_sQuadName "Car"
 }
}
'@
    [System.IO.File]::WriteAllText((Join-Path $legacyLayersDir 'rus_markers.layer'), $legacyMarkers, [System.Text.Encoding]::UTF8)

    # friz.layer (зоны фризтайма)
    $legacyFriz = @'
SCR_EditorRestrictionZoneEntity Freez_Rus : "{6144B0BE2EAC6897}Prefabs/RestrictionZone.et" {
 coords 5010 100 5005
}
SCR_EditorRestrictionZoneEntity Freez_US : "{6144B0BE2EAC6897}Prefabs/RestrictionZone.et" {
 coords 1005 50 1005
}
'@
    [System.IO.File]::WriteAllText((Join-Path $legacyLayersDir 'friz.layer'), $legacyFriz, [System.Text.Encoding]::UTF8)

    # Запуск нормализации
    $res1 = & $normalizerScript -MissionPath $legacyMissionDir -PassThru
    Assert ($res1.Renamed -eq $true) "Mission was renamed to canonical TvT_<Name>_<Map>."
    Assert ($res1.TargetName -eq 'TvT_Zavod_Zarichne') "Target name is TvT_Zavod_Zarichne."
    Assert ($res1.GroupsRenamed -ge 2) "Both squads were renamed to canonical callsigns."
    Assert ($res1.VehiclesAttached -ge 2) "Both vehicles were attached to squads."
    Assert ($res1.LayersCleaned.Count -ge 4) "Old layer files were cleaned up."

    # Проверка структуры файлов
    $targetDir = Join-Path $testSandbox 'TvT_Zavod_Zarichne'
    Assert (Test-Path -LiteralPath $targetDir) "Target mission directory exists."
    Assert (Test-Path -LiteralPath (Join-Path $targetDir 'TvT_Zavod_Zarichne.ent')) "Canonical .ent exists."
    Assert (Test-Path -LiteralPath (Join-Path $targetDir 'TvT_Zavod_Zarichne.ent.meta')) "Canonical .ent.meta exists."

    $targetLayers = Join-Path $targetDir 'TvT_Zavod_Zarichne_Layers'
    Assert (Test-Path -LiteralPath (Join-Path $targetLayers '_0_DESCRIPTION.layer')) "_0_DESCRIPTION.layer exists."
    Assert (Test-Path -LiteralPath (Join-Path $targetLayers '_1_GAME_MODE.layer')) "_1_GAME_MODE.layer exists."
    Assert (Test-Path -LiteralPath (Join-Path $targetLayers '_2_PROPS.layer')) "_2_PROPS.layer exists (tripod moved)."
    Assert (Test-Path -LiteralPath (Join-Path $targetLayers 'OPFOR\UNITS.layer')) "OPFOR\UNITS.layer exists."
    Assert (Test-Path -LiteralPath (Join-Path $targetLayers 'OPFOR\VEHICLES.layer')) "OPFOR\VEHICLES.layer exists."
    Assert (Test-Path -LiteralPath (Join-Path $targetLayers 'OPFOR\MARKERS.layer')) "OPFOR\MARKERS.layer exists."
    Assert (Test-Path -LiteralPath (Join-Path $targetLayers 'OPFOR\FREEZ.layer')) "OPFOR\FREEZ.layer exists."
    Assert (Test-Path -LiteralPath (Join-Path $targetLayers 'BLUFOR\UNITS.layer')) "BLUFOR\UNITS.layer exists."
    Assert (Test-Path -LiteralPath (Join-Path $targetLayers 'BLUFOR\VEHICLES.layer')) "BLUFOR\VEHICLES.layer exists."
    Assert (Test-Path -LiteralPath (Join-Path $targetLayers 'BLUFOR\FREEZ.layer')) "BLUFOR\FREEZ.layer exists."

    # Проверка отсутствия старых файлов
    Assert (-not (Test-Path -LiteralPath (Join-Path $targetLayers 'rus.layer'))) "rus.layer was removed."
    Assert (-not (Test-Path -LiteralPath (Join-Path $targetLayers 'us.layer'))) "us.layer was removed."
    Assert (-not (Test-Path -LiteralPath (Join-Path $targetLayers 'friz.layer'))) "friz.layer was removed."

    # Проверка содержимого UNITS и VEHICLES
    $opforUnitsText = [System.IO.File]::ReadAllText((Join-Path $targetLayers 'OPFOR\UNITS.layer'), [System.Text.Encoding]::UTF8)
    Assert ($opforUnitsText -match 'RU_210\s*\{') "Squad bb was renamed to RU_210."
    Assert ($opforUnitsText -notmatch 'Vehicle') "UNITS.layer contains no Vehicle."
    Assert ($opforUnitsText -notmatch 'Tripod') "UNITS.layer contains no static tripod."

    $opforVehText = [System.IO.File]::ReadAllText((Join-Path $targetLayers 'OPFOR\VEHICLES.layer'), [System.Text.Encoding]::UTF8)
    Assert ($opforVehText -match 'm_sAttachmentGroupName\s+"RU_210"') "BTR70 attached to RU_210."
    Assert ($opforVehText -match 'RU_210_V') "BTR70 renamed to RU_210_V."

    $opforMarkersText = [System.IO.File]::ReadAllText((Join-Path $targetLayers 'OPFOR\MARKERS.layer'), [System.Text.Encoding]::UTF8)
    Assert ($opforMarkersText -notmatch 'm_sQuadName "undefined"') "m_sQuadName undefined was fixed."
    Assert ($opforMarkersText -match 'GroupFlagsOpfor-outline\.imageset') "Glow outline was added."
    Assert ($opforMarkersText -match '#PDVL_Squad_') "#DRG-Sq- was remapped to #PDVL_Squad_."
    Assert ($opforMarkersText -match 'm_aHideOnGameModeStates') "Vehicle marker hidden in game."

    $gmText = [System.IO.File]::ReadAllText((Join-Path $targetLayers '_1_GAME_MODE.layer'), [System.Text.Encoding]::UTF8)
    Assert ($gmText -match 'm_iFreezeTime 300000') "Freeze time normalized to 300000 ms."

    $descText = [System.IO.File]::ReadAllText((Join-Path $targetLayers '_0_DESCRIPTION.layer'), [System.Text.Encoding]::UTF8)
    Assert ($descText -match 'DescriptionEditableScrollable\.layout') "Description scroll layout updated."

    # Проверка через валидатор Test-MissionStandard.ps1: 0 ошибок!
    $val = & $validatorScript -MissionPath $targetDir -PassThru
    Assert ($val.Errors -eq 0) "Validator reports 0 errors on normalized mission."
    Assert ($val.Passed -eq $true) "Normalized mission passes validation."

    # ------------------------------------------------------------------ Сценарий 2: Идемпотентность (повторный запуск)
    $res2 = & $normalizerScript -MissionPath $targetDir -PassThru
    Assert ($res2.Renamed -eq $false) "Already normalized mission is not renamed again."
    $val2 = & $validatorScript -MissionPath $targetDir -PassThru
    Assert ($val2.Errors -eq 0) "Idempotent re-run preserves 0 errors."

    # ------------------------------------------------------------------ Сценарий 3: DryRun режим
    $dryMissionDir = Join-Path $testSandbox 'DryMission_Everon'
    New-Item -ItemType Directory -Path $dryMissionDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dryMissionDir 'DryMission_Everon.ent'), 'SubScene { }', [System.Text.Encoding]::UTF8)
    $dryLayers = Join-Path $dryMissionDir 'DryMission_Everon_Layers'
    New-Item -ItemType Directory -Path $dryLayers -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dryLayers 'rus.layer'), $legacyRus, [System.Text.Encoding]::UTF8)

    & $normalizerScript -MissionPath $dryMissionDir -DryRun | Out-Null
    Assert (Test-Path -LiteralPath (Join-Path $dryLayers 'rus.layer')) "DryRun did not remove rus.layer."
    Assert (-not (Test-Path -LiteralPath (Join-Path $dryLayers 'OPFOR\UNITS.layer'))) "DryRun did not write OPFOR\UNITS.layer."

} finally {
    Remove-Item -LiteralPath $testSandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PASS mission-normalization-regression: $script:assertions assertions" -ForegroundColor Green
