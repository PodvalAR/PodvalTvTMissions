#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$shellName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$shellPath = Join-Path $PSHOME $shellName
foreach ($testName in @('core-regression.ps1', 'core-paths-regression.ps1', 'ranking-regression.ps1', 'config-regression.ps1', 'server-regression.ps1', 'mission-validation-regression.ps1')) {
    & $shellPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $testName)
    if ($LASTEXITCODE -ne 0) { throw "$testName failed (exit $LASTEXITCODE)." }
}
# Node.js is only needed for the browser-side regressions. A machine without it still
# gets the PowerShell coverage instead of a hard failure.
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Warning 'node not found in PATH - skipping editor-regression.cjs and index-regression.cjs.'
} else {
    foreach ($testName in @('editor-regression.cjs','index-regression.cjs')) {
        & $node.Source (Join-Path $PSScriptRoot $testName)
        if ($LASTEXITCODE -ne 0) { throw "$testName failed (exit $LASTEXITCODE)." }
    }
}
Write-Host 'PASS all restore regressions'
