#requires -Version 5.1
<#
.SYNOPSIS
    Local web backend for the mission-restore tool. Pure PowerShell + built-in
    System.Net.HttpListener (no extra runtime/module to install). Binds to loopback
    only. Browser POST requests require a per-run token and a matching origin.

.DESCRIPTION
    Serves index.html and a small JSON API over Restore-Core.ps1. Start via
    Start-RestoreUI.bat (or run this directly) then open http://localhost:<port>/.

    AI assist calls the justwoker endpoint using an API key read ONLY from an env var
    (JUSTWOKER_API_KEY by default). The key is never written to disk or logged.
#>
[CmdletBinding()]
param(
    [int]$Port,
    [string]$ConfigPath,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path (Split-Path $ScriptDir -Parent) 'Restore-Core.ps1')

# ------------------------------------------------------------------ config
# Paths are machine-specific and come from the local, git-ignored tool config. The
# server-specific keys keep their built-in defaults and are overridden by the same file.
$cfg = @{
    Port           = 8787
    ApiKeyEnv      = 'JUSTWOKER_API_KEY'
    AiBaseUrl      = 'https://api.justwoker.icu/v1'
    AiModel        = 'claude-opus-4-8'
}
if ($Port) { $cfg.Port = $Port }
if ($ConfigPath) {
    $cfgImport = Import-RMUserConfig -Path $ConfigPath
} else {
    # Precedence: Tools\tool.config.json, then the legacy Tools\UI\ui.config.json.
    $cfgImport = Import-RMUserConfig
}
foreach ($w in $cfgImport.Warnings) { Write-Host "Настройки: $w" -ForegroundColor DarkYellow }
foreach ($key in @('ApiKeyEnv','AiBaseUrl','AiModel')) {
    $value = [string]$cfgImport.Applied[$key]
    if ($value) { $cfg[$key] = $value }
}
if ($cfgImport.Applied.ContainsKey('Port')) { $cfg.Port = [int]$cfgImport.Applied['Port'] }
if ($Port) { $cfg.Port = $Port }

$state = Get-RMConfigurationState
$cfg.MissingSettings = $state.Missing
$cfg.PathsConfigured = $state.Configured
$cfg.DefaultSourceRoot = [string]$script:RMC.DefaultSourceRoot
$cfg.DefaultDestDir    = [string]$script:RMC.DefaultDestDir
$cfg.PrefabsModRoot    = [string]$script:RMC.PrefabsModRoot
$cfg.AddonRoot         = [string]$script:RMC.AddonRoot
$cfg.RemapTable        = [string]$script:RMC.RemapTable
$cfg.UserConfig        = [string]$script:RMC.UserConfig

# resolve the API key across process/user/machine scopes (so a freshly setx-ed key
# works without needing to restart the shell/session)
function Get-ApiKey([string]$name) {
    $k = [System.Environment]::GetEnvironmentVariable($name)
    if (-not $k) { $k = [System.Environment]::GetEnvironmentVariable($name, 'User') }
    if (-not $k) { $k = [System.Environment]::GetEnvironmentVariable($name, 'Machine') }
    return $k
}

# ------------------------------------------------------------------ helpers
$script:Utf8 = [System.Text.UTF8Encoding]::new($false)

function Send-Json($ctx, $obj, [int]$status = 200) {
    $json = ConvertTo-Json -InputObject $obj -Depth 60
    $bytes = $script:Utf8.GetBytes($json)
    $ctx.Response.StatusCode = $status
    $ctx.Response.ContentType = 'application/json; charset=utf-8'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}
