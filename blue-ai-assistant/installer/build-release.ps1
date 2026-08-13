[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Clean,
    [switch]$SkipTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$DistRoot = Join-Path $ProjectRoot 'dist'
$StagingParent = Join-Path $DistRoot 'staging'
$StagingRoot = Join-Path $StagingParent 'blue-ai-assistant'
$PowerShellExecutable = (Get-Process -Id $PID).Path
$RequiredSourceDirectories = @('api', 'core', 'config', 'installer', 'tests')
$AllowedDirectories = @('api', 'core', 'config', 'installer', 'tests')
$WindowsReleaseTests = @(
    'test_api_security.py',
    'test_core.py',
    'test_health.py',
    'test_model_runtime.py',
    'test_server_lifespan.py'
)
$RequiredSourceFiles = @('requirements.txt', 'README.md', 'VERSION', 'RELEASE_NOTES.md')
$ExplicitReleaseFiles = @(
    'config/settings.json',
    'installer/common.ps1',
    'installer/install.ps1',
    'installer/start.ps1',
    'installer/verify.ps1',
    'installer/uninstall.ps1',
    'installer/test-common.ps1',
    'requirements.txt',
    'README.md',
    'VERSION',
    'RELEASE_NOTES.md'
)
$PythonTestStatus = 'NOT RUN'
$InstallerTestStatus = 'NOT RUN'
$ParserStatus = 'NOT RUN'
$PartialZip = $null
$TemporarySidecar = $null
$TemporaryReport = $null
$PublishedArtifacts = New-Object Collections.Generic.List[object]

function Get-FullPath {
    param([Parameter(Mandatory)] [string]$LiteralPath)
    return [IO.Path]::GetFullPath($LiteralPath)
}

function Get-ReleaseRelativePath {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$ItemPath
    )
    $RootFull = (Get-FullPath $Root).TrimEnd([char[]]@([char]92, [char]47))
    $Prefix = $RootFull + [IO.Path]::DirectorySeparatorChar
    $ItemFull = Get-FullPath $ItemPath
    if (-not $ItemFull.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'An allowlisted item resolved outside its source root.'
    }
    return $ItemFull.Substring($Prefix.Length).Replace([char]92, [char]47)
}

function Test-ExcludedSourcePath {
    param([Parameter(Mandatory)] [string]$RelativePath)
    $Normalized = $RelativePath.Replace([char]92, [char]47)
    $Segments = @($Normalized.Split([char]47))
    $ExcludedDirectories = @(
        '.venv', '__pycache__', 'logs', 'state', '.git', '.github', '.vscode',
        '.idea', '.pytest_cache', 'dist', 'build'
    )
    foreach ($Segment in $Segments) {
        if ($ExcludedDirectories -contains $Segment.ToLowerInvariant()) { return $true }
    }
    $Leaf = $Segments[$Segments.Count - 1].ToLowerInvariant()
    if ($Leaf -in @('.coverage', 'thumbs.db', 'desktop.ini', 'settings.local.json', '.env')) { return $true }
    return [bool]($Leaf -match '\.(?:pyc|pyo|log|tmp|bak)$')
}

function Assert-SourceStructure {
    foreach ($Name in $RequiredSourceDirectories) {
        if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $Name) -PathType Container)) {
            throw "Required project directory is missing: $Name"
        }
    }
    foreach ($Name in $RequiredSourceFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $Name) -PathType Leaf)) {
            throw "Required project file is missing: $Name"
        }
    }
    foreach ($Name in @('common.ps1', 'install.ps1', 'start.ps1', 'verify.ps1', 'uninstall.ps1', 'test-common.ps1', 'build-release.ps1', 'verify-release.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $Name) -PathType Leaf)) {
            throw "Required installer script is missing: installer/$Name"
        }
    }
    Write-Host '[PASS] Project structure'
}

function Get-PlannedFiles {
    $Files = New-Object Collections.Generic.List[string]
    foreach ($DirectoryName in @('api', 'core')) {
        $SourceDirectory = Join-Path $ProjectRoot $DirectoryName
        foreach ($File in Get-ChildItem -LiteralPath $SourceDirectory -Recurse -Force -File -Filter '*.py') {
            $NestedRelative = Get-ReleaseRelativePath $SourceDirectory $File.FullName
            $ReleaseRelative = ($DirectoryName + '/' + $NestedRelative)
            if (-not (Test-ExcludedSourcePath $ReleaseRelative)) { $Files.Add($ReleaseRelative) }
        }
    }
    foreach ($Name in $WindowsReleaseTests) { $Files.Add("tests/$Name") }
    foreach ($Name in $ExplicitReleaseFiles) { $Files.Add($Name) }
    $Files.Add('RELEASE_MANIFEST.json (generated)')
    return @($Files | Sort-Object -Unique)
}

