[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')
$Failed = $false
$StartedProcess = $null
$ExpectedVersion = (Get-Content -Raw (Join-Path $ProjectRoot 'VERSION')).Trim()

function Report-Test([string]$Name, [bool]$Passed, [string]$Detail = '') {
    if ($Passed) { Write-Host "[PASS] $Name $Detail" }
    else { Write-Host "[FAIL] $Name $Detail"; $script:Failed = $true }
}

$VenvPython = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
$VenvOk = Test-Venv $ProjectRoot
if ($VenvOk) {
    Write-Host '[INFO] System Python discovery skipped; not required because project venv is valid'
} else {
    $SystemPython = Find-Python
    if ($SystemPython) { Write-Host "[PASS] System Python $($SystemPython.Version)" }
    else { Write-Host '[INFO] System Python not found; required only to create or repair project venv' }
}

Report-Test 'Project virtual environment' $VenvOk $(if (-not $VenvOk) { 'missing or broken' } else { '' })
if ($VenvOk) {
    $ImportProbe = Test-Executable -Executable $VenvPython -Arguments @('-c','import fastapi, httpx, uvicorn; print("required imports available")') -TimeoutSeconds 5
    Report-Test 'Python dependencies' ($null -ne $ImportProbe)
    Push-Location -LiteralPath $ProjectRoot
    try { & $VenvPython -m unittest discover -s 'tests' -v }
    finally { Pop-Location }
    Report-Test 'Python tests' ($LASTEXITCODE -eq 0)
} else {
    Report-Test 'Python dependencies' $false 'cannot test without a valid .venv'
    Report-Test 'Python tests' $false 'cannot test without a valid .venv'
}

$Ollama = Find-Ollama
Report-Test 'Ollama executable' ($null -ne $Ollama) $(if ($Ollama) { $Ollama.Version } else { 'not found or not executable' })
$Models = Get-OllamaModels
Report-Test 'Ollama API' ($null -ne $Models) 'http://127.0.0.1:11434/api/tags'
Report-Test $script:ModelName (Test-ModelInstalled $Models)

$Health = Get-BlueAiHealth
if ($null -ne $Health -and $Health.service -ne 'blue-ai-assistant') {
    Report-Test 'Blue AI API' $false 'port 8765 is occupied by another service; no process was stopped'
} elseif ($null -eq $Health -and $VenvOk) {
    Write-Host "Loading $script:ModelName into memory..."
    $StartedProcess = Start-Process -FilePath $VenvPython -ArgumentList @('-m','api.server') -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru
    $Settings = Get-Content -Raw (Join-Path $ProjectRoot 'config\settings.json') | ConvertFrom-Json
    $Deadline = (Get-Date).AddSeconds(([int]$Settings.model_warmup_timeout_seconds) + 10)
    do { Start-Sleep -Milliseconds 500; $Health = Get-BlueAiHealth } while ($null -eq $Health -and -not $StartedProcess.HasExited -and (Get-Date) -lt $Deadline)
    if (Test-BlueAiHealth $Health $ExpectedVersion) {
        Write-Host "$script:ModelName ready"
        Write-Host 'Blue AI Assistant ready'
    }
}

$HealthReady = Test-BlueAiHealth $Health $ExpectedVersion
if ($Health) {
    $HealthVersion = if ($Health.PSObject.Properties['version']) { $Health.version } else { 'missing' }
    $HealthLocalhost = if ($Health.PSObject.Properties['localhost_only']) { $Health.localhost_only } else { 'missing' }
    $HealthDetail = "service=$($Health.service) version=$HealthVersion status=$($Health.status) installed=$($Health.model.installed) loaded=$($Health.model.loaded) localhost_only=$HealthLocalhost"
} else { $HealthDetail = 'unreachable' }
Report-Test 'Blue AI /health' $HealthReady $HealthDetail

if ($StartedProcess -and -not $StartedProcess.HasExited) { Stop-Process -Id $StartedProcess.Id }
if ($Failed) {
    Write-Host 'Blue AI Assistant installation verification failed. Review the [FAIL] items above.'
    exit 1
}
Write-Host 'Blue AI Assistant installation verified successfully.'
exit 0
