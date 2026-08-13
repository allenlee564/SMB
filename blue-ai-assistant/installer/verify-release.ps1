[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [Alias('PackagePath')]
    [string]$Path,
    [string]$ExpectedVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot

function Write-Pass {
    param([Parameter(Mandatory)] [string]$Name)
    Write-Host "[PASS] $Name"
}

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
        throw 'A package item resolved outside the release root.'
    }
    return $ItemFull.Substring($Prefix.Length).Replace([char]92, [char]47)
}

function Test-ForbiddenReleasePath {
    param([Parameter(Mandatory)] [string]$RelativePath)
    $Normalized = $RelativePath.Replace([char]92, [char]47)
    $Segments = @($Normalized.Split([char]47))
    $ForbiddenDirectories = @(
        '.venv', '__pycache__', 'logs', 'state', '.git', '.github', '.vscode',
        '.idea', '.pytest_cache', 'dist', 'build'
    )
    foreach ($Segment in $Segments) {
        if ($ForbiddenDirectories -contains $Segment.ToLowerInvariant()) { return $true }
    }
    $Leaf = $Segments[$Segments.Count - 1].ToLowerInvariant()
    if ($Leaf -in @('.coverage', 'thumbs.db', 'desktop.ini', 'settings.local.json', '.env')) { return $true }
    return [bool]($Leaf -match '\.(?:pyc|pyo|log|tmp|bak)$')
}

function Get-TextFiles {
    param([Parameter(Mandatory)] [string]$Root)
    $Extensions = @('.ps1', '.psm1', '.py', '.json', '.md', '.txt', '.ini', '.cfg', '.toml', '.yaml', '.yml', '.env')
    return @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Where-Object {
        $Extensions -contains $_.Extension.ToLowerInvariant()
    })
}

function Assert-ProjectStructure {
    param([Parameter(Mandatory)] [string]$Root)
    $RequiredDirectories = @('api', 'core', 'config', 'installer', 'tests')
    $RequiredFiles = @('requirements.txt', 'README.md', 'VERSION', 'RELEASE_NOTES.md', 'RELEASE_MANIFEST.json')
    foreach ($Name in $RequiredDirectories) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $Name) -PathType Container)) {
            throw "Required release directory is missing: $Name"
        }
    }
    foreach ($Name in $RequiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $Name) -PathType Leaf)) {
            throw "Required release file is missing: $Name"
        }
    }

    $AllowedTopLevel = @($RequiredDirectories + $RequiredFiles)
    foreach ($Item in Get-ChildItem -LiteralPath $Root -Force) {
        if ($AllowedTopLevel -notcontains $Item.Name) {
            throw "Unexpected top-level release item: $($Item.Name)"
        }
    }

    $RuntimeInstallerFiles = @('common.ps1', 'install.ps1', 'start.ps1', 'verify.ps1', 'uninstall.ps1', 'test-common.ps1')
    foreach ($File in Get-ChildItem -LiteralPath $Root -Recurse -Force -File) {
        $Relative = Get-ReleaseRelativePath $Root $File.FullName
        $Segments = @($Relative.Split([char]47))
        $Top = $Segments[0]
        $Allowed = $false
        if ($Top -in @('api', 'core', 'tests')) {
            $Allowed = ($File.Extension -eq '.py' -and $Segments.Count -ge 2)
        } elseif ($Top -eq 'config') {
            $Allowed = ($Relative -eq 'config/settings.json')
        } elseif ($Top -eq 'installer') {
            $Allowed = ($Segments.Count -eq 2 -and $RuntimeInstallerFiles -contains $Segments[1])
        } else {
            $Allowed = ($Segments.Count -eq 1 -and $RequiredFiles -contains $Relative)
        }
        if (-not $Allowed) { throw "File is outside the release file allowlist: $Relative" }
    }
    Write-Pass 'Project structure'
}

function Assert-NoForbiddenFiles {
    param([Parameter(Mandatory)] [string]$Root)
    foreach ($Item in Get-ChildItem -LiteralPath $Root -Recurse -Force) {
        $Relative = Get-ReleaseRelativePath $Root $Item.FullName
        if (Test-ForbiddenReleasePath $Relative) {
            throw "Forbidden release item: $Relative"
        }
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points are not permitted in a release: $Relative"
        }
    }
    Write-Pass 'Forbidden-file scan'
}