function Send-Text($ctx, [string]$text, [string]$ctype = 'text/html; charset=utf-8', [int]$status = 200) {
    $bytes = $script:Utf8.GetBytes($text)
    if ($ctype -like 'text/html*') { $ctx.Response.Headers['Cache-Control'] = 'no-store' }
    $ctx.Response.StatusCode = $status
    $ctx.Response.ContentType = $ctype
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}
function Read-Body($ctx) {
    if (-not $ctx.Request.HasEntityBody) { return $null }
    $reader = [System.IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
    $t = $reader.ReadToEnd(); $reader.Close()
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    return $t | ConvertFrom-Json
}

function New-RestoreToken {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) }
    finally { $rng.Dispose() }
    return [System.BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

function Test-PostRequest($ctx) {
    $token = $ctx.Request.Headers['X-Restore-Token']
    if ([string]::IsNullOrWhiteSpace($script:CsrfToken) -or $token -cne $script:CsrfToken) {
        Send-Json $ctx ([pscustomobject]@{ ok=$false; error='Недействительный токен запроса. Обновите страницу.' }) 403
        return $false
    }
    $origin = $ctx.Request.Headers['Origin']
    if ($null -ne $origin -and $origin -cne $script:ServerOrigin) {
        Send-Json $ctx ([pscustomobject]@{ ok=$false; error='Запрос с другого источника запрещён.' }) 403
        return $false
    }
    $contentType = ([string]$ctx.Request.ContentType).Split(';')[0].Trim()
    if ($contentType -ine 'application/json') {
        Send-Json $ctx ([pscustomobject]@{ ok=$false; error='Ожидается Content-Type application/json.' }) 415
        return $false
    }
    return $true
}

$script:CsrfToken = New-RestoreToken
$script:ServerOrigin = ([uri]"http://localhost:$($cfg.Port)/").GetLeftPart([System.UriPartial]::Authority)

# Values shown in the settings panel. The API key itself is never exposed: only the
# NAME of the environment variable that holds it.
function Get-RMSettingsView {
    $rm = Get-RMConfig
    return [pscustomobject]@{
        addonRoot         = [string]$rm.AddonRoot
        prefabsModRoot    = [string]$rm.PrefabsModRoot
        remapTable        = [string]$rm.RemapTable
        defaultSourceRoot = [string]$rm.DefaultSourceRoot
        defaultDestDir    = [string]$rm.DefaultDestDir
        apiKeyEnv         = [string]$cfg.ApiKeyEnv
        aiBaseUrl         = [string]$cfg.AiBaseUrl
        aiModel           = [string]$cfg.AiModel
        port              = [int]$cfg.Port
        configPath        = [string]$rm.UserConfig
        apiKeyPresent     = [bool](Get-ApiKey $cfg.ApiKeyEnv)
    }
}

# find mission folders (a dir that directly contains a *.ent file)
function Find-Missions([string]$Root) {
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Root)) { return $out }
    Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.ent -ErrorAction SilentlyContinue | ForEach-Object {
        $dir = $_.Directory.FullName
        $out.Add([pscustomobject]@{ Name = $_.Directory.Name; Dir = $dir; Ent = $_.Name })
    }
    return ($out | Sort-Object Dir -Unique)
}

