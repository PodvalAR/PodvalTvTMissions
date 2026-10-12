#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$shellName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$shellPath = Join-Path $PSHOME $shellName
foreach ($testName in @('core-regression.ps1', 'core-paths-regression.ps1', 'ranking-regression.ps1', 'server-regression.ps1')) {
    & $shellPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $testName)
    if ($LASTEXITCODE -ne 0) { throw "$testName failed (exit $LASTEXITCODE)." }
}
$nodePath = (Get-Command node -ErrorAction Stop).Source
foreach ($testName in @('editor-regression.cjs','index-regression.cjs')) {
    & $nodePath (Join-Path $PSScriptRoot $testName)
    if ($LASTEXITCODE -ne 0) { throw "$testName failed (exit $LASTEXITCODE)." }
}
Write-Host 'PASS all restore regressions'
