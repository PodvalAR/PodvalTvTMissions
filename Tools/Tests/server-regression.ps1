#requires -Version 5.1
param([string]$ToolsRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$serverPath = Join-Path $ToolsRoot 'UI\Serve-RestoreUI.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

# Load function definitions only: never execute configuration or listener startup.
foreach ($name in @('Send-Json', 'Send-Text', 'New-RestoreToken', 'Test-PostRequest', 'Handle-Api', 'Get-RMSettingsView')) {
    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $functionAst) { throw "Function not found: $name" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$script:Utf8 = [System.Text.UTF8Encoding]::new($false)
$script:CsrfToken = 'synthetic-server-token'
$script:ServerOrigin = 'http://localhost:8787'
$script:ModIndexEmpty = $false
$cfg = @{
    DefaultSourceRoot='synthetic-source'; DefaultDestDir='synthetic-destination'
    RemapTable='synthetic-remap'; PrefabsModRoot='synthetic-mod'
    ApiKeyEnv='synthetic-key'; AiModel='synthetic-model'; AiBaseUrl='https://synthetic.invalid'
    AddonRoot='synthetic-addon'; Port=8787; UserConfig='synthetic-config'
}
# Configuration layer: the server reads the resolved paths from the core config object
# and persists changes through the core helpers, so both are stubbed here.
$script:RMPathKeys  = @('AddonRoot','PrefabsModRoot','RemapTable','CatalogNew','CatalogOld','DefaultSourceRoot','DefaultDestDir','IndexCache')
$script:RMValueKeys = @('ApiKeyEnv','AiBaseUrl','AiModel')
$script:RMC = @{
    AddonRoot='synthetic-addon'; PrefabsModRoot='synthetic-mod'
    RemapTable='synthetic-remap'; DefaultSourceRoot='synthetic-source'
    DefaultDestDir='synthetic-destination'; UserConfig='synthetic-config'
}
$script:MissingSettings = @()
$script:SavedValues = $null
$script:SaveShouldThrow = $false
function Get-RMConfig { return $script:RMC }
function Get-RMConfigurationState { return [pscustomobject]@{ Configured=(@($script:MissingSettings).Count -eq 0); Missing=@($script:MissingSettings) } }
function Import-RMUserConfig { param([string]$Path) $script:OperationCalls++; return [pscustomobject]@{ Path='synthetic-config'; Exists=$true; Applied=@{}; Warnings=@() } }
function Save-RMUserConfig {
    param([Parameter(Mandatory)][hashtable]$Values, [string]$Path)
    $script:OperationCalls++
    if ($script:SaveShouldThrow) { throw 'Настройки не сохранены: PrefabsModRoot : каталог не найден: synthetic-missing' }
    $script:SavedValues = $Values
    foreach ($k in @('AddonRoot','PrefabsModRoot','DefaultSourceRoot','DefaultDestDir')) {
        if ($Values.ContainsKey($k) -and $Values[$k]) { $script:RMC[$k] = $Values[$k] }
    }
    return [pscustomobject]@{ ok=$true; path='synthetic-config'; backupFile='synthetic-config.bak' }
}
$script:ReadBodyCalls = 0
$script:OperationCalls = 0
$script:FixtureItems = @()
$script:FixtureIndex = @{ '0000000000000001'='Prefabs/Test.et' }
$script:PoolOverride = $null
$script:RequestBody = [pscustomobject]@{
    path='Prefabs/Test.et'; ref='{0000000000000001}Prefabs/Test.et'; top=6
    sourceDir='synthetic-source'; destDir='synthetic-destination'; writeStubs=$false; force=$false
    oldRef='{0000000000000001}Prefabs/Test.et'; newRef='{0000000000000002}Prefabs/Replacement.et'; message='synthetic'
    operations=@([pscustomobject]@{ op='delete'; oldRef='{0000000000000001}Prefabs/Test.et' }); versionHash='synthetic'
}
function Read-Body($ctx) { $script:ReadBodyCalls++; return $script:RequestBody }
function Get-ApiKey($name) { return $null }
function Build-ModIndex { param([switch]$Refresh) $script:OperationCalls++; if ($script:ModIndexEmpty) { return @{} }; return @{ '0000000000000001'='Prefabs/Test.et' } }
function Find-Missions($Root) { return $script:FixtureItems }
function Get-NewPrefabsCatalog { return $script:FixtureItems }
function Get-OldPrefabsCatalog { return $script:FixtureItems }
function Get-NewCatalogModIndex { $script:OperationCalls++; return $script:FixtureIndex }
function Get-NewCatalogCandidateFeatures { return @{ '0000000000000001'=[pscustomobject]@{FeatureVersion=2;Path='Prefabs/Test.et'} } }
function Rank-Candidates { param($BrokenPath,$ModIndex,$CandidateFeatures,$Top) $script:LastRankTop=$Top; $script:LastRankFeatures=$CandidateFeatures; return $script:FixtureItems }
function Get-AICandidatePool { param($Candidates,$Top,$PerFamily) $script:LastPoolTop=$Top; $script:LastPerFamily=$PerFamily; if ($null -ne $script:PoolOverride) { return $script:PoolOverride }; return $Candidates }
function Scan-Mission { param($MissionDir,$RemapTable,[switch]$WriteStubs) $script:OperationCalls++; return [pscustomobject]@{ Refs=@() } }
function Set-RemapEntries { param($Entries,$Path) $script:OperationCalls++; return [pscustomobject]@{ Added=1; Updated=0 } }
function Invoke-Restore { param($SourceMission,$DestDir,$RemapTable,$AddonRoot,[switch]$Force) $script:OperationCalls++; return [pscustomobject]@{ Broken=@() } }
function Invoke-AISuggest { param($BrokenRef,$Candidates,$ApiKeyEnv,$BaseUrl,$Model) $script:OperationCalls++; $script:LastAiCandidates=@($Candidates); if ($Candidates.Count) { return [pscustomobject]@{ Status='match';Ref=$Candidates[0].Ref; Confidence=1; Reason='synthetic' } }; return [pscustomobject]@{ Status='no_match';Ref='';Confidence=0;Reason='synthetic' } }
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

$postPaths = @('/api/reindex','/api/scan','/api/suggest','/api/shutdown','/api/ai-suggest','/api/chat','/api/map','/api/restore','/api/table/save','/api/catalog/rebuild','/api/settings','/')
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
# The AI pool may contain a result beyond the first eight. The API must return
# that record for inspection and use the entire indexed snapshot for retrieval.
$script:FixtureItems=@(); $script:FixtureIndex=@{}
for ($i=1; $i -le 10; $i++) {
    $guid=$i.ToString('X16'); $prefabPath="Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Char_Rifleman_$i.et"
    $script:FixtureIndex[$guid]=$prefabPath
    $script:FixtureItems += [pscustomobject]@{Ref="{$guid}$prefabPath";Path=$prefabPath;Guid=$guid}
}
$script:PoolOverride=@($script:FixtureItems[9])
$ctx=New-Context -method POST -path '/api/ai-suggest' -headers @{'X-Restore-Token'=$script:CsrfToken}
Handle-Api $ctx
$aiBoundary=Read-Response $ctx | ConvertFrom-Json
Assert-Equal $script:LastRankTop 10 'AI retrieval ranks the complete indexed snapshot'
Assert-True ($script:LastRankFeatures -is [hashtable]) 'AI retrieval uses prepared catalog features'
Assert-Equal $script:LastPoolTop 20 'AI prompt pool supports twenty candidates'
Assert-Equal $script:LastPerFamily 2 'AI prompt pool limits repeated families'
Assert-Equal $script:LastAiCandidates.Count 1 'AI transport receives the diverse pool rather than the UI shortlist'
Assert-Equal $aiBoundary.ai.Ref $script:FixtureItems[9].Ref 'AI-selected item beyond first eight is returned'
Assert-True (@($aiBoundary.candidates | Where-Object {$_.Ref -eq $aiBoundary.ai.Ref}).Count -eq 1) 'AI selection is included once in visible candidates'
$script:PoolOverride=@()
$ctx=New-Context -method POST -path '/api/ai-suggest' -headers @{'X-Restore-Token'=$script:CsrfToken}
Handle-Api $ctx
$noMatchBoundary=Read-Response $ctx | ConvertFrom-Json
Assert-True ($noMatchBoundary.ok -and $noMatchBoundary.ai.Status -eq 'no_match' -and -not $noMatchBoundary.ai.Ref) 'Empty AI pool yields a normal no_match response'
$script:FixtureItems=@(); $script:FixtureIndex=@{'0000000000000001'='Prefabs/Test.et'}; $script:PoolOverride=$null

# --- configuration surface: first run without a configured prefab mod ---------------
# The UI must load on a fresh clone, so /api/config may not fail when the prefab mod is
# absent; it reports the state instead.
$script:MissingSettings = @()
$script:ModIndexEmpty = $false
$ctx = New-Context -method GET -path '/api/config'
Handle-Api $ctx
$readyConfig = Read-Response $ctx | ConvertFrom-Json
Assert-Equal $ctx.Response.StatusCode 200 'Config responds when the prefab mod is available'
Assert-True $readyConfig.prefabsAvailable 'Config reports the prefab mod as available'
Assert-Equal $readyConfig.modIndexCount 1 'Config reports the prefab count'
Assert-True $readyConfig.pathsConfigured 'Config reports a fully configured tool'
Assert-Equal @($readyConfig.missingSettings).Count 0 'Configured tool lists no missing settings'

$script:ModIndexEmpty = $true
$ctx = New-Context -method GET -path '/api/config'
Handle-Api $ctx
$emptyConfig = Read-Response $ctx | ConvertFrom-Json
Assert-Equal $ctx.Response.StatusCode 200 'Config still responds without the prefab mod'
Assert-True (-not $emptyConfig.prefabsAvailable) 'Config reports the prefab mod as unavailable'
Assert-Equal $emptyConfig.modIndexCount 0 'Config reports zero prefabs when the mod is absent'

$script:ModIndexEmpty = $false
$script:MissingSettings = @('PrefabsModRoot')
$ctx = New-Context -method GET -path '/api/config'
Handle-Api $ctx
$unconfigured = Read-Response $ctx | ConvertFrom-Json
Assert-True (-not $unconfigured.pathsConfigured) 'Config reports an unconfigured tool'
Assert-True (@($unconfigured.missingSettings) -contains 'PrefabsModRoot') 'Config names the missing setting'
Assert-Equal @($unconfigured.missingSettings).Count 1 'Config lists exactly the missing settings'
$script:MissingSettings = @()

# --- settings: read, save, and reject an invalid path ------------------------------
$ctx = New-Context -method GET -path '/api/settings'
Handle-Api $ctx
$settings = Read-Response $ctx | ConvertFrom-Json
Assert-Equal $ctx.Response.StatusCode 200 'Settings view responds'
Assert-Equal $settings.addonRoot 'synthetic-addon' 'Settings view exposes the addon root'
Assert-Equal $settings.prefabsModRoot 'synthetic-mod' 'Settings view exposes the prefab mod root'
Assert-Equal $settings.configPath 'synthetic-config' 'Settings view exposes the config file path'
Assert-True (-not $settings.PSObject.Properties['apiKey']) 'Settings view never exposes the API key'
Assert-True (-not $settings.PSObject.Properties['apiKeyPresentValue']) 'Settings view exposes no key material'

$savedRequest = $script:RequestBody
$script:RequestBody = [pscustomobject]@{
    prefabsModRoot='synthetic-new-mod'; defaultSourceRoot='synthetic-new-source'; port='8787'
}
$script:OperationCalls = 0
$ctx = New-Context -method POST -path '/api/settings' -headers @{ 'X-Restore-Token'=$script:CsrfToken }
Handle-Api $ctx
$saveResponse = Read-Response $ctx | ConvertFrom-Json
Assert-Equal $ctx.Response.StatusCode 200 'Valid settings are accepted'
Assert-True $saveResponse.ok 'Valid settings report success'
Assert-True ($null -ne $script:SavedValues) 'Valid settings reach the persistence helper'
Assert-Equal $script:SavedValues['prefabsModRoot'] 'synthetic-new-mod' 'New prefab mod root is forwarded'
Assert-Equal $script:RMC.PrefabsModRoot 'synthetic-new-mod' 'Saving updates the live configuration'

$script:SaveShouldThrow = $true
$ctx = New-Context -method POST -path '/api/settings' -headers @{ 'X-Restore-Token'=$script:CsrfToken }
Handle-Api $ctx
$rejected = Read-Response $ctx | ConvertFrom-Json
Assert-Equal $ctx.Response.StatusCode 400 'An invalid path is rejected instead of being stored'
Assert-True (-not $rejected.ok) 'A rejected save reports failure'
Assert-True ($rejected.error -match 'PrefabsModRoot') 'A rejected save explains which setting is wrong'
$script:SaveShouldThrow = $false
$script:RequestBody = $savedRequest

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
function Get-RoleTokens($path) { return [pscustomobject]@{FeatureVersion=2;Path=$path} }

foreach ($count in @(0,1,2)) {
    $script:NewCatalogCache = $null
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