# ------------------------------------------------------------------ routing
function Handle-Api($ctx) {
    $path   = $ctx.Request.Url.AbsolutePath
    $method = $ctx.Request.HttpMethod

    if ($method -eq 'POST' -and -not (Test-PostRequest $ctx)) { return }

    switch ("$method $path") {
        'GET /api/config' {
            $ctx.Response.Headers['Cache-Control'] = 'no-store'
            # A missing prefab mod is a first-run state, not a failure: the UI must still
            # load so the operator can enter the paths and save them.
            $modIndex = @{}
            $modIndexError = ''
            try { $modIndex = Build-ModIndex }
            catch { $modIndexError = $_.Exception.Message }
            $state = Get-RMConfigurationState
            Send-Json $ctx ([pscustomobject]@{
                csrfToken         = $script:CsrfToken
                defaultSourceRoot = $script:RMC.DefaultSourceRoot
                defaultDestDir    = $script:RMC.DefaultDestDir
                remapTable        = $script:RMC.RemapTable
                addonRoot         = $script:RMC.AddonRoot
                prefabsModRoot    = $script:RMC.PrefabsModRoot
                userConfig        = $script:RMC.UserConfig
                pathsConfigured   = $state.Configured
                missingSettings   = @($state.Missing)
                prefabsAvailable  = ($modIndex.Count -gt 0)
                prefabsError      = $modIndexError
                aiEnabled         = [bool](Get-ApiKey $cfg.ApiKeyEnv)
                aiModel           = $cfg.AiModel
                aiKeyEnv          = $cfg.ApiKeyEnv
                modIndexCount     = $modIndex.Count
            })
            return
        }
        'GET /api/settings' {
            $ctx.Response.Headers['Cache-Control'] = 'no-store'
            Send-Json $ctx (Get-RMSettingsView)
            return
        }
        'POST /api/settings' {
            $b = Read-Body $ctx
            $values = @{}
            foreach ($key in @($script:RMPathKeys) + @($script:RMValueKeys)) {
                if ($b -and $null -ne $b.PSObject.Properties[$key]) { $values[$key] = [string]$b.PSObject.Properties[$key].Value }
            }
            try {
                $saved = Save-RMUserConfig -Values $values
                $reimport = Import-RMUserConfig -Path $saved.path
                foreach ($key in @('ApiKeyEnv','AiBaseUrl','AiModel')) {
                    $value = [string]$reimport.Applied[$key]
                    if ($value) { $cfg[$key] = $value }
                }
                $cfg.DefaultSourceRoot = [string]$script:RMC.DefaultSourceRoot
                $cfg.DefaultDestDir    = [string]$script:RMC.DefaultDestDir
                $cfg.PrefabsModRoot    = [string]$script:RMC.PrefabsModRoot
                $cfg.AddonRoot         = [string]$script:RMC.AddonRoot
                $cfg.RemapTable        = [string]$script:RMC.RemapTable
                $cfg.UserConfig        = [string]$script:RMC.UserConfig
                $state = Get-RMConfigurationState
                Send-Json $ctx ([pscustomobject]@{
                    ok=$true; path=$saved.path; backupFile=$saved.backupFile
                    settings=(Get-RMSettingsView); warnings=@($reimport.Warnings)
                })
            } catch {
                Send-Json $ctx ([pscustomobject]@{ ok=$false; error=$_.Exception.Message }) 400
            }
            return
        }
        'GET /api/missions' {
            $root = $ctx.Request.QueryString['root']; if (-not $root) { $root = $cfg.DefaultSourceRoot }
            Send-Json $ctx (@(Find-Missions $root))
            return
        }
        'POST /api/reindex' {
            $n = (Build-ModIndex -Refresh).Count
            Send-Json $ctx ([pscustomobject]@{ ok=$true; count=$n })
            return
        }
        'POST /api/scan' {
            $b = Read-Body $ctx
            $writeStubs = [bool]$b.writeStubs
            $res = Scan-Mission -MissionDir $b.sourceDir -RemapTable $cfg.RemapTable -WriteStubs:$writeStubs
            Send-Json $ctx $res
            return
        }
        'POST /api/suggest' {
            $b = Read-Body $ctx
            $p = [string]$b.path
            if ([string]::IsNullOrWhiteSpace($p)) {
                Send-Json $ctx ([pscustomobject]@{ error = 'Не передана ссылка на префаб (пустое поле path).' }) 400
                return
            }
            $idx = Get-NewCatalogModIndex
            $features = Get-NewCatalogCandidateFeatures
            $top = if ($b.top) { [Math]::Min(100,[Math]::Max(1,[int]$b.top)) } else { 6 }
            Send-Json $ctx (@(Rank-Candidates -BrokenPath $p -ModIndex $idx -CandidateFeatures $features -Top $top))
            return
        }
        'POST /api/shutdown' {
            Send-Json $ctx ([pscustomobject]@{ ok=$true; message='Сервер остановлен. Можно закрыть это окно браузера.' })
            # Stop the listener shortly after the response is flushed, otherwise the
            # client may not receive the reply.
            Start-Sleep -Milliseconds 300
            if ($script:Listener) { try { $script:Listener.Stop() } catch {} }
            return
        }
        'POST /api/ai-suggest' {
            $b = Read-Body $ctx
            $p = [string]$b.path
            if ([string]::IsNullOrWhiteSpace($p)) {
                Send-Json $ctx ([pscustomobject]@{ ok=$false; error='Не передана ссылка на префаб.'; candidates=@() }) 200
                return
            }
            $idx = Get-NewCatalogModIndex
            $features = Get-NewCatalogCandidateFeatures
            $ranked = @(Rank-Candidates -BrokenPath $p -ModIndex $idx -CandidateFeatures $features -Top ([Math]::Max(1,$idx.Count)))
            $pool = @(Get-AICandidatePool -Candidates $ranked -Top 20 -PerFamily 2)
            # Include the normal shortlist and every AI option in the response so
            # the user can inspect the selected candidate and manual alternatives.
            $visibleRefs = @(@($ranked | Select-Object -First 8) + @($pool) | ForEach-Object { $_.Ref })
            $cands = @($ranked | Where-Object { $visibleRefs -contains $_.Ref })
            try {
                $brokenRef = if ($b.ref) { [string]$b.ref } else { $p }
                $ai = Invoke-AISuggest -BrokenRef $brokenRef -Candidates $pool -ApiKeyEnv $cfg.ApiKeyEnv -BaseUrl $cfg.AiBaseUrl -Model $cfg.AiModel
                Send-Json $ctx ([pscustomobject]@{ ok=$true; ai=$ai; candidates=$cands })
            } catch {
                Send-Json $ctx ([pscustomobject]@{ ok=$false; error=$_.Exception.Message; candidates=$cands }) 200
            }
            return
        }
        'POST /api/chat' {
            $b = Read-Body $ctx
            $msg = [string]$b.message
            if ([string]::IsNullOrWhiteSpace($msg)) {
                Send-Json $ctx ([pscustomobject]@{ ok=$false; error='Пустое сообщение.' }) 400
                return
            }
            try {
                $reply = Invoke-AIChat -Message $msg -ApiKeyEnv $cfg.ApiKeyEnv -BaseUrl $cfg.AiBaseUrl -Model $cfg.AiModel
                Send-Json $ctx ([pscustomobject]@{ ok=$true; reply=$reply })
            } catch {
                Send-Json $ctx ([pscustomobject]@{ ok=$false; error=$_.Exception.Message }) 200
            }
            return
        }
        'POST /api/map' {
            $b = Read-Body $ctx
            if ([string]$b.oldRef -notmatch '^\{[0-9A-Fa-f]{16}\}.+\.et$' -or [string]$b.newRef -notmatch '^\{[0-9A-Fa-f]{16}\}.+\.et$') {
                Send-Json $ctx ([pscustomobject]@{ ok=$false; error='Ссылки на исходный и целевой префабы должны быть указаны полностью.' }) 400
                return
            }
            $w = Set-RemapEntries -Entries @{ "$($b.oldRef)" = "$($b.newRef)" } -Path $cfg.RemapTable
            Send-Json $ctx ([pscustomobject]@{ ok=$true; added=$w.Added; updated=$w.Updated })
            return
        }
        'POST /api/restore' {
            $b = Read-Body $ctx
            $dest = if ($b.destDir) { $b.destDir } else { $cfg.DefaultDestDir }
            $res = Invoke-Restore -SourceMission $b.sourceDir -DestDir $dest -RemapTable $cfg.RemapTable -AddonRoot $cfg.AddonRoot -Force:([bool]$b.force)
            Send-Json $ctx $res
            return
        }
        'GET /api/table' {
            $model = Get-RemapModel -Path $cfg.RemapTable
            Send-Json $ctx $model
            return
        }
        'GET /api/modindex' {
            $idx = Build-ModIndex
            Send-Json $ctx $idx
            return
        }
        'POST /api/table/save' {
            $b = Read-Body $ctx
            $ops = @($b.operations)
            $expectedHash = [string]$b.versionHash
            try {
                $res = Save-RemapOperations -Operations $ops -ExpectedVersionHash $expectedHash -Path $cfg.RemapTable
                $updatedModel = Get-RemapModel -Path $cfg.RemapTable
                Send-Json $ctx ([pscustomobject]@{
                    ok         = $true
                    applied    = $res.applied
                    backupFile = $res.backupFile
                    model      = $updatedModel
                })
            } catch {
                Send-Json $ctx ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) 400
            }
            return
        }
        'GET /api/catalog/new' {
            $cat = Get-NewPrefabsCatalog
            Send-Json $ctx $cat
            return
        }
        'GET /api/catalog/old' {
            $cat = Get-OldPrefabsCatalog
            Send-Json $ctx $cat
            return
        }
        'POST /api/catalog/rebuild' {
            $n = Build-NewPrefabsCatalog -Refresh
            $o = Build-OldPrefabsCatalog -Refresh
            Send-Json $ctx ([pscustomobject]@{ ok=$true; newCount=$n.Count; oldCount=$o.Count })
            return
        }
        default {
            Send-Json $ctx ([pscustomobject]@{ error = "no route: $method $path" }) 404
        }
    }
}

