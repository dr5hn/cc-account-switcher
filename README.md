# Multi-Account Switcher for Claude Code

A simple tool to manage and switch between multiple Claude Code accounts on macOS, Linux, and WSL.

## Features

### Core Features
- **Multi-account management**: Add, remove, and list Claude Code accounts
- **Quick switching**: Switch between accounts with simple commands or interactive mode
- **Cross-platform**: Works on macOS, Linux, and WSL
- **Secure storage**: Uses system keychain (macOS) or protected files (Linux/WSL)
- **Settings preservation**: Only switches authentication - your themes, settings, and preferences remain unchanged

### Enhanced Features (v2.0+)
- **Account aliases**: Set friendly names like "work" or "personal" for quick access
- **Switch history**: Track and view your account switching history
- **Undo capability**: Quickly revert to your previous account
- **Health verification**: Validate backup integrity for all accounts
- **Export/Import**: Backup and restore your account configurations
- **Interactive mode**: Menu-driven interface for easier management
- **Rich metadata**: View last used time, usage counts, and account health
- **Color-coded output**: Beautiful terminal colors for better readability
- **Progress indicators**: Real-time feedback during operations
- **Performance optimized**: Caching and parallel operations for faster switching

## Installation

Download the script directly:

```bash
curl -O https://raw.githubusercontent.com/ming86/cc-account-switcher/main/ccswitch.sh
chmod +x ccswitch.sh
```

## Usage

### Interactive Mode (Recommended)

The easiest way to use the switcher:

```bash
./ccswitch.sh --interactive
```

This launches a menu-driven interface where you can:
- See all accounts at a glance with visual indicators
- Switch accounts by number
- Add, verify, and manage accounts
- View switch history
- Undo last switch

### Basic Commands

```bash
# Add current account to managed accounts
./ccswitch.sh --add-account

# List all managed accounts with metadata
./ccswitch.sh --list

# Show detailed status
./ccswitch.sh --status

# Switch to next account in sequence
./ccswitch.sh --switch

# Switch to specific account by number, email, or alias
./ccswitch.sh --switch-to 2
./ccswitch.sh --switch-to user2@example.com
./ccswitch.sh --switch-to work

# Remove an account
./ccswitch.sh --remove-account user2@example.com

# Show help
./ccswitch.sh --help
```

### Advanced Features

```bash
# Set a friendly alias for an account
./ccswitch.sh --set-alias 1 work
./ccswitch.sh --set-alias user@example.com personal

# View switch history
./ccswitch.sh --history

# Undo last account switch
./ccswitch.sh --undo

# Verify all account backups
./ccswitch.sh --verify

# Verify specific account
./ccswitch.sh --verify work

# Export all accounts to backup archive
./ccswitch.sh --export ~/my-accounts-backup.tar.gz

# Import accounts from backup
./ccswitch.sh --import ~/my-accounts-backup.tar.gz

# Disable colors (for scripting or preference)
./ccswitch.sh --no-color --list
NO_COLOR=1 ./ccswitch.sh --list
```

### First Time Setup

1. **Log into Claude Code** with your first account (make sure you're actively logged in)
2. Run `./ccswitch.sh --add-account` to add it to managed accounts
3. **Log out** and log into Claude Code with your second account
4. Run `./ccswitch.sh --add-account` again
5. Now you can switch between accounts with `./ccswitch.sh --switch`
6. **Important**: After each switch, restart Claude Code to use the new authentication

> **What gets switched:** Only your authentication credentials change. Your themes, settings, preferences, and chat history remain exactly the same.

## Requirements

- Bash 4.4+
- `jq` (JSON processor)

### Installing Dependencies

**macOS:**

```bash
brew install jq
```

**Ubuntu/Debian:**

```bash
sudo apt install jq
```

## How It Works

The switcher stores account authentication data separately:

- **macOS**: Credentials in Keychain, OAuth info in `~/.claude-switch-backup/`
- **Linux/WSL**: Both credentials and OAuth info in `~/.claude-switch-backup/` with restricted permissions

When switching accounts, it:

1. Backs up the current account's authentication data
2. Restores the target account's authentication data
3. Updates Claude Code's authentication files

## What's New in v2.0

### Performance Improvements
- **Caching system**: Reduces redundant file reads and jq operations
- **Parallel operations**: Faster account switching with optimized I/O
- **Progress indicators**: Real-time feedback during operations

### User Experience Enhancements
- **Interactive mode**: Beautiful menu-driven interface
- **Color-coded output**: Green for active, yellow for warnings, red for errors
- **Rich metadata**: See when you last used each account and how often
- **Account health**: Visual indicators showing backup validity

### New Functionality
- **Account aliases**: Use memorable names instead of numbers
- **Switch history**: Track your last 10 account switches
- **Undo command**: Quickly revert to previous account
- **Verify command**: Check backup integrity
- **Export/Import**: Disaster recovery and migration support
- **Status command**: Detailed view of your current account

### Data Migration
Existing users will be automatically migrated to v2.0 schema on first use. A backup of your old data format is created automatically.

## Troubleshooting

### If a switch fails

- Check that you have accounts added: `./ccswitch.sh --list`
- Run verification: `./ccswitch.sh --verify`
- Try switching back to your original account: `./ccswitch.sh --undo`

### If you can't add an account

- Make sure you're logged into Claude Code first
- Check that you have `jq` installed
- Verify you have write permissions to your home directory
- Try running verification: `./ccswitch.sh --verify`

### If Claude Code doesn't recognize the new account

- Make sure you restarted Claude Code after switching
- Check the current account: `./ccswitch.sh --status`
- View account health: `./ccswitch.sh --list`
- Run verification on the account: `./ccswitch.sh --verify <account>`

### Backup and Recovery

If something goes wrong:

```bash
# Export your accounts first
./ccswitch.sh --export ~/backup-$(date +%Y%m%d).tar.gz

# Check backup integrity
./ccswitch.sh --verify

# If needed, import from backup
./ccswitch.sh --import ~/backup-YYYYMMDD.tar.gz
```

## Cleanup/Uninstall

To stop using this tool and remove all data:

1. Note your current active account: `./ccswitch.sh --list`
2. Remove the backup directory: `rm -rf ~/.claude-switch-backup`
3. Delete the script: `rm ccswitch.sh`

Your current Claude Code login will remain active.

## Security Notes

- Credentials stored in macOS Keychain or files with 600 permissions
- Authentication files are stored with restricted permissions (600)
- The tool requires Claude Code to be closed during account switches

## License

MIT License - see LICENSE file for details
