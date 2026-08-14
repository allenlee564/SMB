[CmdletBinding()]
param(
    [switch]$AcceptTerms,
    [switch]$InstallPrerequisites,
    [switch]$PullModel,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')

Write-Host 'Blue AI Assistant will use/install:'
Write-Host '- Python 3.11+ if missing; project-local .venv and Python dependencies'
Write-Host '- Ollama if missing; Qwen2.5:3b (~1.9 GB) if missing'
Write-Host '- Local services only: Ollama 127.0.0.1:11434; Blue AI 127.0.0.1:8765'
Write-Host 'It will not attack hosts, modify/patch the exercise VM, read user documents,'
Write-Host 'expose Ollama to LAN, add inbound firewall rules, enable startup, or remove existing models.'
if ($DryRun) { Write-Host '[DRY RUN] No installation, deletion, download, or system modification will occur.' }
elseif (-not $AcceptTerms) { Write-Host 'Nothing was installed. Review the plan, then add -AcceptTerms.'; exit 2 }

$WindowsVersion = [Environment]::OSVersion.Version.ToString()
$RamGb = $null
try { $RamGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) } catch {}
$ProjectDrive = (Get-Item $ProjectRoot).PSDrive
$FreeGb = if ($null -ne $ProjectDrive.Free) { [math]::Round($ProjectDrive.Free / 1GB, 1) } else { $null }
$RamText = if ($null -ne $RamGb) { "${RamGb} GB" } else { 'unknown (permission unavailable)' }
$DiskText = if ($null -ne $FreeGb) { "${FreeGb} GB" } else { 'unknown' }
Write-Host "Preflight: Windows $WindowsVersion; $env:PROCESSOR_ARCHITECTURE; RAM $RamText; free disk $DiskText; GPU acceleration unknown."
if ($null -ne $RamGb -and $RamGb -lt 8) { Write-Warning 'Less than 8 GB RAM: CPU inference may be slow.' }
if ($null -ne $FreeGb -and $FreeGb -lt 5) { throw 'At least 5 GB of free disk space is required.' }

$State = [ordered]@{
    python = [ordered]@{ found = $false; installed_by_blue_ai = $false; version = $null }
    ollama = [ordered]@{ found = $false; installed_by_blue_ai = $false }
    model = [ordered]@{ name = $script:ModelName; installed_by_blue_ai = $false }
}

$VenvPath = Join-Path $ProjectRoot '.venv'
$VenvValid = Test-Venv $ProjectRoot
$VenvExists = Test-Path -LiteralPath $VenvPath
Write-Host $(if ($VenvValid) { 'Virtual environment: valid' } elseif ($VenvExists) { 'Virtual environment: broken; will rebuild' } else { 'Virtual environment: missing; will create' })

$Python = $null
if ($VenvValid) {
    Write-Host 'System Python: not required (valid project venv detected)'
    $PythonAction = 'UseVenv'
} else {
    $Python = Find-Python
    Write-Host $(if ($Python) { "System Python detected: $($Python.Version) ($($Python.Source))" } else { 'System Python: missing' })
    $PythonAction = Get-PythonPrerequisiteAction -VenvValid $false -SystemPython $Python -InstallPrerequisites ([bool]$InstallPrerequisites)
}

