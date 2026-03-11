---
name: github-ops
description: Use this skill for GitHub issue, PR, and release operations in the Mole repository via gh CLI.
---

# GitHub Operations Skill

Use this skill when working with GitHub issues, PRs, and releases for Mole.

## Golden Rule

**ALWAYS use `gh` CLI** for GitHub operations. Never use raw git commands or web scraping.

## Issue Handling

```bash
# View issue
gh issue view 123

# List issues
gh issue list --state open

# NEVER comment without explicit user request
# Only prepare responses for user review
```

## Pull Request Workflow

```bash
# View current PR
gh pr view

# View PR diff
gh pr diff

# Checkout PR branch
gh pr checkout 123
```

## Safety Rules

1. **NEVER** comment on issues/PRs without explicit user request
2. **NEVER** create PRs automatically
3. **NEVER** merge without explicit confirmation
4. **ALWAYS** prepare responses for user review first
5. **ALWAYS** use `gh` instead of manual curl/API calls

## Issue Language

Draft replies in the same language as the issue author.
