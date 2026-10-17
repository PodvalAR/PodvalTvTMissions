#requires -Version 5.1
<#
.SYNOPSIS
    Ручная проверка первого запуска инструмента восстановления миссий.

.DESCRIPTION
    Полностью изолированная проверка. Скрипт копирует Tools во временный каталог без
    локального файла настроек, запускает сервер в фоновом задании, прогоняет HTTP-сценарии
    и останавливает всё. Рабочая копия репозитория не изменяется.

    Сценарии:
      1. Первый запуск без настроек: сервер поднимается и честно сообщает, что не настроен.
      2. Подсказки работают по сохранённому каталогу, когда мод префабов недоступен.
      3. Операция, которой нужен мод префабов, отказывает с actionable-сообщением.
      4. Таблица замен читается и проверяется по снимку каталога.
      5. Некорректный путь отклоняется, файл настроек не создаётся.
      6. Корректные настройки сохраняются и немедленно вступают в силу.
      7. Настройки переживают перезапуск.
      8. Занятый порт не фатален: сервер подбирает свободный.

    В отличие от Run-Regression.ps1, проверка не входит в автоматический прогон: ей нужен
    настоящий мод префабов, свободный диапазон портов и около минуты времени. Запускайте
    её вручную перед тем, как отдать инструмент другому оператору.

.PARAMETER Port
    Базовый порт для проверки. Занятый порт - часть сценария 8, поэтому его нужно
    только избегать при параллельных запусках.

.PARAMETER PrefabsModRoot
    Корень мода префабов. Если не задан, ищется соседний репозиторий PodvalTvTPrefabs.

.PARAMETER AddonRoot
    Корень аддона с .gproj. Если не задан, определяется автоматически, как это делает
    сам инструмент.

.PARAMETER KeepCopy
    Не удалять временную копию Tools после проверки (для разбора).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\firstrun-verification.ps1
#>
[CmdletBinding()]
param(
    [int]$Port = 8911,
    [string]$PrefabsModRoot,
    [string]$AddonRoot,
    [switch]$KeepCopy
)

$ErrorActionPreference = 'Stop'

$toolsRoot  = Split-Path -Parent $PSScriptRoot
$repoRoot   = Split-Path -Parent $toolsRoot

# ------------------------------------------------------------------ входные пути
function Resolve-AddonRoot([string]$Repo) {
    $hits = @(Get-ChildItem -LiteralPath $Repo -Recurse -Depth 2 -File -Filter *.gproj -ErrorAction SilentlyContinue |
              Select-Object -ExpandProperty DirectoryName -Unique)
    if ($hits.Count -eq 1) { return $hits[0] }
    if ($hits.Count -gt 1) { throw ("Найдено несколько .gproj ({0}). Укажите корень аддона параметром -AddonRoot." -f ($hits -join ', ')) }
    throw "Не удалось определить корень аддона: в репозитории нет .gproj. Укажите его параметром -AddonRoot."
}
function Resolve-PrefabsRoot([string]$Repo, [string]$Explicit) {
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Container)) { throw "Каталог мода префабов не найден: $Explicit" }
        return $Explicit
    }
    $sibling = Join-Path (Split-Path -Parent $Repo) 'PodvalTvTPrefabs\PodvalTvTPrefabs'
    if (Test-Path -LiteralPath $sibling -PathType Container) { return $sibling }
    throw ("Не удалось определить мод префабов: ожидался соседний репозиторий {0}. " +
           "Укажите его параметром -PrefabsModRoot." -f $sibling)
}

if (-not $AddonRoot)     { $AddonRoot = Resolve-AddonRoot $repoRoot }
if (-not $PrefabsModRoot) { $PrefabsModRoot = Resolve-PrefabsRoot $repoRoot $PrefabsModRoot }

