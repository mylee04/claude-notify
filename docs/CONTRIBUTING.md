# Contributing to Code-Notify

First off, thank you for considering contributing to Code-Notify! 🎉

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check existing issues to avoid duplicates. When you create a bug report, include as many details as possible:

- **Use a clear and descriptive title**
- **Describe the exact steps to reproduce the problem**
- **Provide specific examples**
- **Include your environment details** (macOS version, shell type, etc.)

### Suggesting Enhancements

Enhancement suggestions are welcome! Please:

- **Use a clear and descriptive title**
- **Provide a detailed description of the proposed enhancement**
- **Explain why this enhancement would be useful**
- **List any alternative solutions you've considered**

### Pull Requests

1. Fork the repo and create your branch from `main`
2. Make your changes
3. Add tests if applicable
4. Ensure the test suite passes (`make test`)
5. Update documentation as needed
6. Submit the pull request!

## Development Setup

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/code-notify.git
cd code-notify

# Make scripts executable
chmod +x bin/code-notify

# Add to PATH for testing
export PATH="$PWD/bin:$PATH"

# Run tests
./test/run_tests.sh
```

## Style Guidelines

### Shell Script Style

- Use bash shebang: `#!/bin/bash`
- Set error handling: `set -e`
- Use meaningful variable names
- Add comments for complex logic
- Keep functions focused and small
- Use proper quoting for variables

### Commit Messages

- Use present tense ("Add feature" not "Added feature")
- Use imperative mood ("Move cursor to..." not "Moves cursor to...")
- Limit first line to 72 characters
- Reference issues and pull requests when applicable

## Testing

- Add tests for new functionality
- Ensure all tests pass before submitting PR
- Test on clean macOS environment if possible

## Questions?

Feel free to open an issue with your question or reach out to the maintainers.

Thank you for contributing! 🚀