function Get-AllowlistedSourceFiles {
    $Files = New-Object Collections.Generic.List[object]
    foreach ($DirectoryName in @('api', 'core')) {
        $SourceDirectory = Join-Path $ProjectRoot $DirectoryName
        foreach ($File in Get-ChildItem -LiteralPath $SourceDirectory -Recurse -Force -File -Filter '*.py') {
            $NestedRelative = Get-ReleaseRelativePath $SourceDirectory $File.FullName
            $ReleaseRelative = $DirectoryName + '/' + $NestedRelative
            if (-not (Test-ExcludedSourcePath $ReleaseRelative)) {
                $Files.Add([pscustomobject]@{ Source = $File.FullName; Relative = $ReleaseRelative })
            }
        }
    }
    foreach ($Name in $WindowsReleaseTests) {
        $Source = Join-Path $ProjectRoot "tests\$Name"
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
            throw "Allowlisted source file is missing: tests/$Name"
        }
        $Files.Add([pscustomobject]@{ Source = $Source; Relative = "tests/$Name" })
    }
    foreach ($Relative in $ExplicitReleaseFiles) {
        $Source = Join-Path $ProjectRoot $Relative.Replace([char]47, [char]92)
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
            throw "Allowlisted source file is missing: $Relative"
        }
        $Files.Add([pscustomobject]@{ Source = $Source; Relative = $Relative })
    }
    return $Files.ToArray()
}

function Assert-PowerShellParser {
    $Names = @('common.ps1', 'install.ps1', 'start.ps1', 'verify.ps1', 'uninstall.ps1', 'build-release.ps1', 'verify-release.ps1', 'test-common.ps1')
    foreach ($Name in $Names) {
        $File = Join-Path $PSScriptRoot $Name
        $Tokens = $null
        $Errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($File, [ref]$Tokens, [ref]$Errors)
        if ($Errors.Count -gt 0) {
            $First = $Errors[0]
            throw "PowerShell parser error in $Name line $($First.Extent.StartLineNumber): $($First.Message)"
        }
    }
    $script:ParserStatus = 'PASS'
    Write-Host '[PASS] PowerShell parser'
}

function Invoke-TestGates {
    if ($SkipTests) {
        Write-Warning '-SkipTests was supplied. Python and installer helper tests are being skipped; all parser, security, staging, ZIP, and checksum gates remain enabled.'
        $script:PythonTestStatus = 'SKIPPED (warning)'
        $script:InstallerTestStatus = 'SKIPPED (warning)'
        Write-Host '[WARN] Python tests skipped'
        Write-Host '[WARN] Installer helper tests skipped'
        return
    }
    $Python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        throw 'A valid project .venv is required to run release Python tests.'
    }
    Push-Location -LiteralPath $ProjectRoot
    try { & $Python -B -m unittest discover -s 'tests' -v }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw 'Python tests failed; release build stopped.' }
    $script:PythonTestStatus = 'PASS'
    Write-Host '[PASS] Python tests'

    & $PowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test-common.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Installer helper tests failed; release build stopped.' }
    $script:InstallerTestStatus = 'PASS'
    Write-Host '[PASS] Installer helper tests'
}

function Assert-SafeDistTarget {
    param([Parameter(Mandatory)] [string]$Target)
    $DistFull = (Get-FullPath $DistRoot).TrimEnd([char[]]@([char]92, [char]47))
    $TargetFull = Get-FullPath $Target
    $Prefix = $DistFull + [IO.Path]::DirectorySeparatorChar
    if ($TargetFull -eq $DistFull -or -not $TargetFull.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unsafe path: $TargetFull"
    }
}

function Remove-DistItem {
    param([Parameter(Mandatory)] [string]$Target)
    Assert-SafeDistTarget $Target
    if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Recurse -Force }
}