# ------------------------------------------------------------------ listener
# Another tool already holding the default port must not be fatal: try the configured
# port first, then a short range of neighbours, and report only if all of them fail.
# Each attempt needs its OWN HttpListener: once Start() has failed, the instance can no
# longer accept or release prefixes, it throws an argument error instead.
$prefix = $null
$listener = $null
$lastError = ''
foreach ($candidate in ($cfg.Port..($cfg.Port + 9))) {
    $attempt = "http://localhost:$candidate/"
    $attemptListener = [System.Net.HttpListener]::new()
    $script:Listener = $attemptListener
    try {
        $attemptListener.Prefixes.Add($attempt)
        $attemptListener.Start()
        $listener = $attemptListener
        $prefix = $attempt
        break
    } catch {
        $lastError = $_.Exception.Message
        try { if ($attemptListener.IsListening) { $attemptListener.Stop() } } catch {}
        try { $attemptListener.Close() } catch {}
    }
}
if (-not $prefix) {
    Write-Host "Не удалось занять порты $($cfg.Port)-$($cfg.Port + 9): $lastError" -ForegroundColor Red
    Write-Host 'Укажите свободный порт в настройках (Port) или передайте -Port.' -ForegroundColor Red
    exit 1
}
$script:Listener = $listener
if ($cfg.Port -ne ([uri]$prefix).Port) {
    $cfg.Port = ([uri]$prefix).Port
    $script:ServerOrigin = ([uri]$prefix).GetLeftPart([System.UriPartial]::Authority)
    Write-Host "Порт $($cfg.Port) занят другим приложением, сервер запущен на свободном порту $($cfg.Port)." -ForegroundColor Yellow
}

