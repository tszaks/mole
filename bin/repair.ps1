# Mole - Repair Command
# System repair utilities for Windows (cache rebuilds, resets)

#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$DebugMode,
    [switch]$ShowHelp,
    [switch]$All,
    [switch]$DNS,
    [switch]$Font,
    [switch]$Icon,
    [switch]$Search,
    [switch]$Store
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path (Split-Path -Parent $scriptDir) "lib"

# Import core modules
. "$libDir\core\base.ps1"
. "$libDir\core\log.ps1"
. "$libDir\core\ui.ps1"

# ============================================================================
# Configuration
# ============================================================================

$script:RepairsApplied = 0
$script:IsDryRun = $DryRun -or ($env:MOLE_DRY_RUN -eq "1")

# ============================================================================
# Help
# ============================================================================

function Show-RepairHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mMole Repair$esc[0m - System repair utilities"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m mole repair [options]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  -All         Run all repairs"
    Write-Host "  -DNS         Flush DNS cache"
    Write-Host "  -Font        Rebuild font cache"
    Write-Host "  -Icon        Rebuild icon cache"
    Write-Host "  -Search      Reset Windows Search index"
    Write-Host "  -Store       Reset Windows Store cache"
    Write-Host ""
    Write-Host "  -DryRun      Preview repairs without applying"
    Write-Host "  -DebugMode   Enable debug logging"
    Write-Host "  -ShowHelp    Show this help message"
    Write-Host ""
    Write-Host "$esc[33mExamples:$esc[0m"
    Write-Host "  mole repair -DNS          Flush DNS cache"
    Write-Host "  mole repair -Icon -Font   Rebuild icon and font caches"
    Write-Host "  mole repair -All          Run all repairs"
    Write-Host ""
}

# ============================================================================
# Repair Functions
# ============================================================================

function Repair-DnsCache {
    <#
    .SYNOPSIS
        Flush DNS resolver cache
    .DESCRIPTION
        Clears the DNS client cache, forcing fresh DNS lookups.
        Useful when DNS records have changed or you're having connectivity issues.
    #>
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) DNS Cache Flush$esc[0m"
    
    if ($script:IsDryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would flush DNS cache"
        $script:RepairsApplied++
        return
    }
    
    try {
        Clear-DnsClientCache -ErrorAction Stop
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m DNS cache flushed successfully"
        $script:RepairsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Could not flush DNS cache: $_"
    }
}

function Repair-FontCache {
    <#
    .SYNOPSIS
        Rebuild Windows font cache
    .DESCRIPTION
        Stops the font cache service, clears the cache files, and restarts.
        Fixes issues with fonts not displaying correctly or missing fonts.
    #>
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Font Cache Rebuild$esc[0m"
    
    if (-not (Test-IsAdmin)) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Requires administrator privileges"
        return
    }
    
    # Font cache locations
    $fontCachePaths = @(
        "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
        "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache"
        "$env:WINDIR\System32\FNTCACHE.DAT"
    )
    
    if ($script:IsDryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would stop Windows Font Cache Service"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would delete font cache files"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would restart Windows Font Cache Service"
        $script:RepairsApplied++
        return
    }
    
    try {
        # Stop font cache service
        Write-Host "  $esc[90mStopping Font Cache Service...$esc[0m"
        Stop-Service -Name "FontCache" -Force -ErrorAction SilentlyContinue
        Stop-Service -Name "FontCache3.0.0.0" -Force -ErrorAction SilentlyContinue
        
        # Wait a moment for service to stop
        Start-Sleep -Seconds 2
        
        # Delete font cache files
        foreach ($path in $fontCachePaths) {
            if (Test-Path $path) {
                if (Test-Path $path -PathType Container) {
                    # Directory - clear contents
                    Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | 
                        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
                }
                else {
                    # File - delete it
                    Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
                }
            }
        }
        
        # Restart font cache service
        Write-Host "  $esc[90mRestarting Font Cache Service...$esc[0m"
        Start-Service -Name "FontCache" -ErrorAction SilentlyContinue
        Start-Service -Name "FontCache3.0.0.0" -ErrorAction SilentlyContinue
        
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Font cache rebuilt successfully"
        Write-Host "  $esc[90mNote: Some apps may need restart to see changes$esc[0m"
        $script:RepairsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Could not rebuild font cache: $_"
        # Try to restart services even if we failed
        Start-Service -Name "FontCache" -ErrorAction SilentlyContinue
    }
}

