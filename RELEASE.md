# Mole Windows - Release Guide

This guide explains how to build and publish Mole for Windows package managers.

## Prerequisites

### Required Tools

1. **PowerShell 5.1+**
   - Already included in Windows 10/11
   - Verify: `$PSVersionTable.PSVersion`

2. **Go 1.21+**
   - Download: https://golang.org/dl/
   - Verify: `go version`

3. **Git**
   - Download: https://git-scm.com/
   - Verify: `git --version`

### Optional Tools (for specific build types)

4. **WiX Toolset** (for MSI installer)
   ```powershell
   choco install wixtoolset
   # Or download from: https://wixtoolset.org/
   ```

5. **PS2EXE** (for standalone EXE)
   ```powershell
   Install-Module ps2exe -Scope CurrentUser
   ```

## Build Commands

### Quick Start - Build Everything

```powershell
# Build portable ZIP and checksums
.\scripts\build-release.ps1

# Optionally build MSI (requires WiX)
.\scripts\build-msi.ps1

# Optionally build standalone EXE (requires PS2EXE)
.\scripts\build-exe.ps1
```

### Build Options

```powershell
# Specify version explicitly
.\scripts\build-release.ps1 -Version "1.2.3"

# Skip running tests
.\scripts\build-release.ps1 -SkipTests

# Show help
.\scripts\build-release.ps1 -ShowHelp
```

## Release Artifacts

After building, the `release/` directory will contain:

```
release/
├── mole-1.0.0-x64.zip          # Portable archive (required)
├── mole-1.0.0-x64.msi          # MSI installer (optional)
├── mole-1.0.0-x64.exe          # Standalone EXE (optional)
└── SHA256SUMS.txt               # Checksums for verification
```

## Publishing to Package Managers

### 1. WinGet (Highest Priority)

**Requirements:**
- GitHub release with ZIP or MSI
- SHA256 hash
- Fork of microsoft/winget-pkgs

**Steps:**

1. Create GitHub release:
   ```powershell
   # Tag the release
   git tag v1.0.0
   git push origin v1.0.0
   
   # Or use GitHub CLI
   gh release create v1.0.0 `
     release/mole-1.0.0-x64.zip `
     release/SHA256SUMS.txt `
     --title "Mole v1.0.0" `
     --notes "Release notes here"
   ```

2. Install winget-create:
   ```powershell
   winget install Microsoft.WingetCreate
   ```

3. Generate manifests:
   ```powershell
   # For new package
   wingetcreate new `
     --token YOUR_GITHUB_TOKEN `
     --urls https://github.com/bhadraagada/mole/releases/download/v1.0.0/mole-1.0.0-x64.zip
   
   # For updates
   wingetcreate update bhadraagada.mole `
     --urls https://github.com/bhadraagada/mole/releases/download/v1.0.0/mole-1.0.0-x64.zip `
     --version 1.0.0 `
     --submit
   ```

4. Manually submit (alternative):
   ```powershell
   # Fork microsoft/winget-pkgs
   git clone https://github.com/YOUR_USERNAME/winget-pkgs
   cd winget-pkgs
   
   # Create manifest directory
   mkdir -p manifests/b/bhadraagada/mole/1.0.0
   
   # Copy template manifests (see templates/ below)
   # Then commit and create PR
   git add manifests/b/bhadraagada/mole/
   git commit -m "New package: bhadraagada.mole version 1.0.0"
   git push
   
   # Create PR to microsoft/winget-pkgs
   ```

**WinGet Manifest Template:**

Create these files in `manifests/b/bhadraagada/mole/1.0.0/`:

`bhadraagada.mole.yaml`:
```yaml
PackageIdentifier: bhadraagada.mole
PackageVersion: 1.0.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.4.0
```

