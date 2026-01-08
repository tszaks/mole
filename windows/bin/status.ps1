# Mole - Status Command
# System status monitor wrapper

#Requires -Version 5.1
param(
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"

# Script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsDir = Split-Path -Parent $scriptDir
$binPath = Join-Path $windowsDir "bin\status.exe"

# Help
function Show-StatusHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mMole Status$esc[0m - Real-time system health monitor"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m mole status"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  -ShowHelp    Show this help message"
    Write-Host ""
    Write-Host "$esc[33mDisplays:$esc[0m"
    Write-Host "  - System health score (0-100)"
    Write-Host "  - CPU usage and model"
    Write-Host "  - Memory and swap usage"
    Write-Host "  - Disk space per drive"
    Write-Host "  - Top processes by CPU"
    Write-Host "  - Network interfaces"
    Write-Host ""
    Write-Host "$esc[33mKeybindings:$esc[0m"
    Write-Host "  c            Toggle mole animation"
    Write-Host "  r            Force refresh"
    Write-Host "  q            Quit"
    Write-Host ""
}

if ($ShowHelp) {
    Show-StatusHelp
    return
}

# Check if binary exists
if (-not (Test-Path $binPath)) {
    Write-Host "Building status tool..." -ForegroundColor Cyan
    
    $cmdDir = Join-Path $windowsDir "cmd\status"
    $binDir = Join-Path $windowsDir "bin"
    
    if (-not (Test-Path $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }
    
    Push-Location $windowsDir
    try {
        $result = & go build -o "$binPath" "./cmd/status/" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to build status tool: $result" -ForegroundColor Red
            Pop-Location
            return
        }
    }
    finally {
        Pop-Location
    }
}

# Run the binary
& $binPath
