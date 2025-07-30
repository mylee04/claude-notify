# Claude-Notify Project Guide

## Project Overview
Claude-Notify is a cross-platform desktop notification system for Claude Code that provides real-time alerts when tasks complete, errors occur, or input is needed. It integrates seamlessly with Claude Code's hook system to deliver native notifications across macOS, Linux, and Windows.

## Key Project Rules

### 1. Use Specialized Subagents
When answering questions or working on specific aspects of this project, ALWAYS use the appropriate specialized subagent:

- **react-typescript-specialist**: For React components, TypeScript interfaces, or UI component questions
- **tailwind-ui-designer**: For styling, CSS, responsive design, or UI/UX questions
- **supabase-backend-specialist**: For database, backend, or data persistence questions
- **vercel-deployment-engineer**: For deployment, CI/CD, or hosting questions
- **vitest-testing-expert**: For testing, test coverage, or test implementation questions
- **git-operations-specialist**: For git operations, commits, branches, or version control
- **api-integration-architect**: For API design, integration, or architecture questions
- **feature-planner**: For planning new features or major architectural changes
- **form-validation-specialist**: For form handling, validation, or user input questions

### 2. Documentation Requirements
- All changes MUST be documented in `DEVELOPMENT_JOURNEY.md`
- Include date, description, and impact of changes
- Document both successful implementations and failed attempts
- Track bug fixes, feature additions, and refactoring efforts

### 3. Code Standards
- Follow existing code conventions in the project
- Maintain cross-platform compatibility (macOS, Linux, Windows)
- Use bash scripts for maximum portability
- Test on multiple platforms when possible

### 4. Testing Philosophy
- Always verify changes work as expected
- Run manual tests for notification functionality
- Consider platform-specific edge cases

### 5. User Experience Principles
- Keep CLI commands simple and intuitive
- Provide clear feedback for all operations
- Support both verbose and short command aliases
- Maintain backward compatibility

## Project Architecture

### Core Components
1. **CLI Tool** (`bin/claude-notify`): Main command-line interface
2. **Notification Script** (`~/.claude/notifications/notify.sh`): Platform-specific notification handler
3. **Hook Integration**: Integrates with Claude Code's hook system
4. **Configuration**: Global and project-specific settings via `hooks.json`

### Platform Support
- **macOS**: Uses terminal-notifier or native osascript
- **Linux**: Uses notify-send, zenity, or wall
- **Windows**: Uses PowerShell with BurntToast or native notifications

## Development Workflow
1. Always consult appropriate subagents for specialized questions
2. Document all changes in development journey
3. Test changes across platforms when possible
4. Follow existing code patterns and conventions
5. Prioritize user experience and simplicity