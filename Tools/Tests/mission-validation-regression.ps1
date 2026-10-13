#requires -Version 5.1
<#
.SYNOPSIS
    Регрессионные тесты валидатора стандарта миссий Test-MissionStandard.ps1
#>
$ErrorActionPreference = 'Stop'

$script:assertions = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:assertions++
}

$toolsRoot = Split-Path $PSScriptRoot -Parent
$validatorScript = Join-Path $toolsRoot 'Test-MissionStandard.ps1'

# Создание временной директории для синтетических миссий
$testSandbox = Join-Path $env:TEMP ("podval_val_test_" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testSandbox -Force | Out-Null

try {
    # ------------------------------------------------------------------ Сценарий 1: Эталонная миссия (0 ошибок, 0 варнингов)
    $compliantMissionDir = Join-Path $testSandbox 'TvT_GoodMission_Everon'
    $compliantLayersDir  = Join-Path $compliantMissionDir 'TvT_GoodMission_Everon_Layers'
    New-Item -ItemType Directory -Path (Join-Path $compliantLayersDir 'BLUFOR') -Force | Out-Null

    [System.IO.File]::WriteAllText((Join-Path $compliantMissionDir 'TvT_GoodMission_Everon.ent'), 'SubScene { }', [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $compliantMissionDir 'TvT_GoodMission_Everon.ent.meta'), 'Name "{1111111111111111}Worlds/Author/TvT_GoodMission_Everon/TvT_GoodMission_Everon.ent"', [System.Text.Encoding]::UTF8)

    # _0_DESCRIPTION.layer
    $descContent = @'
$grp PS_MissionDescription : "{3136BE42592F3B1B}PrefabsEditable/MissionDescription/EditableMissionDescription.et" {
 _0_ABOUT {
  m_sDescriptionLayout "{B6DE04F7CF7A95DA}UI/MissionDescription/DescriptionEditableScrollable.layout"
  m_iOrder 0
 }
}
'@
    [System.IO.File]::WriteAllText((Join-Path $compliantLayersDir '_0_DESCRIPTION.layer'), $descContent, [System.Text.Encoding]::UTF8)

    # _1_GAME_MODE.layer
    $gmContent = @'
SCR_AIWorld : "{E0A05C76552E7F58}Prefabs/AI/SCR_AIWorld.et" { }
PerceptionManager : "{028DAEAD63E056BE}Prefabs/World/Game/PerceptionManager.et" { }
PS_GameModeCoop : "{9C2001FE7A2F2281}Prefabs/MP/Modes/PS_GameMode_Lobby.et" {
 m_iFreezeTime 300000
}
'@
    [System.IO.File]::WriteAllText((Join-Path $compliantLayersDir '_1_GAME_MODE.layer'), $gmContent, [System.Text.Encoding]::UTF8)

    # BLUFOR/UNITS.layer
    $unitsContent = @'
$grp SCR_AIGroup : "{955623450C88D6F3}Prefabs/Groups/BLUFOR/RHS_USAF/Regular/Group_RHS_USAF_Regular_Squad.et" {
 USAF_101_AR {
  components {
   PS_GroupCallsignAssigner "{68A0FE57278C3493}" {
    m_iCompanyCallsign 1
    m_iSquadCallsign 1
   }
  }
 }
}
'@
    [System.IO.File]::WriteAllText((Join-Path $compliantLayersDir 'BLUFOR\UNITS.layer'), $unitsContent, [System.Text.Encoding]::UTF8)

    # BLUFOR/VEHICLES.layer
    $vehContent = @'
$grp Vehicle : "{3EA6F47D95867114}Prefabs/Vehicles/Wheeled/M998/M1025_armed_M2HB.et" {
 USAF_101_AR_V {
  m_sAttachmentGroupName "USAF_101_AR"
 }
}
'@
    [System.IO.File]::WriteAllText((Join-Path $compliantLayersDir 'BLUFOR\VEHICLES.layer'), $vehContent, [System.Text.Encoding]::UTF8)

    # BLUFOR/MARKERS.layer
    $markersContent = @'
$grp PS_ManualMarker : "{CD85ADE9E0F54679}PrefabsEditable/Markers/EditableMarker.et" {
 RHS_USAF_G_101_M {
  m_sImageSet "{1228936E5DB30403}UI/Textures/GroupManagement/FlagIcons/GroupFlagsBlufor.imageset"
  m_sImageSetGlow "{D1BFDF90DD7A4E01}UI/Textures/GroupManagement/FlagIcons/GroupFlagsBlufor-outline.imageset"
  m_sQuadName "infantry"
  m_sDescription "(#PDVL_Squad_Rifle) Atlas 1-1"
 }
 USAF_101_AR_V_M {
  m_sImageSet "{F3A9B47F55BE8D2B}UI/Textures/Icons/PS_Atlas_x64.imageset"
  m_sQuadName "Car"
  m_aHideOnGameModeStates { GAME }
 }
}
'@
    [System.IO.File]::WriteAllText((Join-Path $compliantLayersDir 'BLUFOR\MARKERS.layer'), $markersContent, [System.Text.Encoding]::UTF8)

    $res1 = & $validatorScript -MissionPath $compliantMissionDir -PassThru
    Assert ($res1.Passed -eq $true) "Compliant mission must pass validation."
    Assert ($res1.Errors -eq 0) "Compliant mission must have 0 errors."
    Assert ($res1.Warnings -eq 0) "Compliant mission must have 0 warnings."

    # ------------------------------------------------------------------ Сценарий 2: Нарушение именования и структуры
    $badNameDir = Join-Path $testSandbox 'OldMission'
    New-Item -ItemType Directory -Path $badNameDir -Force | Out-Null
    $res2 = & $validatorScript -MissionPath $badNameDir -PassThru
    Assert ($res2.Warnings -gt 0) "Non-TvT name triggers a warning."
    $hasNamingWarn = [bool](@($res2.Issues | Where-Object { $_.Category -eq 'Naming' }).Count)
    Assert $hasNamingWarn "Warning category is Naming."

    # ------------------------------------------------------------------ Сценарий 3: Техника в UNITS.layer (засорение)
    $contamMissionDir = Join-Path $testSandbox 'TvT_Contam_Everon'
    $contamLayersDir  = Join-Path $contamMissionDir 'TvT_Contam_Everon_Layers'
    New-Item -ItemType Directory -Path (Join-Path $contamLayersDir 'BLUFOR') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $contamMissionDir 'TvT_Contam_Everon.ent'), 'SubScene { }', [System.Text.Encoding]::UTF8)

    $badUnitsContent = @'
