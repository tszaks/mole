---
name: release
description: Use this skill when preparing, validating, and publishing a Mole release.
---

# Release Skill

Use this skill when preparing or executing a Mole release.

## Release Checklist

### Pre-Release
1. [ ] All tests pass: `./scripts/test.sh`
2. [ ] Format check: `./scripts/check.sh --format`
3. [ ] No uncommitted changes: `git status`

### Version Bump

Update version in:
- `bin/mole` (VERSION variable)
- `install.sh` (if version referenced)

### Build Verification

```bash
# Build
make build

# Test dry run
MOLE_DRY_RUN=1 ./mole clean
```

## Release Process

### 1. Create Git Tag

```bash
# Create annotated tag
git tag -a v0.x.x -m "Release v0.x.x"

# Push tag
git push origin v0.x.x
```

### 2. GitHub Release

Create release via GitHub UI or:
```bash
gh release create v0.x.x --generate-notes
```

## Safety Rules

1. **NEVER** auto-commit release changes
2. **ALWAYS** test build before tagging
3. **ALWAYS** verify tests pass
4. **NEVER** include local paths in release notes
