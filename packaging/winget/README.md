# WinGet Package for Mole

## Quick Submission Guide

### 1. Prerequisites
- GitHub account
- GitHub release with ZIP file
- `winget-create` tool (optional but recommended)

### 2. Install WinGet Create Tool (Recommended)

```powershell
# Install via WinGet
winget install Microsoft.WingetCreate

# Or download from GitHub
# https://github.com/microsoft/winget-create/releases
```

### 3a. Automated Submission (Recommended)

```powershell
# For new package
wingetcreate new `
  --urls https://github.com/bhadraagada/mole/releases/download/v1.0.0/mole-1.0.0-x64.zip `
  --version 1.0.0

# For updates (after first approval)
wingetcreate update bhadraagada.mole `
  --urls https://github.com/bhadraagada/mole/releases/download/v1.0.0/mole-1.0.0-x64.zip `
  --version 1.0.0 `
  --submit
```

### 3b. Manual Submission

1. **Fork microsoft/winget-pkgs**
   ```powershell
   # On GitHub: Fork https://github.com/microsoft/winget-pkgs
   git clone https://github.com/YOUR_USERNAME/winget-pkgs
   cd winget-pkgs
   ```

2. **Create manifest directory**
   ```powershell
   mkdir -p manifests\b\bhadraagada\mole\1.0.0
   ```

3. **Copy manifests**
   ```powershell
   Copy-Item packaging\winget\*.yaml manifests\b\bhadraagada\mole\1.0.0\
   ```

4. **Update checksums**
   - Edit `bhadraagada.mole.installer.yaml`
   - Update `InstallerSha256` with your build's SHA256
   - Update `InstallerUrl` with correct version

5. **Commit and push**
   ```powershell
   git add manifests\b\bhadraagada\mole\
   git commit -m "New package: bhadraagada.mole version 1.0.0"
   git push
   ```

6. **Create Pull Request**
   - Go to: https://github.com/microsoft/winget-pkgs/compare
   - Select your fork and branch
   - Create PR with title: `New package: bhadraagada.mole version 1.0.0`

## Manifest Files

WinGet requires 3 manifest files:

### 1. Version Manifest (bhadraagada.mole.yaml)
- Package identifier
- Version number
- Default locale

### 2. Locale Manifest (bhadraagada.mole.locale.en-US.yaml)
- Package metadata (name, description, publisher)
- URLs (homepage, license, documentation)
- Tags and categories
- Release notes

### 3. Installer Manifest (bhadraagada.mole.installer.yaml)
- Download URLs
- SHA256 checksums
- Installer type
- Architecture
- Minimum OS version

## Validation

Before submitting, validate manifests:

```powershell
# Install WinGet validation tool
winget install Microsoft.WingetCreate

# Validate manifests
winget validate --manifest manifests\b\bhadraagada\mole\1.0.0
```

## Review Process

1. **Auto-checks**: Automated validation runs immediately
   - Manifest format
   - URL accessibility
   - Checksum verification
   - Malware scan

2. **Human Review**: Maintainers review (~1-2 weeks)
   - First-time packages reviewed more carefully
   - Subsequent updates often auto-approved

3. **Approval**: Package becomes available via WinGet

## Updating for New Releases

When releasing v1.0.1:

```powershell
# Option A: Using wingetcreate (easy)
wingetcreate update bhadraagada.mole `
  --urls https://github.com/bhadraagada/mole/releases/download/v1.0.1/mole-1.0.1-x64.zip `
  --version 1.0.1 `
  --submit

# Option B: Manual
# 1. Create new directory: manifests\b\bhadraagada\mole\1.0.1
# 2. Copy and update manifests
# 3. Submit PR with title: "Update: bhadraagada.mole version 1.0.1"
```

## Testing Before Submission

Test installation locally:

```powershell
# Add local source
winget source add --name local file://C:\path\to\manifests

# Install from local
winget install bhadraagada.mole --source local

# Test functionality
mole --version

# Remove local source
winget source remove local
```

## Common Issues

### "URL not accessible"
- Ensure GitHub release is public
- Wait a few minutes after creating release
- Test URL in browser

### "Checksum mismatch"
- Regenerate: `(Get-FileHash mole-1.0.0-x64.zip).Hash`
- Ensure lowercase in manifest
- Verify no extra spaces

### "Manifest validation failed"
- Run `winget validate --manifest path\to\manifest`
- Check YAML indentation (use spaces, not tabs)
- Ensure all required fields present

### "Installer type not supported"
- Use `zip` with `NestedInstallerType: portable` for ZIP archives
- Consider creating MSI for better integration

## Best Practices

1. **Use semantic versioning**: 1.0.0, 1.0.1, 1.1.0
2. **Tag releases properly**: v1.0.0 (with 'v' prefix)
3. **Keep manifests updated**: Update within days of releases
4. **Add detailed descriptions**: Help users understand the tool
5. **Include release notes**: Document changes clearly

## Migration to MSI (Optional Future Enhancement)

WinGet works better with MSI installers:

```yaml
InstallerType: msi
Installers:
  - Architecture: x64
    InstallerUrl: https://github.com/bhadraagada/mole/releases/download/v1.0.0/mole-1.0.0-x64.msi
    InstallerSha256: <MSI_SHA256>
    ProductCode: '{GUID-HERE}'
```

Benefits:
- Better Windows integration
- Automatic PATH configuration
- Add/Remove Programs integration
- Silent installation support

## Resources

- **WinGet Repository**: https://github.com/microsoft/winget-pkgs
- **Submission Guide**: https://github.com/microsoft/winget-pkgs/wiki/Submitting-Packages
- **Manifest Schema**: https://github.com/microsoft/winget-cli/blob/master/schemas/JSON/manifests/v1.4.0/manifest.version.1.4.0.json
- **WinGet Create**: https://github.com/microsoft/winget-create
- **Validation**: https://github.com/microsoft/winget-cli

## Support

- **WinGet Issues**: https://github.com/microsoft/winget-cli/issues
- **Package Issues**: https://github.com/microsoft/winget-pkgs/issues
- **Discussions**: https://github.com/microsoft/winget-cli/discussions
