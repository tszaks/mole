$ErrorActionPreference = 'Stop'

$packageName = 'mole'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Find installation directory
$installDir = Get-ChildItem $toolsDir -Directory | Where-Object { $_.Name -like "mole-*" } | Select-Object -First 1

if ($installDir) {
    $moleDir = $installDir.FullName
    
    # Remove from PATH
    Uninstall-ChocolateyPath -PathToUninstall $moleDir -PathType 'User'
    
    Write-Host ""
    Write-Host "Mole has been uninstalled successfully" -ForegroundColor Green
    Write-Host ""
} else {
    Write-Warning "Installation directory not found, but PATH will be cleaned up"
}
