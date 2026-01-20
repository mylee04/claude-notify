# Git Workflow Rules

## Branch Strategy
- `main` - Production-ready code
- Feature branches for development

## Commit Message Format

```
type: brief description

- Detail 1
- Detail 2
```

### Types
| Type | Description |
|------|-------------|
| feat | New feature |
| fix | Bug fix |
| docs | Documentation only |
| refactor | Code refactoring |
| test | Adding/updating tests |
| chore | Maintenance tasks |

### Examples
```
feat: add WSL notification support

- Detect WSL via /proc/version
- Use wsl-notify-send.exe for notifications
- Add installation option in setup wizard
```

```
fix: handle non-git directories on Windows

- Wrap git commands in try-catch
- Check $LASTEXITCODE after git calls
```

## Pre-Commit Checklist
- [ ] `make test` passes
- [ ] No shellcheck warnings
- [ ] No hardcoded credentials
- [ ] Meaningful commit message
- [ ] No .env files staged

## Rules
- Never force push to main
- Never commit credentials
- No Co-Authored-By lines
- Run tests before pushing
- Keep commits focused and atomic

## PR Process
1. Create feature branch
2. Make changes
3. Run tests locally
4. Push and create PR
5. Address review feedback
6. Merge when approved

## Never Commit
- `.env`
- `*.pem`, `*.key`
- `node_modules/`
- `credentials.json`
- IDE settings (unless shared)
