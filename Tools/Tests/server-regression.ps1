#requires -Version 5.1
param([string]$ToolsRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$serverPath = Join-Path $ToolsRoot 'UI\Serve-RestoreUI.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

# Load function definitions only: never execute configuration or listener startup.
foreach ($name in @('Send-Json', 'Send-Text', 'New-RestoreToken', 'Test-PostRequest', 'Handle-Api')) {
    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $functionAst) { throw "Function not found: $name" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$script:Utf8 = [System.Text.UTF8Encoding]::new($false)
$script:CsrfToken = 'synthetic-server-token'
$script:ServerOrigin = 'http://localhost:8787'
$cfg = @{
    DefaultSourceRoot='synthetic-source'; DefaultDestDir='synthetic-destination'
    RemapTable='synthetic-remap'; PrefabsModRoot='synthetic-mod'
    ApiKeyEnv='synthetic-key'; AiModel='synthetic-model'; AiBaseUrl='https://synthetic.invalid'
    AddonRoot='synthetic-addon'
}
$script:ReadBodyCalls = 0
$script:OperationCalls = 0
$script:FixtureItems = @()
$script:RequestBody = [pscustomobject]@{
    path='Prefabs/Test.et'; ref='{0000000000000001}Prefabs/Test.et'; top=6
    sourceDir='synthetic-source'; destDir='synthetic-destination'; writeStubs=$false; force=$false
    oldRef='{0000000000000001}Prefabs/Test.et'; newRef=''; message='synthetic'
    operations=@([pscustomobject]@{ op='delete'; oldRef='{0000000000000001}Prefabs/Test.et' }); versionHash='synthetic'
}
function Read-Body($ctx) { $script:ReadBodyCalls++; return $script:RequestBody }
function Get-ApiKey($name) { return $null }
function Build-ModIndex { param([switch]$Refresh) $script:OperationCalls++; return @{ '0000000000000001'='Prefabs/Test.et' } }
function Find-Missions($Root) { return $script:FixtureItems }
function Get-NewPrefabsCatalog { return $script:FixtureItems }
function Get-OldPrefabsCatalog { return $script:FixtureItems }
function Rank-Candidates { param($BrokenPath,$ModIndex,$Top) return $script:FixtureItems }
function Scan-Mission { param($MissionDir,$RemapTable,[switch]$WriteStubs) $script:OperationCalls++; return [pscustomobject]@{ Refs=@() } }
function Set-RemapEntries { param($Entries,$Path) $script:OperationCalls++; return [pscustomobject]@{ Added=1; Updated=0 } }
function Invoke-Restore { param($SourceMission,$DestDir,$RemapTable,$AddonRoot,[switch]$Force) $script:OperationCalls++; return [pscustomobject]@{ Broken=@() } }
function Invoke-AISuggest { param($BrokenRef,$Candidates,$ApiKeyEnv,$BaseUrl,$Model) $script:OperationCalls++; return [pscustomobject]@{ Ref='synthetic'; Confidence=1; Reason='synthetic' } }
function Invoke-AIChat { param($Message,$ApiKeyEnv,$BaseUrl,$Model) $script:OperationCalls++; return 'synthetic' }
function Save-RemapOperations { param($Operations,$ExpectedVersionHash,$Path) $script:OperationCalls++; return [pscustomobject]@{ applied=1; backupFile='synthetic' } }
function Get-RemapModel { param($Path) return [pscustomobject]@{ groups=@(); entries=@() } }
function Build-NewPrefabsCatalog { param([switch]$Refresh) $script:OperationCalls++; return $script:FixtureItems }
function Build-OldPrefabsCatalog { param([switch]$Refresh) $script:OperationCalls++; return $script:FixtureItems }
function Start-Sleep { param($Milliseconds) }
$script:StopCalls = 0
$script:Listener = [pscustomobject]@{}
$script:Listener | Add-Member -MemberType ScriptMethod -Name Stop -Value { $script:StopCalls++ }

$script:Assertions = 0
function Assert-Equal($actual, $expected, [string]$message) {
    $script:Assertions++
    if ($actual -cne $expected) { throw "${message}: expected '$expected', got '$actual'" }
}
function Assert-True([bool]$actual, [string]$message) {
    $script:Assertions++
    if (-not $actual) { throw $message }
}
function New-Context([string]$method='GET', [string]$path='/api/config', [hashtable]$headers=@{}, [string]$contentType='application/json') {
    $requestHeaders = New-Object System.Net.WebHeaderCollection
    foreach ($key in $headers.Keys) { $requestHeaders[$key] = $headers[$key] }
    return [pscustomobject]@{
        Request=[pscustomobject]@{
            HttpMethod=$method; Url=[uri]($script:ServerOrigin + $path)
            Headers=$requestHeaders; ContentType=$contentType
            HasEntityBody=$true; QueryString=(New-Object System.Collections.Specialized.NameValueCollection)
        }
        Response=[pscustomobject]@{
            StatusCode=200; ContentType=''; ContentLength64=0
            Headers=(New-Object System.Net.WebHeaderCollection)
            OutputStream=(New-Object System.IO.MemoryStream)
        }
    }
}
function Read-Response($ctx) { return $script:Utf8.GetString($ctx.Response.OutputStream.ToArray()) }
function Assert-Blocked([string]$path, [hashtable]$headers, [string]$contentType, [int]$status) {
    $script:ReadBodyCalls=0; $script:OperationCalls=0; $script:StopCalls=0
    $ctx = New-Context -method POST -path $path -headers $headers -contentType $contentType
    Handle-Api $ctx
    Assert-Equal $ctx.Response.StatusCode $status "Blocked $path status"
    Assert-Equal $script:ReadBodyCalls 0 "Blocked $path must not parse body"
    Assert-Equal $script:OperationCalls 0 "Blocked $path must not perform operations"
    Assert-Equal $script:StopCalls 0 "Blocked $path must not stop listener"
}

$tokenA = New-RestoreToken
$tokenB = New-RestoreToken
Assert-True ($tokenA -cmatch '^[0-9a-f]{64}$') 'Token must contain 256 random bits as hex'
Assert-True ($tokenA -cne $tokenB) 'Each generated token must differ'

$ctx = New-Context
Handle-Api $ctx
$config = Read-Response $ctx | ConvertFrom-Json
Assert-Equal $config.csrfToken $script:CsrfToken 'Config publishes current token'
Assert-Equal $ctx.Response.Headers['Cache-Control'] 'no-store' 'Config must not be cached'
$ctx = New-Context
Send-Text $ctx '<html>synthetic</html>'
Assert-Equal $ctx.Response.Headers['Cache-Control'] 'no-store' 'HTML must not be cached'

$postPaths = @('/api/reindex','/api/scan','/api/suggest','/api/shutdown','/api/ai-suggest','/api/chat','/api/map','/api/restore','/api/table/save','/api/catalog/rebuild','/')
foreach ($path in $postPaths) {
    Assert-Blocked $path @{} 'application/json' 403
    Assert-Blocked $path @{ 'X-Restore-Token'='previous-run-token'; Origin=$script:ServerOrigin } 'application/json' 403
    Assert-Blocked $path @{ 'X-Restore-Token'=$script:CsrfToken; Origin='https://foreign.invalid' } 'application/json' 403
    Assert-Blocked $path @{ 'X-Restore-Token'=$script:CsrfToken; Origin='null' } 'application/json' 403
    Assert-Blocked $path @{ 'X-Restore-Token'=$script:CsrfToken; Origin=$script:ServerOrigin } 'text/plain' 415
}
Assert-Blocked '/api/reindex' @{ 'X-Restore-Token'=$script:CsrfToken; Origin='http://LOCALHOST:8787' } 'application/json' 403
Assert-Blocked '/api/reindex' @{ 'X-Restore-Token'=$script:CsrfToken; Origin=($script:ServerOrigin + '/') } 'application/json' 403
Assert-Blocked '/api/reindex' @{ 'X-Restore-Token'=$script:CsrfToken } 'application/jsonp' 415

foreach ($path in ($postPaths | Where-Object { $_ -ne '/' })) {
    $script:ReadBodyCalls=0; $script:OperationCalls=0; $script:StopCalls=0
    $ctx = New-Context -method POST -path $path -headers @{ 'X-Restore-Token'=$script:CsrfToken; Origin=$script:ServerOrigin } -contentType 'application/json; charset=utf-8'
    Handle-Api $ctx
    Assert-Equal $ctx.Response.StatusCode 200 "Authenticated $path response"
    Assert-True (($script:OperationCalls + $script:StopCalls) -gt 0) "Authenticated $path must reach its mock operation"
}

foreach ($headers in @(@{ 'X-Restore-Token'=$script:CsrfToken }, @{ 'X-Restore-Token'=$script:CsrfToken; Origin=$script:ServerOrigin })) {
    $script:OperationCalls=0
    $ctx = New-Context -method POST -path '/api/reindex' -headers $headers -contentType 'Application/JSON; charset=UTF-8'
    Handle-Api $ctx
    Assert-Equal $ctx.Response.StatusCode 200 'Authenticated JSON with charset is accepted'
    Assert-Equal $script:OperationCalls 1 'Authenticated POST runs once'
}

# Exercise the actual catalog getter/server boundary, including PS 5.1 JSON arrays.
# Existing script paths only satisfy Test-Path; Read-Text returns synthetic JSON.
$coreParseErrors = $null
$coreAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $ToolsRoot 'Restore-Core.ps1'), [ref]$tokens, [ref]$coreParseErrors)
if ($coreParseErrors.Count) { throw ($coreParseErrors | Out-String) }
foreach ($name in @('Get-NewPrefabsCatalog', 'Get-OldPrefabsCatalog')) {
    $functionAst = $coreAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $functionAst) { throw "Core function not found: $name" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
$script:RMC = @{ CatalogNew=$serverPath; CatalogOld=$serverPath }
function Read-Text($Path) {
    if ($Path -cne $serverPath) { throw "Unexpected synthetic catalog path: $Path" }
    return (ConvertTo-Json -InputObject $script:FixtureItems -Depth 5 -Compress)
}

foreach ($count in @(0,1,2)) {
    $script:FixtureItems = @()
    for ($i=0; $i -lt $count; $i++) { $script:FixtureItems += [pscustomobject]@{ Name="Item$i"; Ref="Item$i" } }
    foreach ($path in @('/api/missions','/api/catalog/new','/api/catalog/old','/api/suggest')) {
        $method = if ($path -eq '/api/suggest') { 'POST' } else { 'GET' }
        $ctx = New-Context -method $method -path $path -headers @{ 'X-Restore-Token'=$script:CsrfToken }
        Handle-Api $ctx
        $text = Read-Response $ctx
        Assert-True ($text.TrimStart().StartsWith('[')) "$path count $count must serialize as an array"
        $decoded = ConvertFrom-Json -InputObject $text
        $decodedCount = if ($null -eq $decoded) { 0 } else { $decoded.Count }
        Assert-Equal $decodedCount $count "$path array count"
        if ($count -gt 0) {
            $first = @($decoded)[0]
            Assert-Equal $first.Name 'Item0' "$path must contain flat records, not nested arrays"
        }
    }
}

$script:StopCalls=0
$ctx = New-Context -method POST -path '/api/shutdown' -headers @{ 'X-Restore-Token'=$script:CsrfToken }
Handle-Api $ctx
Assert-Equal $ctx.Response.StatusCode 200 'Authenticated shutdown responds'
Assert-Equal $script:StopCalls 1 'Authenticated shutdown stops only fake listener'

$index = [System.IO.File]::ReadAllText((Join-Path $ToolsRoot 'UI\index.html'), [System.Text.Encoding]::UTF8)
Assert-Equal ([regex]::Matches($index, '\bfetch\s*\(').Count) 1 'All index requests must use the shared wrapper'
Assert-True ($index.Contains("headers.set('X-Restore-Token', CFG.csrfToken)")) 'Index wrapper sends the token'
Assert-True ($index.Contains("await api('/api/shutdown'")) 'Shutdown uses the guarded wrapper'

Write-Output ("PASS server-regression: {0} assertions, PowerShell {1}" -f $script:Assertions, $PSVersionTable.PSVersion)
