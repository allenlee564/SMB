Set-StrictMode -Version Latest

$script:ModelName = 'qwen2.5:3b'
$script:OllamaTagsUrl = 'http://127.0.0.1:11434/api/tags'
$script:BlueAiHealthUrl = 'http://127.0.0.1:8765/health'

function Invoke-CheckedCommand {
    param([Parameter(Mandatory)] [string]$Executable, [string[]]$Arguments = @())
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Executable $($Arguments -join ' ')" }
}

function Test-Executable {
    param(
        [Parameter(Mandatory)] [string]$Executable,
        [string[]]$Arguments = @('--version'),
        [ValidateRange(1, 30)] [int]$TimeoutSeconds = 5
    )
    function ConvertTo-ProcessArgument([string]$Value) {
        if ($Value -notmatch '[\s"]') { return $Value }
        return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
    }
    $Process = $null
    try {
        $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $StartInfo.FileName = $Executable
        $StartInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
        $StartInfo.UseShellExecute = $false
        $StartInfo.CreateNoWindow = $true
        $StartInfo.RedirectStandardOutput = $true
        $StartInfo.RedirectStandardError = $true
        $Process = [System.Diagnostics.Process]::new()
        $Process.StartInfo = $StartInfo
        if (-not $Process.Start()) { return $null }
        if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $Process.Kill() } catch {}
            return $null
        }
        $Output = ($Process.StandardOutput.ReadToEnd() + $Process.StandardError.ReadToEnd()).Trim()
        if ($Process.ExitCode -ne 0) { return $null }
        return $Output
    } catch { return $null }
    finally { if ($null -ne $Process) { $Process.Dispose() } }
}

function Find-Python {
    param(
        [scriptblock]$Resolver = { param($Name) Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1 },
        [scriptblock]$Probe = { param($Exe, $ProbeArguments) Test-Executable -Executable $Exe -Arguments $ProbeArguments }
    )
    $Candidates = @(
        @{ Name = 'py'; Prefix = @('-3.12'); Source = 'py-launcher' },
        @{ Name = 'py'; Prefix = @('-3'); Source = 'py-launcher' },
        @{ Name = 'python'; Prefix = @(); Source = 'python' },
        @{ Name = 'python3'; Prefix = @(); Source = 'python3' }
    )
    foreach ($Candidate in $Candidates) {
        $Command = & $Resolver $Candidate.Name
        if (-not $Command) { continue }
        $ProbeArgs = @($Candidate.Prefix) + @('-c', 'import sys; print(".".join(map(str, sys.version_info[:3]))); raise SystemExit(0 if sys.version_info >= (3, 11) else 1)')
        $Version = & $Probe $Command.Source $ProbeArgs
        if ($Version) {
            return [pscustomobject]@{ Executable = $Command.Source; ArgumentsPrefix = @($Candidate.Prefix); Version = $Version; Source = $Candidate.Source }
        }
    }
    return $null
}

function Test-Venv {
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [scriptblock]$Probe = { param($Exe) Test-Executable -Executable $Exe -Arguments @('--version') }
    )
    $Python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { return $false }
    return [bool](& $Probe $Python)
}

function Get-PythonPrerequisiteAction {
    param(
        [Parameter(Mandatory)] [bool]$VenvValid,
        [AllowNull()]$SystemPython,
        [bool]$InstallPrerequisites
    )
    if ($VenvValid) { return 'UseVenv' }
    if ($null -ne $SystemPython) { return 'CreateVenv' }
    if ($InstallPrerequisites) { return 'InstallPython' }
    return 'FailMissingPython'
}

function Find-Ollama {
    param(
        [scriptblock]$Resolver = {
            $Command = Get-Command ollama -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($Command) { return $Command }
            $KnownPaths = @(
                (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
                (Join-Path $env:ProgramFiles 'Ollama\ollama.exe')
            )
            foreach ($Path in $KnownPaths) {
                if (Test-Path -LiteralPath $Path -PathType Leaf) { return [pscustomobject]@{ Source = $Path } }
            }
            return $null
        },
        [scriptblock]$Probe = { param($Exe) Test-Executable -Executable $Exe -Arguments @('--version') }
    )
    $Command = & $Resolver
    if (-not $Command) { return $null }
    $Version = & $Probe $Command.Source
    if (-not $Version) { return $null }
    return [pscustomobject]@{ Executable = $Command.Source; Version = $Version }
}

function Get-OllamaModels {
    try {
        $Response = Invoke-RestMethod -Uri $script:OllamaTagsUrl -Method Get -TimeoutSec 3
        return @($Response.models)
    } catch { return $null }
}

function Test-ModelInstalled {
    param([AllowNull()] [object[]]$Models, [string]$Name = $script:ModelName)
    if ($null -eq $Models) { return $false }
    return [bool]($Models | Where-Object {
        $NameProperty = $_.PSObject.Properties['name']
        $ModelProperty = $_.PSObject.Properties['model']
        ($NameProperty -and $NameProperty.Value -eq $Name) -or ($ModelProperty -and $ModelProperty.Value -eq $Name)
    } | Select-Object -First 1)
}

function Get-BlueAiHealth {
    try { return Invoke-RestMethod -Uri $script:BlueAiHealthUrl -Method Get -TimeoutSec 3 }
    catch { return $null }
}

function Test-BlueAiHealth {
    param([AllowNull()]$Health, [string]$ExpectedVersion = '')
    if ($null -eq $Health -or $Health.service -ne 'blue-ai-assistant' -or $Health.status -ne 'ok') { return $false }
    $ModelProperty = $Health.PSObject.Properties['model']
    if (-not $ModelProperty -or $null -eq $ModelProperty.Value) { return $false }
    $InstalledProperty = $ModelProperty.Value.PSObject.Properties['installed']
    $LoadedProperty = $ModelProperty.Value.PSObject.Properties['loaded']
    $LocalhostProperty = $Health.PSObject.Properties['localhost_only']
    if (-not $InstalledProperty -or $InstalledProperty.Value -ne $true -or
        -not $LoadedProperty -or $LoadedProperty.Value -ne $true -or
        -not $LocalhostProperty -or $LocalhostProperty.Value -ne $true) { return $false }
    if ($ExpectedVersion) {
        $VersionProperty = $Health.PSObject.Properties['version']
        if (-not $VersionProperty -or $VersionProperty.Value -ne $ExpectedVersion) { return $false }
    }
    return $true
}

function Write-InstallLog {
    param([string]$ProjectRoot, [string]$Message)
    $LogDirectory = Join-Path $ProjectRoot 'logs'
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    Add-Content -LiteralPath (Join-Path $LogDirectory 'install.log') -Value "$(Get-Date -Format o) $Message"
}