$modIndexCount = (Build-ModIndex).Count
Write-Host ""
Write-Host "  Восстановление миссий  ->  $prefix" -ForegroundColor Green
Write-Host "  Префабов в моде: $modIndexCount" -ForegroundColor DarkGray
Write-Host "  ИИ-подсказки: $(if (Get-ApiKey $cfg.ApiKeyEnv) {'вкл ('+$cfg.AiModel+')'} else {'выкл ('+$cfg.ApiKeyEnv+' не задан)'})" -ForegroundColor DarkGray
Write-Host "  Настройки: $($cfg.UserConfig)" -ForegroundColor DarkGray
if (-not $state.Configured) {
    Write-Host ''
    Write-Host "  Не заданы обязательные пути: $($state.Missing -join ', ')" -ForegroundColor Yellow
    Write-Host "  Откройте панель «Настройки» в интерфейсе и сохраните их." -ForegroundColor Yellow
} elseif ($modIndexCount -eq 0) {
    Write-Host ''
    Write-Host "  Каталог префабов мода недоступен: $($cfg.PrefabsModRoot)" -ForegroundColor Yellow
    Write-Host "  Подсказки и таблица замен работают по сохранённому каталогу, проверка и восстановление — нет." -ForegroundColor Yellow
}
Write-Host "  Остановить: кнопка в интерфейсе или Ctrl+C в этом окне" -ForegroundColor DarkGray
Write-Host ""

if (-not $NoBrowser) { Start-Process $prefix }

$indexPath = Join-Path $ScriptDir 'index.html'
$editorPath = Join-Path $ScriptDir 'editor.html'
while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $p = $ctx.Request.Url.AbsolutePath
        if ($ctx.Request.HttpMethod -eq 'POST' -or $p -like '/api/*') {
            Handle-Api $ctx
        }
        elseif ($p -eq '/' -or $p -eq '/index.html') {
            # MUST read as UTF-8 explicitly: Get-Content in PS 5.1 defaults to the ANSI
            # codepage, which would mangle the Cyrillic/UTF-8 bytes into mojibake.
            $html = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8)
            Send-Text $ctx $html
        }
        elseif ($p -eq '/editor' -or $p -eq '/editor.html') {
            if (-not (Test-Path -LiteralPath $editorPath)) {
                Send-Text $ctx 'editor.html не найден' 'text/plain; charset=utf-8' 404
            } else {
                $html = [System.IO.File]::ReadAllText($editorPath, [System.Text.Encoding]::UTF8)
                Send-Text $ctx $html
            }
        }
        else {
            Send-Text $ctx 'Not found' 'text/plain; charset=utf-8' 404
        }
    } catch {
        try { Send-Json $ctx ([pscustomobject]@{ error = $_.Exception.Message }) 500 } catch {}
        Write-Host ("ERR {0} : {1}" -f $ctx.Request.Url.AbsolutePath, $_.Exception.Message) -ForegroundColor Red
    }
}
