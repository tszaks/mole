# Mole - Analyze Command
# Disk space analyzer wrapper

#Requires -Version 5.1
param(
    [Parameter(Position = 0)]
    [string]$Path,
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"

# Script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsDir = Split-Path -Parent $scriptDir
$binPath = Join-Path $windowsDir "bin\analyze.exe"

# Help
function Show-AnalyzeHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mMole Analyze$esc[0m - Interactive disk space analyzer"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m mole analyze [path]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  [path]       Path to analyze (default: user profile)"
    Write-Host "  -ShowHelp    Show this help message"
    Write-Host ""
    Write-Host "$esc[33mKeybindings:$esc[0m"
    Write-Host "  Up/Down      Navigate entries"
    Write-Host "  Enter        Enter directory"
    Write-Host "  Backspace    Go back"
    Write-Host "  Space        Multi-select"
    Write-Host "  d            Delete selected"
    Write-Host "  f            Toggle large files view"
    Write-Host "  o            Open in Explorer"
    Write-Host "  r            Refresh"
    Write-Host "  q            Quit"
    Write-Host ""
}

if ($ShowHelp) {
    Show-AnalyzeHelp
    return
}

# Check if binary exists
if (-not (Test-Path $binPath)) {
    Write-Host "Building analyze tool..." -ForegroundColor Cyan
    
    $cmdDir = Join-Path $windowsDir "cmd\analyze"
    $binDir = Join-Path $windowsDir "bin"
    
    if (-not (Test-Path $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }
    
    Push-Location $windowsDir
    try {
        $result = & go build -o "$binPath" "./cmd/analyze/" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to build analyze tool: $result" -ForegroundColor Red
            Pop-Location
            return
        }
    }
    finally {
        Pop-Location
    }
}

# Set path environment variable if provided
if ($Path) {
    $env:MO_ANALYZE_PATH = $Path
}

# Run the binary
& $binPath