Vehicle BTR70 : "{1234567812345678}Prefabs/Vehicles/Wheeled/BTR70/BTR70.et" { }
'@
    [System.IO.File]::WriteAllText((Join-Path $contamLayersDir 'BLUFOR\UNITS.layer'), $badUnitsContent, [System.Text.Encoding]::UTF8)
    $res3 = & $validatorScript -MissionPath $contamMissionDir -PassThru
    $hasContamError = [bool](@($res3.Issues | Where-Object { $_.Category -eq 'UnitsLayerContamination' -and $_.Level -eq 'ERROR' }).Count)
    Assert $hasContamError "Vehicle in UNITS.layer triggers UnitsLayerContamination ERROR."
    Assert ($res3.Passed -eq $false) "Mission with contamination fails validation."

    # ------------------------------------------------------------------ Сценарий 4: Пехота в VEHICLES.layer
    $badVehContent = @'
SCR_AIGroup BadSquad : "{955623450C88D6F3}Prefabs/Groups/Group_RHS_USAF.et" { }
'@
    [System.IO.File]::WriteAllText((Join-Path $contamLayersDir 'BLUFOR\VEHICLES.layer'), $badVehContent, [System.Text.Encoding]::UTF8)
    $res4 = & $validatorScript -MissionPath $contamMissionDir -PassThru
    $hasVehContam = [bool](@($res4.Issues | Where-Object { $_.Category -eq 'VehiclesLayerContamination' -and $_.Level -eq 'ERROR' }).Count)
    Assert $hasVehContam "SCR_AIGroup in VEHICLES.layer triggers VehiclesLayerContamination ERROR."

    # ------------------------------------------------------------------ Сценарий 5: Битая привязка техники (m_sAttachmentGroupName)
    $brokenAttachContent = @'
