[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MetisOrigin,

    [switch]$SkipModelPull
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ExampleConfig = Join-Path $ProjectRoot "config\settings.example.json"
$RuntimeConfig = Join-Path $ProjectRoot "config\settings.json"
$InstallScript = Join-Path $PSScriptRoot "install.ps1"

Write-Host "============================================"
Write-Host " Blue AI Assistant - First Run"
Write-Host "============================================"
Write-Host ""

if (-not (Test-Path $ExampleConfig)) {
    throw "找不到 config\settings.example.json"
}

if (-not $MetisOrigin.StartsWith("http://") -and
    -not $MetisOrigin.StartsWith("https://")) {
    throw "MetisOrigin 必須是完整 Origin，例如 http://192.168.1.50:17681"
}

try {
    $uri = [Uri]$MetisOrigin
} catch {
    throw "MetisOrigin 格式錯誤：$MetisOrigin"
}

if (-not $uri.Host) {
    throw "MetisOrigin 缺少 Host"
}

# Origin 不應包含 path
$origin = "{0}://{1}" -f $uri.Scheme, $uri.Authority

Write-Host "[1/3] 建立本機設定"
Write-Host "Metis Origin: $origin"

$config = Get-Content $ExampleConfig -Raw | ConvertFrom-Json

$config.allowed_origins = @(
    $origin
)

$json = $config | ConvertTo-Json -Depth 10

# 使用 UTF-8 without BOM，避免 Python JSON 讀取問題
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText(
    $RuntimeConfig,
    $json,
    $utf8NoBom
)

Write-Host "設定完成：config\settings.json"
Write-Host ""

Write-Host "[2/3] 安裝 Blue AI 執行環境"

$arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $InstallScript,
    "-AcceptTerms",
    "-InstallPrerequisites"
)

if (-not $SkipModelPull) {
    $arguments += "-PullModel"
}

& powershell.exe @arguments

if ($LASTEXITCODE -ne 0) {
    throw "Blue AI 安裝或驗證失敗。"
}

Write-Host ""
Write-Host "[3/3] First Run 完成"
Write-Host ""
Write-Host "Blue AI API : http://127.0.0.1:8765"
Write-Host "Ollama      : http://127.0.0.1:11434"
Write-Host "Model       : qwen2.5:3b"
Write-Host ""
Write-Host "接下來執行："
Write-Host ""
Write-Host "powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\start.ps1"
Write-Host ""
Write-Host "停止服務：Ctrl+C"