`bhadraagada.mole.locale.en-US.yaml`:
```yaml
PackageIdentifier: bhadraagada.mole
PackageVersion: 1.0.0
PackageLocale: en-US
Publisher: Mole Project
PublisherUrl: https://github.com/bhadraagada/mole
PublisherSupportUrl: https://github.com/bhadraagada/mole/issues
PackageName: Mole
PackageUrl: https://github.com/bhadraagada/mole
License: MIT
LicenseUrl: https://github.com/bhadraagada/mole/blob/windows/LICENSE
ShortDescription: Deep clean and optimize your Windows system
Description: |
  All-in-one toolkit combining CCleaner, IObit Uninstaller, WinDirStat, 
  and Task Manager functionality for comprehensive Windows system 
  optimization and cleanup.
Moniker: mole
Tags:
  - cleanup
  - optimizer
  - maintenance
  - disk-space
  - uninstaller
  - system-tools
ManifestType: defaultLocale
ManifestVersion: 1.4.0
```

`bhadraagada.mole.installer.yaml`:
```yaml
PackageIdentifier: bhadraagada.mole
PackageVersion: 1.0.0
InstallerLocale: en-US
MinimumOSVersion: 10.0.0.0
InstallerType: zip
NestedInstallerType: portable
NestedInstallerFiles:
  - RelativeFilePath: mole.ps1
    PortableCommandAlias: mole
Installers:
  - Architecture: x64
    InstallerUrl: https://github.com/bhadraagada/mole/releases/download/v1.0.0/mole-1.0.0-x64.zip
    InstallerSha256: YOUR_SHA256_HERE
ManifestType: installer
ManifestVersion: 1.4.0
```

### 2. Chocolatey

**Requirements:**
- Chocolatey account
- .nuspec manifest
- PowerShell install/uninstall scripts

**Steps:**

1. Register at https://community.chocolatey.org/

2. Create package structure:
   ```powershell
   mkdir chocolatey
   cd chocolatey
   ```

3. Create `mole.nuspec`:
   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
     <metadata>
       <id>mole</id>
       <version>1.0.0</version>
       <title>Mole</title>
       <authors>Mole Project</authors>
       <owners>bhadraagada</owners>
       <licenseUrl>https://github.com/bhadraagada/mole/blob/windows/LICENSE</licenseUrl>
       <projectUrl>https://github.com/bhadraagada/mole</projectUrl>
       <requireLicenseAcceptance>false</requireLicenseAcceptance>
       <description>Deep clean and optimize your Windows system. All-in-one toolkit for system maintenance.</description>
       <summary>Windows system cleanup and optimization tool</summary>
       <releaseNotes>https://github.com/bhadraagada/mole/releases</releaseNotes>
       <copyright>MIT License</copyright>
       <tags>cleanup optimization disk-space uninstaller maintenance</tags>
       <packageSourceUrl>https://github.com/bhadraagada/mole</packageSourceUrl>
       <docsUrl>https://github.com/bhadraagada/mole/blob/windows/README.md</docsUrl>
       <bugTrackerUrl>https://github.com/bhadraagada/mole/issues</bugTrackerUrl>
     </metadata>
     <files>
       <file src="tools\**" target="tools" />
     </files>
   </package>
   ```

4. Create `tools/chocolateyinstall.ps1`:
   ```powershell
   $ErrorActionPreference = 'Stop'
   
   $packageName = 'mole'
   $url64 = 'https://github.com/bhadraagada/mole/releases/download/v1.0.0/mole-1.0.0-x64.zip'
   $checksum64 = 'YOUR_SHA256_HERE'
   $checksumType = 'sha256'
   $toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
   
   Install-ChocolateyZipPackage `
     -PackageName $packageName `
     -Url64bit $url64 `
     -UnzipLocation $toolsDir `
     -Checksum64 $checksum64 `
     -ChecksumType64 $checksumType
   
   # Add to PATH
   $installDir = Join-Path $toolsDir "mole-1.0.0-x64"
   Install-ChocolateyPath -PathToInstall $installDir -PathType 'User'
   
   Write-Host "Mole has been installed successfully!"
   Write-Host "Run 'mole' to get started"
   ```

