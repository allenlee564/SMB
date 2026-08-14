[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw 'The virtual environment is missing. Run installer\install.ps1 -AcceptTerms.' }
& $Python --version *> $null
if ($LASTEXITCODE -ne 0) { throw 'The virtual environment is broken. Run installer\install.ps1 -AcceptTerms to repair it.' }
Set-Location -LiteralPath $ProjectRoot
$env:BLUE_AI_HOST = '127.0.0.1'
& $Python -m api.server
if ($LASTEXITCODE -ne 0) { throw 'Blue AI Assistant stopped with an error.' }