function Copy-AllowlistedContent {
    New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null
    foreach ($DirectoryName in $AllowedDirectories) {
        $DestinationDirectory = Join-Path $StagingRoot $DirectoryName
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }
    foreach ($File in Get-AllowlistedSourceFiles) {
        $Destination = Join-Path $StagingRoot $File.Relative.Replace([char]47, [char]92)
        $DestinationParent = Split-Path -Parent $Destination
        if (-not (Test-Path -LiteralPath $DestinationParent)) { New-Item -ItemType Directory -Path $DestinationParent -Force | Out-Null }
        Copy-Item -LiteralPath $File.Source -Destination $Destination
    }
}

function New-ReleaseManifest {
    param([Parameter(Mandatory)] [string]$Version)
    $Settings = Get-Content -LiteralPath (Join-Path $StagingRoot 'config\settings.json') -Raw | ConvertFrom-Json
    $OllamaUri = [Uri]$Settings.ollama_url
    $Hashes = [ordered]@{}
    foreach ($File in Get-ChildItem -LiteralPath $StagingRoot -Recurse -Force -File | Sort-Object FullName) {
        $Relative = Get-ReleaseRelativePath $StagingRoot $File.FullName
        $Hashes[$Relative] = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
    }
    $Manifest = [ordered]@{
        product = 'blue-ai-assistant'
        version = $Version
        built_at_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        model = [string]$Settings.model
        blue_ai_host = [string]$Settings.listen_host
        blue_ai_port = [int]$Settings.listen_port
        ollama_host = $OllamaUri.Host
        ollama_port = $OllamaUri.Port
        files = $Hashes
    }
    $Manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $StagingRoot 'RELEASE_MANIFEST.json') -Encoding UTF8
}

function Invoke-ReleaseValidator {
    param(
        [Parameter(Mandatory)] [string]$PackagePath,
        [Parameter(Mandatory)] [string]$Version
    )
    & $PowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-release.ps1') -Path $PackagePath -ExpectedVersion $Version
    if ($LASTEXITCODE -ne 0) { throw "Release validation failed: $PackagePath" }
}

function Publish-File {
    param(
        [Parameter(Mandatory)] [string]$TemporaryPath,
        [Parameter(Mandatory)] [string]$FinalPath
    )
    Assert-SafeDistTarget $TemporaryPath
    Assert-SafeDistTarget $FinalPath
    $BackupPath = $null
    if (Test-Path -LiteralPath $FinalPath -PathType Leaf) {
        $BackupPath = $FinalPath + '.rollback.' + [guid]::NewGuid().ToString('N')
        Assert-SafeDistTarget $BackupPath
        [IO.File]::Replace((Get-FullPath $TemporaryPath), (Get-FullPath $FinalPath), (Get-FullPath $BackupPath), $true)
    } else {
        [IO.File]::Move((Get-FullPath $TemporaryPath), (Get-FullPath $FinalPath))
    }
    $script:PublishedArtifacts.Add([pscustomobject]@{ Final = $FinalPath; Backup = $BackupPath })
}

function Complete-Publication {
    foreach ($Artifact in $PublishedArtifacts) {
        if ($Artifact.Backup -and (Test-Path -LiteralPath $Artifact.Backup)) {
            Remove-Item -LiteralPath $Artifact.Backup -Force
        }
    }
    $PublishedArtifacts.Clear()
}

function Undo-Publication {
    for ($Index = $PublishedArtifacts.Count - 1; $Index -ge 0; $Index--) {
        $Artifact = $PublishedArtifacts[$Index]
        if (Test-Path -LiteralPath $Artifact.Final) {
            Remove-Item -LiteralPath $Artifact.Final -Force -ErrorAction SilentlyContinue
        }
        if ($Artifact.Backup -and (Test-Path -LiteralPath $Artifact.Backup)) {
            [IO.File]::Move((Get-FullPath $Artifact.Backup), (Get-FullPath $Artifact.Final))
        }
    }
    $PublishedArtifacts.Clear()
}

