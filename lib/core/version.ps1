# Mole - Version helpers
# Provides a single source of truth for the Windows version string.

#Requires -Version 5.1
Set-StrictMode -Version Latest

if ((Get-Variable -Name 'MOLE_VERSION_HELPERS_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_VERSION_HELPERS_LOADED) {
    return
}
$script:MOLE_VERSION_HELPERS_LOADED = $true

# Last-resort fallback for artifacts that ship without the VERSION file.
# Keep this equal to VERSION: released ZIP/EXE installs read it, not the file
# (issue #635 shipped v1.29.1 reporting v1.29.0 from exactly this constant).
# Locked by the "compiled-in fallback" test in tests/Core.Tests.ps1.
$script:MoleDefaultVersion = "1.29.1"

function Get-MoleVersionFilePath {
    param([string]$RootDir)

    if ([string]::IsNullOrWhiteSpace($RootDir)) {
        return $null
    }

    return Join-Path $RootDir "VERSION"
}

function Get-MoleVersionString {
    param(
        [string]$RootDir,
        [string]$DefaultVersion = $script:MoleDefaultVersion
    )

    $versionFile = Get-MoleVersionFilePath -RootDir $RootDir
    if (-not $versionFile -or -not (Test-Path $versionFile)) {
        return $DefaultVersion
    }

    $version = (Get-Content $versionFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($version)) {
        return $DefaultVersion
    }

    return $version
}
