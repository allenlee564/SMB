[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param()

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Venv = Join-Path $ProjectRoot '.venv'

Write-Host 'This removes only the project .venv directory.'
Write-Host 'It does not remove Ollama, models, Python, source, or user settings.'
if ((Test-Path -LiteralPath $Venv) -and $PSCmdlet.ShouldProcess($Venv, 'Remove Blue AI Python virtual environment')) {
    Remove-Item -LiteralPath $Venv -Recurse -Force
    Write-Host '.venv was removed and can be recreated by install.ps1.'
} elseif (-not (Test-Path -LiteralPath $Venv)) {
    Write-Host '.venv does not exist; nothing to remove.'
}