try {
    Write-Host 'Blue AI Assistant Release Build'
    Write-Host ''
    Assert-SourceStructure
    $Version = (Get-Content -LiteralPath (Join-Path $ProjectRoot 'VERSION') -Raw).Trim()
    if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'VERSION is not a valid release version.' }
    $ZipName = "blue-ai-assistant-v$Version-windows.zip"
    $ZipPath = Join-Path $DistRoot $ZipName
    $SidecarPath = $ZipPath + '.sha256'
    $ReportPath = Join-Path $DistRoot 'release-test-report.txt'
    Write-Host "Version: $Version"
    Write-Host "Output: $ZipPath"

    if ($DryRun) {
        Write-Host ''
        Write-Host '[DRY RUN] No directory or file will be created, removed, or changed.'
        Write-Host "Clean requested: $([bool]$Clean)"
        Write-Host "Tests: $(if ($SkipTests) { 'would be skipped with warning' } else { 'would run' })"
        Write-Host 'Included files:'
        foreach ($File in Get-PlannedFiles) { Write-Host "  $File" }
        Write-Host 'Excluded categories: Portal, capabilities, challenge/checker content, Lab material, .venv, caches, logs, state, Git/editor metadata, dist/build, local settings, and temporary/compiled files.'
        Write-Host 'Planned gates: Python tests, PowerShell parser, installer helper tests, forbidden files, sensitive material, absolute paths, localhost security, staging manifest/hashes, ZIP extraction, and SHA-256.'
        Write-Host '[DRY RUN] Release plan completed; no artifacts were created.'
        exit 0
    }

    New-Item -ItemType Directory -Path $DistRoot -Force | Out-Null
    if ($Clean) {
        Remove-DistItem $StagingRoot
        Remove-DistItem $ZipPath
        Remove-DistItem $SidecarPath
        Remove-DistItem $ReportPath
    } else {
        Remove-DistItem $StagingRoot
    }

    Assert-PowerShellParser
    Invoke-TestGates

    New-Item -ItemType Directory -Path $StagingParent -Force | Out-Null
    Copy-AllowlistedContent
    New-ReleaseManifest $Version
    Invoke-ReleaseValidator $StagingRoot $Version
    Write-Host '[PASS] Release staging'

    $ArtifactId = [guid]::NewGuid().ToString('N')
    $PartialZip = Join-Path $DistRoot ("blue-ai-assistant-v$Version-$ArtifactId.partial.zip")
    Compress-Archive -LiteralPath $StagingRoot -DestinationPath $PartialZip -CompressionLevel Optimal
    Write-Host '[PASS] ZIP creation'
    Invoke-ReleaseValidator $PartialZip $Version
    Write-Host '[PASS] ZIP extraction validation'

    $ZipHash = (Get-FileHash -LiteralPath $PartialZip -Algorithm SHA256).Hash.ToUpperInvariant()
    $TemporarySidecar = Join-Path $DistRoot ("$ZipName.$ArtifactId.partial.sha256")
    Set-Content -LiteralPath $TemporarySidecar -Value "$ZipHash  $ZipName" -Encoding ASCII

    $TemporaryReport = Join-Path $DistRoot ("release-test-report.$ArtifactId.partial.txt")
    $ReportLines = @(
        'Blue AI Assistant Release Test Report',
        "Version: $Version",
        "Built at UTC: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
        "Python tests: $PythonTestStatus",
        "PowerShell parser: $ParserStatus",
        "Installer helper tests: $InstallerTestStatus",
        'Forbidden files: PASS',
        'Secret scan: PASS',
        'Absolute paths: PASS',
        'AI-only package scope: PASS',
        'Red-template API compatibility: PASS',
        'Localhost security: PASS',
        'Staging validation: PASS',
        'ZIP validation: PASS',
        "SHA-256: $ZipHash"
    )
    Set-Content -LiteralPath $TemporaryReport -Value $ReportLines -Encoding UTF8

    Publish-File $PartialZip $ZipPath
    $PartialZip = $null
    Publish-File $TemporarySidecar $SidecarPath
    $TemporarySidecar = $null
    Publish-File $TemporaryReport $ReportPath
    $TemporaryReport = $null
    Complete-Publication
    Write-Host '[PASS] SHA-256'
    Write-Host ''
    Write-Host 'Release created:'
    Write-Host $ZipPath
    Write-Host "SHA-256: $ZipHash"
    Write-Host "Report: $ReportPath"
    exit 0
} catch {
    Undo-Publication
    [Console]::Error.WriteLine("BUILD FAIL: $($_.Exception.Message)")
    exit 1
} finally {
    foreach ($TemporaryPath in @($PartialZip, $TemporarySidecar, $TemporaryReport)) {
        if ($TemporaryPath -and (Test-Path -LiteralPath $TemporaryPath)) {
            Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}