function Assert-NoSecrets {
    param([Parameter(Mandatory)] [string]$Root)
    $SensitiveName = '(?:pass' + 'word|pass' + 'wd|sec' + 'ret|to' + 'ken|api[_-]?key|private[_-]?key)'
    $Patterns = @(
        [pscustomobject]@{ Name = 'private-key block'; Pattern = ('-----BEGIN ' + '(?:RSA |EC |OPENSSH )?PRIVATE KEY-----') },
        [pscustomobject]@{ Name = 'credential assignment'; Pattern = ('(?im)^\s*["'']?' + $SensitiveName + '["'']?\s*[:=]\s*(?!["'']?(?:null|none|false|true|example|redacted|changeme|<[^>]+>|\$\{|\{\{)\b)["'']?[^\s"'']{4,}') },
        [pscustomobject]@{ Name = 'authorization credential'; Pattern = ('(?i)\bAuthoriz' + 'ation\s*:\s*(?:Bear' + 'er|Basic)\s+\S+') },
        [pscustomobject]@{ Name = 'bearer credential'; Pattern = ('(?i)\bBear' + 'er\s+[A-Za-z0-9._~+/=-]{12,}') },
        [pscustomobject]@{ Name = 'AWS access key'; Pattern = '\bAKIA[0-9A-Z]{16}\b' }
    )
    foreach ($File in Get-TextFiles $Root) {
        $Content = [IO.File]::ReadAllText($File.FullName)
        foreach ($Rule in $Patterns) {
            if ([regex]::IsMatch($Content, $Rule.Pattern)) {
                $Relative = Get-ReleaseRelativePath $Root $File.FullName
                throw "Potential sensitive material detected: file=$Relative rule=$($Rule.Name)"
            }
        }
    }
    Write-Pass 'Secret scan'
}

function Assert-NoAbsolutePaths {
    param([Parameter(Mandatory)] [string]$Root)
    $DrivePathRule = '(?i)(?<![A-Za-z0-9])(?:[A-Z]:[\\/](?:Users|Documents and Settings|home|development|dev|src|work|workspace)[\\/])'
    $UncUserPathRule = '(?i)\\\\[^\\\r\n]+\\(?:Users|home)\\'
    foreach ($File in Get-TextFiles $Root) {
        $Content = [IO.File]::ReadAllText($File.FullName)
        if ([regex]::IsMatch($Content, $DrivePathRule) -or [regex]::IsMatch($Content, $UncUserPathRule)) {
            $Relative = Get-ReleaseRelativePath $Root $File.FullName
            throw "Machine-specific absolute path detected: $Relative"
        }
    }
    Write-Pass 'Absolute-path scan'
}

function Assert-AiOnlyScope {
    param([Parameter(Mandatory)] [string]$Root)
    foreach ($Forbidden in @('portal', 'knowledge', 'docs')) {
        if (Test-Path -LiteralPath (Join-Path $Root $Forbidden)) {
            throw "Out-of-scope release directory is present: $Forbidden"
        }
    }
    $ApiSource = [IO.File]::ReadAllText((Join-Path $Root 'api\server.py'), [Text.Encoding]::UTF8)
    if (-not $ApiSource.Contains('"/api/generate"')) {
        throw 'The Red-Team compatible /api/generate endpoint is missing.'
    }
    foreach ($Route in @('/api/score', '/api/session', '/api/challenges', '/retest')) {
        if ($ApiSource.Contains($Route)) { throw "Out-of-scope API route is present: $Route" }
    }
    Write-Pass 'AI-only package scope'
}

function Get-PropertyValue {
    param($Object, [Parameter(Mandatory)] [string]$Name)
    if ($null -eq $Object) { return $null }
    $Property = $Object.PSObject.Properties[$Name]
    if ($null -eq $Property) { return $null }
    return $Property.Value
}

