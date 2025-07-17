# Automation Scripts

This repository contains shell automation scripts written for **zsh**.

## Shell Environment
- **Shell**: zsh (required)
- **Compatibility**: macOS with Homebrew
- **Path**: Scripts expect `/opt/homebrew/bin` and `/usr/local/bin` in PATH

## Project Structure
```
automation-scripts/
├── ai/                 # AI-related automation scripts
├── media/              # Media processing scripts
├── organization/       # File organization scripts
├── utilities/          # Shared utility functions
│   └── logging.sh     # Common logging functions
└── README.md
```

## Development
All scripts use zsh syntax and should be executed with zsh. The project includes:
- EditorConfig for consistent formatting
- VS Code configuration for zsh development
- ShellCheck and shfmt integration

## Usage
Scripts follow a consistent pattern:
- Comprehensive argument validation
- Structured logging with emoji indicators
- Proper error handling and exit codes
- Environment variable configuration
