# maestrode installer for Windows (PowerShell). Works two ways:
#   1) iwr piped:  iwr -useb https://raw.githubusercontent.com/doedja/maestrode/main/install.ps1 | iex
#   2) from clone:  .\install.ps1   (uses the local src\maestrode file)
# Idempotent: safe to re-run.
#
# uninstall:
#   .\install.ps1 -Uninstall                (remove binary + config + sessions)
#   .\install.ps1 -Uninstall -KeepConfig    (remove binary only)
#
# requires:
#   - Git for Windows (provides bash.exe). Install: winget install Git.Git
#   - Python 3 on PATH (used by the shim for secret scan + payload build).
#     Install: winget install Python.Python.3.12
#
# notes:
#   - Installs to %USERPROFILE%\.local\bin (matches the Linux/macOS layout so
#     the underlying bash shim resolves $HOME/.config/maestrode/env the same
#     way under Git Bash).
#   - Creates a maestrode.cmd shim so `maestrode ...` works from cmd and
#     PowerShell. The shim invokes bash on the bash script.
#   - Adds the install dir to the user PATH (no admin needed). Restart the
#     shell to pick it up.

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$KeepConfig
)

$ErrorActionPreference = 'Stop'

$Repo    = if ($env:MAESTRODE_REPO)    { $env:MAESTRODE_REPO }    else { 'doedja/maestrode' }
$Branch  = if ($env:MAESTRODE_BRANCH)  { $env:MAESTRODE_BRANCH }  else { 'main' }
$InstallDir = if ($env:MAESTRODE_INSTALL_DIR) { $env:MAESTRODE_INSTALL_DIR } else { "$env:USERPROFILE\.local\bin" }
$ConfigDir  = if ($env:MAESTRODE_CONFIG_DIR)  { $env:MAESTRODE_CONFIG_DIR }  else { "$env:USERPROFILE\.config\maestrode" }
$RawBase = "https://raw.githubusercontent.com/$Repo/$Branch"

function Remove-PathEntry {
    param([string]$Dir)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { return }
    $parts = $userPath.Split(';') | Where-Object { $_ -and ($_ -ne $Dir) }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}

function Add-PathEntry {
    param([string]$Dir)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = if ($userPath) { $userPath.Split(';') } else { @() }
    if ($parts -contains $Dir) { return $false }
    $newPath = if ($userPath) { "$userPath;$Dir" } else { $Dir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    return $true
}

if ($Uninstall) {
    $removed = $false
    $bin = Join-Path $InstallDir 'maestrode'
    $cmd = Join-Path $InstallDir 'maestrode.cmd'
    foreach ($p in @($bin, $cmd)) {
        if (Test-Path $p) {
            Remove-Item -Force $p
            Write-Host "removed $p"
            $removed = $true
        }
    }
    if (-not $KeepConfig -and (Test-Path $ConfigDir)) {
        Remove-Item -Recurse -Force $ConfigDir
        Write-Host "removed $ConfigDir"
        $removed = $true
    }
    Remove-PathEntry $InstallDir
    if (-not $removed) {
        Write-Host "maestrode is not installed."
    } else {
        Write-Host "maestrode uninstalled. Restart your shell so PATH updates take effect."
    }
    exit 0
}

# Dependency checks
$bash = Get-Command bash.exe -ErrorAction SilentlyContinue
if (-not $bash) {
    Write-Host ""
    Write-Host "bash.exe not found on PATH." -ForegroundColor Red
    Write-Host "Install Git for Windows (includes Git Bash):"
    Write-Host "  winget install --id Git.Git -e --source winget"
    Write-Host "Then re-run this installer."
    exit 1
}

$py = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
if (-not $py) {
    Write-Warning "python not found on PATH. maestrode needs Python 3 for secret scanning and payload building."
    Write-Warning "Install: winget install --id Python.Python.3.12 -e"
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $ConfigDir  | Out-Null

# Prefer local clone source if present
$ScriptDir = $null
if ($PSCommandPath) { $ScriptDir = Split-Path -Parent $PSCommandPath }
elseif ($MyInvocation.MyCommand.Path) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

$LocalSrc = $null
if ($ScriptDir) {
    $candidate = Join-Path $ScriptDir 'src\maestrode'
    if (Test-Path $candidate) { $LocalSrc = $candidate }
}

$Target = Join-Path $InstallDir 'maestrode'

if ($LocalSrc) {
    Write-Host "Installing from local clone: $LocalSrc"
    Copy-Item -Force $LocalSrc $Target
} else {
    Write-Host "Downloading maestrode from $RawBase/src/maestrode ..."
    try {
        Invoke-WebRequest -Uri "$RawBase/src/maestrode" -OutFile $Target -UseBasicParsing
    } catch {
        Write-Host "error: failed to download maestrode: $_" -ForegroundColor Red
        exit 1
    }
    $firstLine = Get-Content $Target -TotalCount 1
    if ($firstLine -notmatch '^#!/usr/bin/env bash') {
        Remove-Item -Force $Target
        Write-Host "error: downloaded file does not look like a bash script" -ForegroundColor Red
        exit 1
    }
}

# .cmd wrapper so users can run `maestrode` from any Windows shell.
# %~dp0 is the wrapper's directory (with trailing backslash); bash on Windows
# accepts Windows-style paths via Git Bash's MSYS path translation.
$WrapperPath = Join-Path $InstallDir 'maestrode.cmd'
$Wrapper = @'
@echo off
bash "%~dp0maestrode" %*
'@
Set-Content -Path $WrapperPath -Value $Wrapper -Encoding ASCII

# Env template
$EnvFile = Join-Path $ConfigDir 'env'
if (-not (Test-Path $EnvFile)) {
    $envTemplate = @"
# maestrode env. fill in the API key, optionally swap endpoint/model.
# MAESTRODE_API_KEY=sk-...
# MAESTRODE_ENDPOINT=https://api.deepseek.com/v1/chat/completions
# MAESTRODE_MODEL=deepseek-v4-flash
"@
    Set-Content -Path $EnvFile -Value $envTemplate -Encoding UTF8
    Write-Host "wrote $EnvFile (edit it)"
}

# PATH
$added = Add-PathEntry $InstallDir
if ($added) {
    Write-Host "added $InstallDir to user PATH (restart your shell)"
}

Write-Host ""
Write-Host "installed maestrode to $Target"
Write-Host ""

$envContent = if (Test-Path $EnvFile) { Get-Content $EnvFile -Raw } else { '' }
if ($envContent -notmatch '(?m)^MAESTRODE_API_KEY=') {
    Write-Host "Next:"
    Write-Host "  1. edit $EnvFile and uncomment MAESTRODE_API_KEY=<your key>"
    Write-Host "  2. open a new shell and run: maestrode ""say pong"""
}