# ------------------------------------------------------------------ изолированная копия
$copyRoot = Join-Path $env:TEMP ('podval-firstrun-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
Copy-Item -LiteralPath $toolsRoot -Destination (Join-Path $copyRoot 'Tools') -Recurse -Force
# Свежая машина: ни локального конфига, ни устаревшего файла настроек в UI.
foreach ($stale in @('Tools\tool.config.json', 'Tools\tool.config.json.bak', 'Tools\UI\ui.config.json')) {
    Remove-Item -LiteralPath (Join-Path $copyRoot $stale) -Force -ErrorAction SilentlyContinue
}
$serverScript = Join-Path $copyRoot 'Tools\UI\Serve-RestoreUI.ps1'

Write-Host ("Копия инструмента : {0}" -f $copyRoot)
Write-Host ("Корень аддона     : {0}" -f $AddonRoot)
Write-Host ("Мод префабов      : {0}" -f $PrefabsModRoot)
Write-Host ("Базовый порт      : {0}" -f $Port)
Write-Host ''

# ------------------------------------------------------------------ помощники
function Start-Server([string]$Script, [int]$ServerPort) {
    # Write-Host из фонового задания не попадает в поток вывода, поэтому баннер сервера
    # недоступен проверке. Признак готовности - ответ /api/config по HTTP.
    return Start-Job -ScriptBlock { param($s, $p) & $s -NoBrowser -Port $p } -ArgumentList $Script, $ServerPort
}
function Wait-Server([int]$ServerPort, [int]$Attempts = 40) {
    for ($i = 0; $i -lt $Attempts; $i++) {
        Start-Sleep -Milliseconds 500
        try { return Invoke-RestMethod -Uri "http://localhost:$ServerPort/api/config" -TimeoutSec 2 } catch { }
    }
    return $null
}
function Invoke-Post([int]$ServerPort, [string]$Path, [string]$Body, [string]$Token) {
    return Invoke-RestMethod -Uri "http://localhost:$ServerPort$Path" -Method Post -ContentType 'application/json' -Headers @{ 'X-Restore-Token' = $Token } -Body $Body
}
function Get-ApiError($Record) {
    try { return [string](($Record.ErrorDetails.Message | ConvertFrom-Json).error) } catch { return $Record.Exception.Message }
}

$job = Start-Server $serverScript $Port
try {
    $cfg = Wait-Server $Port
    if (-not $cfg) { Write-Host 'СЕРВЕР НЕ ЗАПУСТИЛСЯ'; Receive-Job $job | ForEach-Object { Write-Host "  $_" }; exit 1 }
    if ($null -eq $cfg.pathsConfigured) { throw "Порт $Port занят посторонним приложением: ответ не похож на /api/config инструмента." }

    Write-Host '=== 1. Первый запуск без локального файла настроек ==='
    Write-Host ("  pathsConfigured   : {0}" -f $cfg.pathsConfigured)
    Write-Host ("  missingSettings   : {0}" -f ($cfg.missingSettings -join ', '))
    Write-Host ("  addonRoot (авто)  : '{0}'" -f $cfg.addonRoot)
    Write-Host ("  prefabsModRoot    : '{0}'" -f $cfg.prefabsModRoot)
    Write-Host ("  prefabsAvailable  : {0}" -f $cfg.prefabsAvailable)
    Write-Host ("  modIndexCount     : {0}" -f $cfg.modIndexCount)
    Write-Host ("  userConfig        : {0}" -f $cfg.userConfig)
    Write-Host ("  aiKeyEnv          : {0}" -f $cfg.aiKeyEnv)
    if ($cfg.csrfToken -notmatch '^[0-9a-f]{64}$') { throw 'В ответе /api/config нет CSRF-токена.' }
    if ($cfg.pathsConfigured) { throw 'Свежая копия не должна считаться настроенной.' }

    Write-Host ''
    Write-Host '=== 2. Подсказки работают по сохранённому каталогу (мода префабов нет) ==='
    $body = @{ path = '{1111111111111111}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/drg_Role_RHS_USAF_SL.et'; top = 3 } | ConvertTo-Json
    $sug = @(Invoke-Post $Port '/api/suggest' $body $cfg.csrfToken)
    Write-Host ("  кандидатов: {0}" -f $sug.Count)
    Write-Host ("  первый   : {0}" -f $sug[0].Path)
    if ($sug.Count -eq 0) { throw 'Без мода префабов подсказки должны строиться по снимку каталога.' }

    Write-Host ''
    Write-Host '=== 3. Операция, которой нужен мод префабов, отказывает понятно ==='
    $refused = $false
    try { $null = Invoke-Post $Port '/api/scan' '{"sourceDir":"C:\\does\\not\\exist"}' $cfg.csrfToken }
    catch {
        $detail = Get-ApiError $_
        Write-Host ("  отказ: {0}" -f $detail)
        if ($detail -notmatch 'PrefabsModRoot') { throw 'В отказе не названа настройка, которую надо заполнить.' }
        $refused = $true
    }
    if (-not $refused) { throw 'Сканирование прошло без мода префабов, хотя не должно было.' }

    Write-Host ''
    Write-Host '=== 4. Таблица замен читается и проверяется по снимку каталога ==='
    $table = Invoke-RestMethod -Uri "http://localhost:$Port/api/table"
    Write-Host ("  записей={0}  источник={1}  живой={2}" -f @($table.entries).Count, $table.modIndexSource, $table.modIndexLive)
    if ($table.modIndexSource -ne 'catalog' -or $table.modIndexLive) { throw 'Таблица должна проверяться по снимку каталога и честно это показывать.' }

    Write-Host ''
    Write-Host '=== 5. Некорректный путь отклоняется и ничего не записывает ==='
    $rejected = $false
    try { $null = Invoke-Post $Port '/api/settings' (@{ prefabsModRoot = 'C:\definitely\not\here' } | ConvertTo-Json) $cfg.csrfToken }
    catch {
        Write-Host ("  отказ: {0}" -f (Get-ApiError $_))
        $rejected = $true
    }
    if (-not $rejected) { throw 'Некорректный путь был принят.' }
    if (Test-Path -LiteralPath (Join-Path $copyRoot 'Tools\tool.config.json')) { throw 'Отклонённое сохранение всё же создало файл настроек.' }

    Write-Host ''
    Write-Host '=== 6. Корректные настройки сохраняются и вступают в силу ==='
    $good = @{ prefabsModRoot = $PrefabsModRoot; addonRoot = $AddonRoot; port = "$Port" } | ConvertTo-Json
    $ok = Invoke-Post $Port '/api/settings' $good $cfg.csrfToken
    Write-Host ("  сохранено в: {0}" -f $ok.path)
    $cfg2 = Invoke-RestMethod -Uri "http://localhost:$Port/api/config"
    Write-Host ("  prefabsAvailable: {0}   modIndexCount: {1}   pathsConfigured: {2}" -f $cfg2.prefabsAvailable, $cfg2.modIndexCount, $cfg2.pathsConfigured)
    if (-not $cfg2.pathsConfigured) { throw 'Полная настройка всё ещё считается незавершённой.' }
    if ($cfg2.modIndexCount -le 0) { throw 'Корректный корень мода префабов не дал ни одного префаба.' }
    $table2 = Invoke-RestMethod -Uri "http://localhost:$Port/api/table"
    Write-Host ("  таблица теперь проверяется по: {0} (живой={1})" -f $table2.modIndexSource, $table2.modIndexLive)
    if ($table2.modIndexSource -ne 'mod' -or -not $table2.modIndexLive) { throw 'После настройки таблица должна проверяться по живому моду.' }

    Write-Host ''
    Write-Host '=== 7. Настройки переживают перезапуск ==='
    $null = Invoke-Post $Port '/api/shutdown' '{}' $cfg.csrfToken
    Start-Sleep -Seconds 2
    Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue

    $job = Start-Server $serverScript $Port
    $cfg3 = Wait-Server $Port
    if (-not $cfg3) { throw 'После перезапуска сервер не поднялся.' }
    Write-Host ("  prefabsModRoot   : {0}" -f $cfg3.prefabsModRoot)
    Write-Host ("  modIndexCount    : {0}" -f $cfg3.modIndexCount)
    Write-Host ("  prefabsAvailable : {0}" -f $cfg3.prefabsAvailable)
    if ($cfg3.modIndexCount -le 0) { throw 'Сохранённый корень мода префабов не применился после перезапуска.' }
    if (-not $cfg3.pathsConfigured) { throw 'После перезапуска инструмент снова считается ненастроенным.' }

    Write-Host ''
    Write-Host '=== 8. Занятый порт не фатален, подбирается свободный ==='
    # Порт держит и перезапущенный сервер из шага 7; явный блокер делает намерение проверки
    # читаемым и страхует случай, если основной сервер уже завершился.
    $blocker = Start-Job -ScriptBlock {
        param($p)
        $l = [System.Net.HttpListener]::new(); $l.Prefixes.Add("http://localhost:$p/"); $l.Start(); Start-Sleep -Seconds 25
    } -ArgumentList $Port
    Start-Sleep -Seconds 3
    $job4 = Start-Server $serverScript $Port
    $fellBack = $false
    for ($i = 0; $i -lt 40 -and -not $fellBack; $i++) {
        Start-Sleep -Milliseconds 500
        foreach ($candidate in (($Port + 1)..($Port + 9))) {
            try { $c = Invoke-RestMethod -Uri "http://localhost:$candidate/api/config" -TimeoutSec 2 } catch { continue }
            Write-Host ("  порт {0} занят -> сервер ответил на {1}" -f $Port, $candidate)
            Write-Host ("  резервный порт отвечает, modIndexCount={0}" -f $c.modIndexCount)
            if ($c.modIndexCount -le 0) { throw 'Резервный сервер поднялся без индекса префабов.' }
            $null = Invoke-Post $candidate '/api/shutdown' '{}' $c.csrfToken
            $fellBack = $true
            break
        }
    }
    Stop-Job $job4 -ErrorAction SilentlyContinue; Remove-Job $job4 -Force -ErrorAction SilentlyContinue
    Stop-Job $blocker -ErrorAction SilentlyContinue; Remove-Job $blocker -Force -ErrorAction SilentlyContinue
    if (-not $fellBack) { throw 'Сервер не подобрал свободный порт.' }

    Write-Host ''
    Write-Host 'ПРОВЕРКА ПЕРВОГО ЗАПУСКА ПРОЙДЕНА'
}
finally {
    foreach ($pending in @(Get-Job)) {
        if ($pending.State -eq 'Running') { Stop-Job $pending -ErrorAction SilentlyContinue }
        Remove-Job $pending -Force -ErrorAction SilentlyContinue
    }
    if ($KeepCopy) { Write-Host ("Временная копия сохранена: {0}" -f $copyRoot) }
    else { Remove-Item -LiteralPath $copyRoot -Recurse -Force -ErrorAction SilentlyContinue }
}