5. Create `tools/chocolateyuninstall.ps1`:
   ```powershell
   $ErrorActionPreference = 'Stop'
   
   $toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
   $installDir = Join-Path $toolsDir "mole-1.0.0-x64"
   
   # Remove from PATH
   Uninstall-ChocolateyPath -PathToUninstall $installDir -PathType 'User'
   
   Write-Host "Mole has been uninstalled"
   ```

6. Build and push:
   ```powershell
   # Test locally first
   choco pack
   choco install mole -source . -y
   
   # Push to Chocolatey
   choco apikey --key YOUR_API_KEY --source https://push.chocolatey.org/
   choco push mole.1.0.0.nupkg --source https://push.chocolatey.org/
   ```

### 3. Scoop (Easiest!)

**Requirements:**
- Fork of ScoopInstaller/Main
- Simple JSON manifest

**Steps:**

1. Fork https://github.com/ScoopInstaller/Main

2. Create `bucket/mole.json`:
   ```json
   {
     "version": "1.0.0",
     "description": "Deep clean and optimize your Windows system",
     "homepage": "https://github.com/bhadraagada/mole",
     "license": "MIT",
     "url": "https://github.com/bhadraagada/mole/releases/download/v1.0.0/mole-1.0.0-x64.zip",
     "hash": "sha256:YOUR_SHA256_HERE",
     "extract_dir": "mole-1.0.0-x64",
     "bin": "mole.ps1",
     "shortcuts": [
       [
         "mole.ps1",
         "Mole"
       ]
     ],
     "checkver": {
       "github": "https://github.com/bhadraagada/mole"
     },
     "autoupdate": {
       "url": "https://github.com/bhadraagada/mole/releases/download/v$version/mole-$version-x64.zip"
     }
   }
   ```

3. Submit PR:
   ```powershell
   git clone https://github.com/YOUR_USERNAME/Main scoop-main
   cd scoop-main
   
   # Add manifest
   copy path\to\mole.json bucket\
   
   # Commit and push
   git add bucket/mole.json
   git commit -m "mole: Add version 1.0.0"
   git push
   
   # Create PR to ScoopInstaller/Main
   ```

## Automated Releases (GitHub Actions)

The repository includes a GitHub Actions workflow for automated releases.

**Trigger a release:**

```powershell
# Push a version tag
git tag v1.0.0
git push origin v1.0.0

# The workflow will automatically:
# 1. Run tests
# 2. Build release artifacts
# 3. Create GitHub release
# 4. Upload ZIP and checksums
```

**Manual trigger:**

Go to Actions → Build Windows Release → Run workflow

## Testing Releases Locally

```powershell
# Extract ZIP
Expand-Archive release/mole-1.0.0-x64.zip -DestinationPath test-install

# Test installation
cd test-install/mole-1.0.0-x64
.\install.ps1

# Verify mole works
mole --version
mole clean --dry-run

# Test MSI (if built)
msiexec /i release/mole-1.0.0-x64.msi /qn
```

## Verification

Users can verify downloads using SHA256SUMS.txt:

```powershell
# Download the release and checksums
$hash = (Get-FileHash mole-1.0.0-x64.zip).Hash
$expected = (Get-Content SHA256SUMS.txt | Select-String "mole-1.0.0-x64.zip").Line.Split()[0]

if ($hash -eq $expected) {
    Write-Host "✓ Checksum verified!" -ForegroundColor Green
} else {
    Write-Host "✗ Checksum mismatch!" -ForegroundColor Red
}
```

## Troubleshooting

### Build fails with "Go not found"
Install Go from https://golang.org/dl/ and restart PowerShell

### WiX build fails
Ensure WiX Toolset is installed and in PATH:
```powershell
choco install wixtoolset
```

### Tests fail
Run tests manually to debug:
```powershell
.\scripts\test.ps1
```

### GitHub Actions workflow fails
Check the logs in the Actions tab. Common issues:
- Missing secrets (GITHUB_TOKEN is automatic)
- Wrong branch/tag format
- Test failures

## Support

- **Issues**: https://github.com/bhadraagada/mole/issues
- **Discussions**: https://github.com/bhadraagada/mole/discussions
- **Wiki**: https://github.com/bhadraagada/mole/wiki