if ($PythonAction -eq 'FailMissingPython' -and -not $DryRun) {
    throw 'A valid Python 3.11+ installation is required to create the project virtual environment. Re-run with -InstallPrerequisites.'
}
if ($PythonAction -eq 'InstallPython' -and -not $DryRun) {
    $Winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $Winget) { throw 'winget was not found. Install Python 3.11+ manually.' }
    Invoke-CheckedCommand $Winget.Source @('install','--id','Python.Python.3.12','--exact','--accept-package-agreements','--accept-source-agreements')
    $State.python.installed_by_blue_ai = $true
    $Python = Find-Python
    if (-not $Python) { throw 'Python installation completed but no working interpreter was found. Open a new terminal and retry.' }
}
if ($Python) { $State.python.found = $true; $State.python.version = $Python.Version }
if (-not $DryRun) {
    if (-not $VenvValid) {
        if (-not $Python) { throw 'A working Python interpreter is required to create .venv.' }
        $Venv = $VenvPath
        if (Test-Path -LiteralPath $Venv) {
            if ((Resolve-Path $Venv).Path -ne (Join-Path (Resolve-Path $ProjectRoot).Path '.venv')) { throw 'Refusing to remove an unexpected venv path.' }
            Remove-Item -LiteralPath $Venv -Recurse -Force
        }
        Invoke-CheckedCommand $Python.Executable (@($Python.ArgumentsPrefix) + @('-m','venv',$Venv))
    }
    $VenvPython = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
    Invoke-CheckedCommand $VenvPython @('-m','pip','install','--upgrade','pip')
    Invoke-CheckedCommand $VenvPython @('-m','pip','install','-r',(Join-Path $ProjectRoot 'requirements.txt'))
}

$Ollama = Find-Ollama
Write-Host $(if ($Ollama) { "Ollama detected: $($Ollama.Version)" } else { 'Ollama: missing' })
if (-not $Ollama -and -not $DryRun) {
    if (-not $InstallPrerequisites) { throw 'Ollama was not found. Re-run with -InstallPrerequisites.' }
    $Winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $Winget) { throw 'winget was not found. Install Ollama manually.' }
    Invoke-CheckedCommand $Winget.Source @('install','--id','Ollama.Ollama','--exact','--accept-package-agreements','--accept-source-agreements')
    $State.ollama.installed_by_blue_ai = $true
    $Ollama = Find-Ollama
    if (-not $Ollama) { throw 'Ollama installation completed but its executable could not be discovered.' }
}
if ($Ollama) { $State.ollama.found = $true }

$Models = Get-OllamaModels
if ($null -eq $Models -and $Ollama -and -not $DryRun) {
    Write-Host 'Ollama API is unavailable; starting Ollama in its normal local mode.'
    Start-Process -FilePath $Ollama.Executable -ArgumentList 'serve' -WindowStyle Hidden
    $Deadline = (Get-Date).AddSeconds(15)
    do { Start-Sleep -Milliseconds 500; $Models = Get-OllamaModels } while ($null -eq $Models -and (Get-Date) -lt $Deadline)
}
if ($null -eq $Models) { Write-Host 'Ollama API: unreachable' } else { Write-Host 'Ollama API: reachable' }
$HasModel = Test-ModelInstalled $Models
Write-Host $(if ($HasModel) { "${script:ModelName}: installed" } else { "${script:ModelName}: missing" })
if (-not $DryRun) {
    if ($null -eq $Models) { throw 'Ollama API did not become reachable at 127.0.0.1:11434.' }
    if (-not $HasModel) {
        if (-not $PullModel) { throw "Model is missing. Re-run with -PullModel (downloads about 1.9 GB)." }
        Write-Host "Downloading $script:ModelName (~1.9 GB); duration depends on network speed."
        Invoke-CheckedCommand $Ollama.Executable @('pull',$script:ModelName)
        $State.model.installed_by_blue_ai = $true
        if (-not (Test-ModelInstalled (Get-OllamaModels))) { throw 'Model pull finished but the model was not reported by Ollama.' }
    }
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot 'state') -Force | Out-Null
    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ProjectRoot 'state\install-state.json') -Encoding UTF8
    Write-InstallLog $ProjectRoot 'Prerequisites and project environment installed; starting verification.'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Installation verification failed.' }
    Write-Host 'Blue AI Assistant installation verified successfully.'
    Write-Host 'Blue AI API: http://127.0.0.1:8765 | Ollama: http://127.0.0.1:11434 | Model: qwen2.5:3b'
    Write-Host 'Start: installer\start.ps1 | Verify: installer\verify.ps1 | Stop: Ctrl+C | Uninstall: installer\uninstall.ps1'
}