function Assert-LocalhostSecurity {
    param([Parameter(Mandatory)] [string]$Root)
    $SettingsPath = Join-Path $Root 'config\settings.json'
    try { $Settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json }
    catch { throw "settings.json is not valid JSON: $($_.Exception.Message)" }
    if ((Get-PropertyValue $Settings 'listen_host') -ne '127.0.0.1') {
        throw 'Blue AI listen_host must be 127.0.0.1.'
    }
    if ([int](Get-PropertyValue $Settings 'listen_port') -ne 8765) {
        throw 'Blue AI listen_port must be 8765.'
    }
    try { $OllamaUri = [Uri](Get-PropertyValue $Settings 'ollama_url') }
    catch { throw 'The Ollama URL in settings.json is invalid.' }
    if ($OllamaUri.Host -ne '127.0.0.1' -or $OllamaUri.Port -ne 11434) {
        throw 'Ollama must use 127.0.0.1:11434.'
    }

    $UnsafeAddressRule = @('0', '0', '0', '0') -join '\.'
    $BindingRule = '(?im)^(?!\s*(?:#|//)).*(?:host|bind|listen)[^\r\n]{0,100}' + $UnsafeAddressRule + '|' + $UnsafeAddressRule + '[^\r\n]{0,100}(?:host|bind|listen)'
    $RuntimeRoots = @('api', 'core', 'config', 'installer')
    foreach ($RuntimeRoot in $RuntimeRoots) {
        $RuntimePath = Join-Path $Root $RuntimeRoot
        foreach ($File in Get-TextFiles $RuntimePath) {
            $Content = [IO.File]::ReadAllText($File.FullName)
            if ([regex]::IsMatch($Content, $BindingRule)) {
                $Relative = Get-ReleaseRelativePath $Root $File.FullName
                throw "Non-loopback wildcard binding detected in runtime content: $Relative"
            }
        }
    }
    Write-Pass 'Localhost security'
}

function Assert-PowerShellParser {
    param([Parameter(Mandatory)] [string]$Root)
    $PowerShellFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'installer') -Filter '*.ps1' -File)
    if ($PowerShellFiles.Count -eq 0) { throw 'No installer PowerShell scripts were found.' }
    foreach ($File in $PowerShellFiles) {
        $Tokens = $null
        $Errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$Tokens, [ref]$Errors)
        if ($Errors.Count -gt 0) {
            $First = $Errors[0]
            throw "PowerShell parser error in $($File.Name) line $($First.Extent.StartLineNumber): $($First.Message)"
        }
    }
    Write-Pass 'PowerShell parser'
}

function Assert-ReleaseManifest {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [string]$RequiredVersion
    )
    $Version = (Get-Content -LiteralPath (Join-Path $Root 'VERSION') -Raw).Trim()
    if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'VERSION is not a valid release version.' }
    if ($RequiredVersion -and $Version -ne $RequiredVersion) {
        throw "VERSION mismatch: expected $RequiredVersion but found $Version"
    }

    $ManifestPath = Join-Path $Root 'RELEASE_MANIFEST.json'
    try { $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json }
    catch { throw "RELEASE_MANIFEST.json is not valid JSON: $($_.Exception.Message)" }
    if ((Get-PropertyValue $Manifest 'product') -ne 'blue-ai-assistant') { throw 'Manifest product is invalid.' }
    if ((Get-PropertyValue $Manifest 'version') -ne $Version) { throw 'Manifest version does not match VERSION.' }
    if ((Get-PropertyValue $Manifest 'model') -ne 'qwen2.5:3b') { throw 'Manifest model is invalid.' }
    if ((Get-PropertyValue $Manifest 'blue_ai_host') -ne '127.0.0.1' -or [int](Get-PropertyValue $Manifest 'blue_ai_port') -ne 8765) {
        throw 'Manifest Blue AI endpoint is invalid.'
    }
    if ((Get-PropertyValue $Manifest 'ollama_host') -ne '127.0.0.1' -or [int](Get-PropertyValue $Manifest 'ollama_port') -ne 11434) {
        throw 'Manifest Ollama endpoint is invalid.'
    }
    $BuiltAt = [string](Get-PropertyValue $Manifest 'built_at_utc')
    $ParsedBuiltAt = [DateTimeOffset]::MinValue
    if (-not $BuiltAt.EndsWith('Z') -or -not [DateTimeOffset]::TryParse($BuiltAt, [ref]$ParsedBuiltAt)) {
        throw 'Manifest built_at_utc must be an ISO 8601 UTC timestamp.'
    }

    $AllowedProperties = @('product', 'version', 'built_at_utc', 'model', 'blue_ai_host', 'blue_ai_port', 'ollama_host', 'ollama_port', 'files')
    foreach ($Property in $Manifest.PSObject.Properties) {
        if ($AllowedProperties -notcontains $Property.Name) {
            throw "Manifest contains disallowed metadata: $($Property.Name)"
        }
    }

    $ManifestFiles = Get-PropertyValue $Manifest 'files'
    if ($null -eq $ManifestFiles) { throw 'Manifest file hashes are missing.' }
    $ExpectedFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Where-Object {
        $_.FullName -ne $ManifestPath
    } | ForEach-Object { Get-ReleaseRelativePath $Root $_.FullName } | Sort-Object)
    $HashProperties = @($ManifestFiles.PSObject.Properties)
    if ($HashProperties.Count -ne $ExpectedFiles.Count) { throw 'Manifest file list does not match package contents.' }
    foreach ($Relative in $ExpectedFiles) {
        $HashProperty = $ManifestFiles.PSObject.Properties[$Relative]
        if ($null -eq $HashProperty -or [string]$HashProperty.Value -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "Manifest hash is missing or invalid: $Relative"
        }
        $ActualHash = (Get-FileHash -LiteralPath (Join-Path $Root $Relative.Replace([char]47, [char]92)) -Algorithm SHA256).Hash
        if ($ActualHash -ne [string]$HashProperty.Value) { throw "Manifest hash mismatch: $Relative" }
    }
    Write-Pass 'Release manifest and file hashes'
    return $Version
}

