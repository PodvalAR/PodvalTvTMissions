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
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'ui.config.json' }
. (Join-Path (Split-Path $ScriptDir -Parent) 'Restore-Core.ps1')

# ------------------------------------------------------------------ config
$cfg = @{
    Port           = 8787
    AddonRoot      = 'C:\Users\armen\Documents\GitHub\PodvalTvTMissions\PodvalTvTMissions'
    PrefabsModRoot = 'C:\Users\armen\Documents\GitHub\PodvalTvTPrefabs\PodvalTvTPrefabs'
    RemapTable     = (Join-Path (Split-Path $ScriptDir -Parent) 'remap_table.json')
    DefaultSourceRoot = 'C:\Users\armen\Desktop\PodvalCommunityEvent\Worlds'
    DefaultDestDir    = 'C:\Users\armen\Documents\GitHub\PodvalTvTMissions\PodvalTvTMissions\Worlds\RamboKZ\Peroi'
    ApiKeyEnv      = 'JUSTWOKER_API_KEY'
    AiBaseUrl      = 'https://api.justwoker.icu/v1'
    AiModel        = 'claude-opus-4-8'
}
if (Test-Path -LiteralPath $ConfigPath) {
    $fileCfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    foreach ($p in $fileCfg.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
}
if ($Port) { $cfg.Port = $Port }

Set-RMConfig @{ AddonRoot=$cfg.AddonRoot; PrefabsModRoot=$cfg.PrefabsModRoot; RemapTable=$cfg.RemapTable } | Out-Null

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
            Send-Json $ctx ([pscustomobject]@{
                csrfToken         = $script:CsrfToken
                defaultSourceRoot = $cfg.DefaultSourceRoot
                defaultDestDir    = $cfg.DefaultDestDir
                remapTable        = $cfg.RemapTable
                prefabsModRoot    = $cfg.PrefabsModRoot
                aiEnabled         = [bool](Get-ApiKey $cfg.ApiKeyEnv)
                aiModel           = $cfg.AiModel
                modIndexCount     = (Build-ModIndex).Count
            })
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
            $idx = Build-ModIndex
            $top = if ($b.top) { [int]$b.top } else { 6 }
            Send-Json $ctx (@(Rank-Candidates -BrokenPath $p -ModIndex $idx -Top $top))
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
            $idx = Build-ModIndex
            $cands = @(Rank-Candidates -BrokenPath $b.path -ModIndex $idx -Top 8)
            try {
                $ai = Invoke-AISuggest -BrokenRef $b.ref -Candidates $cands -ApiKeyEnv $cfg.ApiKeyEnv -BaseUrl $cfg.AiBaseUrl -Model $cfg.AiModel
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
$prefix = "http://localhost:$($cfg.Port)/"
$listener = [System.Net.HttpListener]::new()
$script:Listener = $listener
$listener.Prefixes.Add($prefix)
try { $listener.Start() }
catch { Write-Host "Не удалось занять порт $prefix : $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "  Восстановление миссий  ->  $prefix" -ForegroundColor Green
Write-Host "  Префабов в моде: $((Build-ModIndex).Count)" -ForegroundColor DarkGray
Write-Host "  ИИ-подсказки: $(if (Get-ApiKey $cfg.ApiKeyEnv) {'вкл ('+$cfg.AiModel+')'} else {'выкл ('+$cfg.ApiKeyEnv+' не задан)'})" -ForegroundColor DarkGray
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
