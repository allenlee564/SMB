[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$Failures = 0
function Assert([bool]$Condition, [string]$Name) {
    if ($Condition) { Write-Host "[PASS] $Name" } else { Write-Host "[FAIL] $Name"; $script:Failures++ }
}

$GoodPython = Find-Python
Assert ($null -eq $GoodPython -or [version]$GoodPython.Version -ge [version]'3.11') 'Python found result is executable and 3.11+'
$PowerShellExe = (Get-Process -Id $PID).Path
$TimeoutWatch = [Diagnostics.Stopwatch]::StartNew()
$TimedOutProbe = Test-Executable -Executable $PowerShellExe -Arguments @('-NoProfile','-Command','Start-Sleep -Seconds 10') -TimeoutSeconds 1
$TimeoutWatch.Stop()
Assert ($null -eq $TimedOutProbe -and $TimeoutWatch.Elapsed.TotalSeconds -lt 4) 'Executable probe times out and rejects a hanging candidate'
$MockPython = Find-Python -Resolver { param($Name) if ($Name -eq 'py') { [pscustomobject]@{ Source = 'mock-py.exe' } } } -Probe { param($Exe, $Args) '3.12.10' }
Assert ($MockPython.Source -eq 'py-launcher' -and $MockPython.Version -eq '3.12.10') 'Python found through mocked discovery'
$CapturedProbeArguments = $null
$ArgumentPython = Find-Python -Resolver { param($Name) if ($Name -eq 'python') { [pscustomobject]@{ Source = 'mock-python.exe' } } } -Probe { param($Exe, $ProbeArguments) $script:CapturedProbeArguments = @($ProbeArguments); '3.12.10' }
Assert ($ArgumentPython.Source -eq 'python' -and $CapturedProbeArguments.Count -eq 2 -and $CapturedProbeArguments[0] -eq '-c') 'Python discovery passes version probe arguments'
$MissingPython = Find-Python -Resolver { param($Name) $null }
Assert ($null -eq $MissingPython) 'Python missing through mocked discovery'
Assert ((Get-PythonPrerequisiteAction -VenvValid $true -SystemPython $null -InstallPrerequisites $false) -eq 'UseVenv') 'System Python missing + valid venv continues'
Assert ((Get-PythonPrerequisiteAction -VenvValid $false -SystemPython $null -InstallPrerequisites $false) -eq 'FailMissingPython') 'System Python missing + missing venv fails without prerequisites'
Assert ((Get-PythonPrerequisiteAction -VenvValid $false -SystemPython $null -InstallPrerequisites $false) -eq 'FailMissingPython') 'System Python missing + broken venv fails without prerequisites'
$MissingRoot = Join-Path ([IO.Path]::GetTempPath()) ("blue-ai-missing-" + [guid]::NewGuid())
Assert (-not (Test-Venv $MissingRoot)) 'Missing venv is rejected'

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("blue-ai-installer-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $TempRoot '.venv\Scripts') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $TempRoot '.venv\Scripts\python.exe') -Value 'not an executable'
Assert (-not (Test-Venv $TempRoot)) 'Broken venv is rejected'
Assert (Test-Venv $TempRoot -Probe { param($Exe) 'Python 3.12.10' }) 'Valid venv is accepted through mocked probe'
Remove-Item -LiteralPath $TempRoot -Recurse -Force

$MockOllama = Find-Ollama -Resolver { [pscustomobject]@{ Source = 'mock-ollama.exe' } } -Probe { param($Exe) 'ollama version 0.11' }
Assert ($null -ne $MockOllama) 'Ollama found through mocked discovery'
Assert ($null -eq (Find-Ollama -Resolver { $null })) 'Ollama missing through mocked discovery'

$ModelsByName = @([pscustomobject]@{ name = 'qwen2.5:3b' })
$ModelsByModel = @([pscustomobject]@{ model = 'qwen2.5:3b' })
Assert (Test-ModelInstalled $ModelsByName) 'Model found using name field'
Assert (Test-ModelInstalled $ModelsByModel) 'Model found using model field'
Assert (-not (Test-ModelInstalled @([pscustomobject]@{ name = 'llama3' }))) 'Missing model is rejected'
Assert (-not (Test-BlueAiHealth ([pscustomobject]@{ service = 'blue-ai-assistant'; status = 'ok' }))) 'Legacy health without readiness is rejected'
Assert (-not (Test-BlueAiHealth ([pscustomobject]@{ service = 'other'; status = 'ok' }))) 'Port conflict response rejected'
Assert (-not (Test-BlueAiHealth ([pscustomobject]@{ service = 'blue-ai-assistant'; status = 'degraded' }))) 'Degraded health rejected'
$ReadyHealth = [pscustomobject]@{ service = 'blue-ai-assistant'; version = '0.3.0'; status = 'ok'; localhost_only = $true; model = [pscustomobject]@{ installed = $true; loaded = $true } }
Assert (Test-BlueAiHealth $ReadyHealth '0.3.0') 'Ready model health accepted'
Assert (-not (Test-BlueAiHealth $ReadyHealth '0.2.0')) 'Wrong release version health rejected'
Assert (-not (Test-BlueAiHealth ([pscustomobject]@{ service = 'blue-ai-assistant'; version = '0.3.0'; status = 'ok'; localhost_only = $false; model = [pscustomobject]@{ installed = $true; loaded = $true } }) '0.3.0')) 'Non-localhost health rejected'

$VerifySource = Get-Content -Raw (Join-Path $PSScriptRoot 'verify.ps1')
Assert ($VerifySource -match '\[INFO\] System Python discovery skipped; not required because project venv is valid') 'Verify skips system Python discovery with valid venv'
Assert ($VerifySource -match 'Push-Location -LiteralPath \$ProjectRoot' -and $VerifySource -match 'finally \{ Pop-Location \}') 'Verify runs Python tests from project root'
Assert ($VerifySource -match 'Blue AI Assistant installation verified successfully\.') 'Verify success summary is visible'
Assert ($VerifySource -match 'verification failed\. Review the \[FAIL\] items above\.' -and $VerifySource -match 'exit 1') 'Verify failure summary is visible and exits non-zero'

if ($Failures) { exit 1 }
Write-Host 'Installer helper tests passed.'
