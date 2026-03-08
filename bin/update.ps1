# Mole - Update Command
# Updates a source-channel installation from the windows branch.

#Requires -Version 5.1
param(
    [Alias('h')]
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsDir = Split-Path -Parent $scriptDir
$installScript = Join-Path $windowsDir "install.ps1"
$gitDir = Join-Path $windowsDir ".git"

function Show-UpdateHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mmo update$esc[0m - Update the Windows source channel"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m mo update"
    Write-Host ""
    Write-Host "$esc[33mBehavior:$esc[0m"
    Write-Host "  - Pulls the latest commit from origin/windows"
    Write-Host "  - Re-runs the local installer in-place"
    Write-Host "  - Rebuilds analyze/status if Go is available"
    Write-Host ""
    Write-Host "$esc[33mNotes:$esc[0m"
    Write-Host "  - Works only for git-based source installs"
    Write-Host "  - Legacy copied installs should be reinstalled with quick-install"
    Write-Host ""
}

function Invoke-GitCommand {
    param(
        [string]$WorkingDirectory,
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $previousNativeErrorPreference = $null
    $hasNativeErrorPreference = $false

    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        $hasNativeErrorPreference = $true
    }

    try {
        $gitArguments = @()
        if ($WorkingDirectory) {
            $gitArguments += @("-C", $WorkingDirectory)
        }
        $gitArguments += $Arguments

        $output = & git @gitArguments 2>&1
        $exitCode = $LASTEXITCODE

        return [pscustomobject]@{
            ExitCode = $exitCode
            Text = ((@($output) | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
        }
    }
    finally {
        if ($hasNativeErrorPreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
        }
    }
}

function Test-InstallDirOnUserPath {
    param([string]$Path)

    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if (-not $currentPath) {
        return $false
    }

    return $currentPath -split ";" | Where-Object { $_ -eq $Path }
}

if ($ShowHelp) {
    Show-UpdateHelp
    return
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Git is not installed. Install Git to use 'mo update'." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $installScript)) {
    Write-Host "Installer not found at: $installScript" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $gitDir)) {
    Write-Host "This installation is not a git-based source install." -ForegroundColor Red
    Write-Host "Reinstall with quick-install to enable 'mo update'." -ForegroundColor Yellow
    exit 1
}

$dirtyStatus = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("status", "--porcelain", "--untracked-files=no")
if ($dirtyStatus.ExitCode -ne 0) {
    Write-Host "Failed to inspect git status: $($dirtyStatus.Text)" -ForegroundColor Red
    exit 1
}

if ($dirtyStatus.Text) {
    Write-Host "Local tracked changes detected in the installation directory." -ForegroundColor Red
    Write-Host "Commit or discard them before running 'mo update'." -ForegroundColor Yellow
    exit 1
}

$remoteResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("remote", "get-url", "origin")
$remote = $remoteResult.Text
if ($remoteResult.ExitCode -ne 0 -or -not $remote) {
    Write-Host "Git remote 'origin' is not configured for this install." -ForegroundColor Red
    exit 1
}

$branchResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("branch", "--show-current")
$branch = $branchResult.Text
if ($branchResult.ExitCode -ne 0 -or -not $branch) {
    $branch = "windows"
}

$beforeResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("rev-parse", "--short", "HEAD")
$before = $beforeResult.Text
if ($beforeResult.ExitCode -ne 0 -or -not $before) {
    Write-Host "Failed to read current revision." -ForegroundColor Red
    exit 1
}

Write-Host "Updating source from $remote ($branch)..." -ForegroundColor Cyan

$pullResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("pull", "--ff-only", "origin", $branch)
if ($pullResult.ExitCode -ne 0) {
    Write-Host "Failed to update source: $($pullResult.Text)" -ForegroundColor Red
    exit 1
}

$afterResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("rev-parse", "--short", "HEAD")
$after = $afterResult.Text
if ($afterResult.ExitCode -ne 0 -or -not $after) {
    Write-Host "Updated source, but failed to read the new revision." -ForegroundColor Red
    exit 1
}

if ($after -eq $before) {
    Write-Host "Already up to date at $after." -ForegroundColor Green
}
else {
    Write-Host "Updated source: $before -> $after" -ForegroundColor Green
}

$installArgs = @(
    "-InstallDir", $windowsDir
)

if (Test-InstallDirOnUserPath -Path $windowsDir) {
    $installArgs += "-AddToPath"
}

Write-Host "Refreshing local installation..." -ForegroundColor Cyan
& $installScript @installArgs
