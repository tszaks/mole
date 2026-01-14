#!/usr/bin/env pwsh
# Mole Quick Installer for Windows
# One-liner install: iwr -useb https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex

#Requires -Version 5.1

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Colors
$ESC = [char]27
$Colors = @{
    Green  = "$ESC[32m"
    Yellow = "$ESC[33m"
    Cyan   = "$ESC[36m"
    Red    = "$ESC[31m"
    NC     = "$ESC[0m"
}

function Write-Step {
    param([string]$Message)
    Write-Host "  $($Colors.Cyan)→$($Colors.NC) $Message"
}

function Write-Success {
    param([string]$Message)
    Write-Host "  $($Colors.Green)✓$($Colors.NC) $Message"
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "  $($Colors.Red)✗$($Colors.NC) $Message"
}

# Main installation
try {
    Write-Host ""
    Write-Host "  $($Colors.Cyan)Mole Quick Installer$($Colors.NC)"
    Write-Host "  $($Colors.Yellow)Installing experimental Windows version...$($Colors.NC)"
    Write-Host ""

    # Check prerequisites
    Write-Step "Checking prerequisites..."

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-ErrorMsg "Git is not installed. Please install Git first:"
        Write-Host "    https://git-scm.com/download/win"
        exit 1
    }

    Write-Success "Git found"

    # Create temp directory
    $TempDir = Join-Path $env:TEMP "mole-install-$(Get-Random)"
    Write-Step "Downloading Mole..."

    # Clone windows branch
    git clone --quiet --depth 1 --branch windows https://github.com/tw93/Mole.git $TempDir 2>&1 | Out-Null

    if (-not (Test-Path "$TempDir\install.ps1")) {
        Write-ErrorMsg "Failed to download installer"
        exit 1
    }

    Write-Success "Downloaded to temp directory"

    # Run installer
    Write-Step "Running installer..."
    Write-Host ""

    & "$TempDir\install.ps1" -AddToPath

    Write-Host ""
    Write-Success "Installation complete!"
    Write-Host ""
    Write-Host "  Run ${Colors.Green}mole$($Colors.NC) to get started"
    Write-Host ""

} catch {
    Write-ErrorMsg "Installation failed: $_"
    exit 1
} finally {
    # Cleanup
    if (Test-Path $TempDir) {
        Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