function Repair-IconCache {
    <#
    .SYNOPSIS
        Rebuild Windows icon cache
    .DESCRIPTION
        Clears the icon cache database files, forcing Windows to rebuild them.
        Fixes issues with missing, corrupted, or outdated icons.
    #>
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Icon Cache Rebuild$esc[0m"
    
    # Icon cache locations
    $iconCachePath = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    $thumbCachePath = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    
    if ($script:IsDryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would stop Explorer"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would delete icon cache files (iconcache_*.db)"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would restart Explorer"
        $script:RepairsApplied++
        return
    }
    
    try {
        Write-Host "  $esc[90mStopping Explorer...$esc[0m"
        
        # Kill explorer (will restart automatically, or we restart it)
        Stop-Process -Name "explorer" -Force -ErrorAction SilentlyContinue
        
        # Wait for explorer to fully stop
        Start-Sleep -Seconds 2
        
        # Delete icon cache files
        $iconCacheFiles = Get-ChildItem -Path $iconCachePath -Filter "iconcache_*.db" -Force -ErrorAction SilentlyContinue
        $thumbCacheFiles = Get-ChildItem -Path $thumbCachePath -Filter "thumbcache_*.db" -Force -ErrorAction SilentlyContinue
        
        $deletedCount = 0
        foreach ($file in $iconCacheFiles) {
            Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
            $deletedCount++
        }
        
        # Also clear thumbcache for good measure
        foreach ($file in $thumbCacheFiles) {
            Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
            $deletedCount++
        }
        
        # Also clear the system-wide icon cache
        $systemIconCache = "$env:LOCALAPPDATA\IconCache.db"
        if (Test-Path $systemIconCache) {
            Remove-Item -Path $systemIconCache -Force -ErrorAction SilentlyContinue
            $deletedCount++
        }
        
        Write-Host "  $esc[90mRestarting Explorer...$esc[0m"
        
        # Restart explorer
        Start-Process "explorer.exe"
        
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Icon cache rebuilt ($deletedCount files cleared)"
        Write-Host "  $esc[90mNote: Icons will rebuild gradually as you browse$esc[0m"
        $script:RepairsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Could not rebuild icon cache: $_"
        # Make sure explorer is running
        Start-Process "explorer.exe" -ErrorAction SilentlyContinue
    }
}

function Repair-SearchIndex {
    <#
    .SYNOPSIS
        Reset Windows Search index
    .DESCRIPTION
        Stops the Windows Search service, deletes the search index, and restarts.
        Fixes issues with search not finding files or returning incorrect results.
        Note: Rebuilding the index can take hours depending on file count.
    #>
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Windows Search Index Reset$esc[0m"
    
    if (-not (Test-IsAdmin)) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Requires administrator privileges"
        return
    }
    
    $searchIndexPath = "$env:ProgramData\Microsoft\Search\Data\Applications\Windows"
    
    if ($script:IsDryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would stop Windows Search service"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would delete search index database"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would restart Windows Search service"
        $script:RepairsApplied++
        return
    }
    
    try {
        Write-Host "  $esc[90mStopping Windows Search service...$esc[0m"
        Stop-Service -Name "WSearch" -Force -ErrorAction Stop
        
        # Wait for service to fully stop
        Start-Sleep -Seconds 3
        
        # Delete search index
        if (Test-Path $searchIndexPath) {
            Write-Host "  $esc[90mDeleting search index...$esc[0m"
            Remove-Item -Path "$searchIndexPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        Write-Host "  $esc[90mRestarting Windows Search service...$esc[0m"
        Start-Service -Name "WSearch" -ErrorAction Stop
        
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Search index reset successfully"
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Indexing will rebuild in the background (may take hours)"
        $script:RepairsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Could not reset search index: $_"
        # Try to restart service
        Start-Service -Name "WSearch" -ErrorAction SilentlyContinue
    }
}

function Repair-StoreCache {
    <#
    .SYNOPSIS
        Reset Windows Store cache
    .DESCRIPTION
        Runs wsreset.exe to clear the Windows Store cache.
        Fixes issues with Store apps not installing, updating, or launching.
    #>
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Windows Store Cache Reset$esc[0m"
    
    if ($script:IsDryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would run wsreset.exe"
        $script:RepairsApplied++
        return
    }
    
    try {
        Write-Host "  $esc[90mResetting Windows Store cache...$esc[0m"
        
        # wsreset.exe clears the store cache and reopens the Store
        $wsreset = Start-Process -FilePath "wsreset.exe" -PassThru -WindowStyle Hidden
        
        # Wait for it to complete (usually quick)
        $wsreset.WaitForExit(30000)  # 30 second timeout
        
        if ($wsreset.ExitCode -eq 0) {
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Windows Store cache reset successfully"
            $script:RepairsApplied++
        }
        else {
            Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m wsreset completed with code $($wsreset.ExitCode)"
            $script:RepairsApplied++
        }
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Could not reset Store cache: $_"
    }
}

# ============================================================================
# Interactive Menu
# ============================================================================

function Show-RepairMenu {
    $esc = [char]27
    
    $menuItems = @(
        @{ Key = "1"; Label = "DNS Cache"; Desc = "Flush DNS resolver cache"; Action = { Repair-DnsCache } }
        @{ Key = "2"; Label = "Font Cache"; Desc = "Rebuild font cache (Admin)"; Action = { Repair-FontCache } }
        @{ Key = "3"; Label = "Icon Cache"; Desc = "Rebuild icon cache"; Action = { Repair-IconCache } }
        @{ Key = "4"; Label = "Search Index"; Desc = "Reset Windows Search (Admin)"; Action = { Repair-SearchIndex } }
        @{ Key = "5"; Label = "Store Cache"; Desc = "Reset Windows Store cache"; Action = { Repair-StoreCache } }
        @{ Key = "A"; Label = "All Repairs"; Desc = "Run all of the above"; Action = { 
            Repair-DnsCache
            Repair-FontCache
            Repair-IconCache
            Repair-SearchIndex
            Repair-StoreCache
        } }
        @{ Key = "Q"; Label = "Quit"; Desc = "Exit"; Action = $null }
    )
    
    Write-Host ""
    Write-Host "$esc[1;35m$($script:Icons.Mole) Mole Repair$esc[0m"
    Write-Host ""
    
    if ($script:IsDryRun) {
        Write-Host "$esc[33m$($script:Icons.DryRun) DRY RUN MODE$esc[0m - No changes will be made"
        Write-Host ""
    }
    
    Write-Host "$esc[90mSelect a repair to run:$esc[0m"
    Write-Host ""
    
    foreach ($item in $menuItems) {
        Write-Host "  $esc[36m[$($item.Key)]$esc[0m $($item.Label) - $esc[90m$($item.Desc)$esc[0m"
    }
    
    Write-Host ""
    $choice = Read-Host "Choice"
    
    $selected = $menuItems | Where-Object { $_.Key -eq $choice.ToUpper() }
    
    if ($selected -and $selected.Action) {
        & $selected.Action
        
        # Show summary
        Write-Host ""
        if ($script:RepairsApplied -gt 0) {
            Write-Host "$esc[32m$($script:Icons.Success)$esc[0m $($script:RepairsApplied) repair(s) applied"
        }
        else {
            Write-Host "$esc[90mNo repairs applied$esc[0m"
        }
    }
    elseif ($choice.ToUpper() -eq "Q") {
        return
    }
    else {
        Write-Host "$esc[31mInvalid choice$esc[0m"
    }
}

# ============================================================================
# Main Entry Point
# ============================================================================

function Main {
    $esc = [char]27
    
    # Enable debug if requested
    if ($DebugMode) {
        $env:MOLE_DEBUG = "1"
        $DebugPreference = "Continue"
    }
    
    # Show help
    if ($ShowHelp) {
        Show-RepairHelp
        return
    }
    
    # Check if any specific repair was requested
    $specificRepair = $DNS -or $Font -or $Icon -or $Search -or $Store -or $All
    
    if (-not $specificRepair) {
        # No specific repair requested - show interactive menu
        Show-RepairMenu
        return
    }
    
    # Run specific repairs
    Write-Host ""
    Write-Host "$esc[1;35m$($script:Icons.Mole) Mole Repair$esc[0m"
    
    if ($script:IsDryRun) {
        Write-Host ""
        Write-Host "$esc[33m$($script:Icons.DryRun) DRY RUN MODE$esc[0m - No changes will be made"
    }
    
    if ($All -or $DNS) {
        Repair-DnsCache
    }
    
    if ($All -or $Font) {
        Repair-FontCache
    }
    
    if ($All -or $Icon) {
        Repair-IconCache
    }
    
    if ($All -or $Search) {
        Repair-SearchIndex
    }
    
    if ($All -or $Store) {
        Repair-StoreCache
    }
    
    # Show summary
    Write-Host ""
    if ($script:RepairsApplied -gt 0) {
        if ($script:IsDryRun) {
            Write-Host "$esc[33m$($script:Icons.DryRun)$esc[0m $($script:RepairsApplied) repair(s) would be applied"
        }
        else {
            Write-Host "$esc[32m$($script:Icons.Success)$esc[0m $($script:RepairsApplied) repair(s) applied successfully"
        }
    }
    else {
        Write-Host "$esc[90mNo repairs applied$esc[0m"
    }
    Write-Host ""
}

# Run main
Main