function Invoke-DirectoryValidation {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [string]$RequiredVersion
    )
    if ((Split-Path -Leaf $Root) -ne 'blue-ai-assistant') {
        throw 'The release root directory must be named blue-ai-assistant.'
    }
    Assert-ProjectStructure $Root
    Assert-NoForbiddenFiles $Root
    Assert-NoSecrets $Root
    Assert-NoAbsolutePaths $Root
    Assert-AiOnlyScope $Root
    Assert-LocalhostSecurity $Root
    Assert-PowerShellParser $Root
    $Version = Assert-ReleaseManifest $Root $RequiredVersion
    Write-Pass 'Release package validation'
    return $Version
}

$TemporaryExtraction = $null
try {
    if (-not $Path) { $Path = Join-Path $ProjectRoot 'dist\staging\blue-ai-assistant' }
    $InputPath = Get-FullPath $Path
    if (Test-Path -LiteralPath $InputPath -PathType Container) {
        $ValidatedVersion = Invoke-DirectoryValidation $InputPath $ExpectedVersion
    } elseif (Test-Path -LiteralPath $InputPath -PathType Leaf) {
        if ([IO.Path]::GetExtension($InputPath) -ne '.zip') { throw 'Release validation accepts only a package directory or ZIP file.' }
        $TemporaryExtraction = Join-Path ([IO.Path]::GetTempPath()) ('blue-ai-release-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $TemporaryExtraction | Out-Null
        Expand-Archive -LiteralPath $InputPath -DestinationPath $TemporaryExtraction -Force
        $TopLevel = @(Get-ChildItem -LiteralPath $TemporaryExtraction -Force)
        if ($TopLevel.Count -ne 1 -or -not $TopLevel[0].PSIsContainer -or $TopLevel[0].Name -ne 'blue-ai-assistant') {
            throw 'ZIP must contain exactly one top-level blue-ai-assistant directory.'
        }
        Write-Pass 'ZIP root structure'
        $ValidatedVersion = Invoke-DirectoryValidation $TopLevel[0].FullName $ExpectedVersion
        Write-Pass 'ZIP extraction validation'
    } else {
        throw "Release path was not found: $InputPath"
    }
    Write-Host "Release validation succeeded. Version: $ValidatedVersion"
    exit 0
} catch {
    [Console]::Error.WriteLine("RELEASE VALIDATION FAIL: $($_.Exception.Message)")
    exit 1
} finally {
    if ($TemporaryExtraction -and (Test-Path -LiteralPath $TemporaryExtraction)) {
        Remove-Item -LiteralPath $TemporaryExtraction -Recurse -Force -ErrorAction SilentlyContinue
    }
}