$grp Vehicle : "{3EA6F47D95867114}Prefabs/Vehicles/M1025.et" {
 M1025_1 {
  m_sAttachmentGroupName "GHOST_SQUAD_404"
 }
}
'@
    [System.IO.File]::WriteAllText((Join-Path $contamLayersDir 'BLUFOR\VEHICLES.layer'), $brokenAttachContent, [System.Text.Encoding]::UTF8)
    $res5 = & $validatorScript -MissionPath $contamMissionDir -PassThru
    $hasAttachError = [bool](@($res5.Issues | Where-Object { $_.Category -eq 'VehicleAttachment' -and $_.Level -eq 'ERROR' }).Count)
    Assert $hasAttachError "Non-existent attachment group triggers VehicleAttachment ERROR."

    # ------------------------------------------------------------------ Сценарий 6: Маркеры с undefined и устаревшим #DRG-Sq-
    $badMarkersContent = @'
$grp PS_ManualMarker : "{CD85ADE9E0F54679}PrefabsEditable/Markers/EditableMarker.et" {
 Marker1 {
  m_sImageSet "{1228936E5DB30403}UI/Textures/GroupManagement/FlagIcons/GroupFlagsBlufor.imageset"
  m_sImageSetGlow ""
  m_sQuadName "undefined"
  m_sDescription "(#DRG-Sq-PlatoonHQ) HQ"
 }
}
'@
    [System.IO.File]::WriteAllText((Join-Path $contamLayersDir 'BLUFOR\MARKERS.layer'), $badMarkersContent, [System.Text.Encoding]::UTF8)
    $res6 = & $validatorScript -MissionPath $contamMissionDir -PassThru
    $hasUndefQuad = [bool](@($res6.Issues | Where-Object { $_.Message -like '*m_sQuadName "undefined"*' }).Count)
    $hasNoGlow    = [bool](@($res6.Issues | Where-Object { $_.Message -like '*не имеет контура флага*' }).Count)
    $hasOldTag    = [bool](@($res6.Issues | Where-Object { $_.Message -like '*#DRG-Sq-*' }).Count)
    Assert $hasUndefQuad "Marker with undefined quad triggers a warning."
    Assert $hasNoGlow "Squad marker without glow triggers a warning."
    Assert $hasOldTag "Legacy #DRG-Sq- tag triggers a warning."

    # ------------------------------------------------------------------ Сценарий 7: Режимы Strict vs Default
    $onlyWarnMission = Join-Path $testSandbox 'TvT_OnlyWarn_Everon'
    $onlyWarnLayers  = Join-Path $onlyWarnMission 'TvT_OnlyWarn_Everon_Layers'
    New-Item -ItemType Directory -Path (Join-Path $onlyWarnLayers 'BLUFOR') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $onlyWarnMission 'TvT_OnlyWarn_Everon.ent'), 'SubScene { }', [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $onlyWarnLayers '_1_GAME_MODE.layer'), $gmContent, [System.Text.Encoding]::UTF8)
    $warnUnits = @'
SCR_AIGroup custom_team : "{955623450C88D6F3}Prefabs/Groups/Group.et" { }
'@
    [System.IO.File]::WriteAllText((Join-Path $onlyWarnLayers 'BLUFOR\UNITS.layer'), $warnUnits, [System.Text.Encoding]::UTF8)

    $defaultRes = & $validatorScript -MissionPath $onlyWarnMission -PassThru
    Assert ($defaultRes.Errors -eq 0) "OnlyWarn mission has 0 errors."
    Assert ($defaultRes.Warnings -gt 0) "OnlyWarn mission has warnings."
    Assert ($defaultRes.Passed -eq $true) "Default mode passes when only warnings are present."

    $strictRes = & $validatorScript -MissionPath $onlyWarnMission -Strict -PassThru
    Assert ($strictRes.Passed -eq $false) "Strict mode fails when warnings are present."

    # ------------------------------------------------------------------ Сценарий 8: Экспорт в JSON
    $jsonReportPath = Join-Path $testSandbox 'report.json'
    & $validatorScript -MissionPath $onlyWarnMission -ReportJson $jsonReportPath -PassThru | Out-Null
    Assert (Test-Path -LiteralPath $jsonReportPath) "JSON report was created."
    $parsedJson = Get-Content -LiteralPath $jsonReportPath -Raw | ConvertFrom-Json
    Assert ($parsedJson.WarningsCount -eq $defaultRes.Warnings) "JSON report reflects warnings count."
    Assert ($parsedJson.Issues.Count -gt 0) "JSON report contains issues list."

} finally {
    Remove-Item -LiteralPath $testSandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PASS mission-validation-regression: $script:assertions assertions" -ForegroundColor Green
