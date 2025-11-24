#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Simple tool to manage and switch between multiple Claude Code accounts

set -euo pipefail

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"
readonly SCHEMA_VERSION="2.0"
readonly MAX_HISTORY_ENTRIES=10

# Feature flags
NO_COLOR=${NO_COLOR:-0}

# Color definitions
if [[ "$NO_COLOR" -eq 0 ]] && [[ -t 1 ]]; then
    readonly COLOR_RED='\033[0;31m'
    readonly COLOR_GREEN='\033[0;32m'
    readonly COLOR_YELLOW='\033[0;33m'
    readonly COLOR_BLUE='\033[0;34m'
    readonly COLOR_CYAN='\033[0;36m'
    readonly COLOR_BOLD='\033[1m'
    readonly COLOR_RESET='\033[0m'
else
    readonly COLOR_RED=''
    readonly COLOR_GREEN=''
    readonly COLOR_YELLOW=''
    readonly COLOR_BLUE=''
    readonly COLOR_CYAN=''
    readonly COLOR_BOLD=''
    readonly COLOR_RESET=''
fi

# Cache variables
declare -A CACHE
CACHE_VALID=0

# Logging and output functions
log_info() {
    echo -e "${COLOR_BLUE}ℹ${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} $*"
}

log_warning() {
    echo -e "${COLOR_YELLOW}⚠${COLOR_RESET} $*" >&2
}

log_error() {
    echo -e "${COLOR_RED}✗${COLOR_RESET} $*" >&2
}

log_step() {
    echo -e "${COLOR_CYAN}→${COLOR_RESET} $*"
}

# Progress indicator
show_progress() {
    local message="$1"
    echo -n -e "${COLOR_CYAN}⟳${COLOR_RESET} ${message}..."
}

complete_progress() {
    echo -e " ${COLOR_GREEN}✓${COLOR_RESET}"
}

# Container detection
# Purpose: Detects if the script is running inside a container environment
# Parameters: None
# Returns: 0 if running in container, 1 otherwise
# Usage: if is_running_in_container; then ...; fi
is_running_in_container() {
    # Check for Docker environment file
    if [[ -f /.dockerenv ]]; then
        return 0
    fi
    
    # Check cgroup for container indicators
    if [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    
    # Check mount info for container filesystems
    if [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null; then
        return 0
    fi
    
    # Check for common container environment variables
    if [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; then
        return 0
    fi
    
    return 1
}

# Platform detection
# Purpose: Identifies the operating system platform
# Parameters: None
# Returns: Prints "macos", "wsl", "linux", or "unknown"
# Usage: platform=$(detect_platform)
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) 
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# Get Claude configuration file path with fallback
# Purpose: Locates the Claude Code configuration file with validation
# Parameters: None
# Returns: Prints the absolute path to .claude.json
# Usage: config_path=$(get_claude_config_path)
get_claude_config_path() {
    local primary_config="$HOME/.claude/.claude.json"
    local fallback_config="$HOME/.claude.json"
    
    # Check primary location first
    if [[ -f "$primary_config" ]]; then
        # Verify it has valid oauthAccount structure
        if jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
            echo "$primary_config"
            return
        fi
    fi
    
    # Fallback to standard location
    echo "$fallback_config"
}

# Basic validation that JSON is valid
validate_json() {
    local file="$1"
    if ! jq . "$file" >/dev/null 2>&1; then
        echo "Error: Invalid JSON in $file"
        return 1
    fi
}

# Email validation function
validate_email() {
    local email="$1"
    # Use robust regex for email validation
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Account identifier resolution function
# Resolves account number, email, or alias to account number
resolve_account_identifier() {
    local identifier="$1"
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        echo "$identifier"  # It's a number
    else
        # Try to look up by email first
        local account_num
        account_num=$(jq -r --arg email "$identifier" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$account_num" && "$account_num" != "null" ]]; then
            echo "$account_num"
            return
        fi

        # Try to look up by alias
        account_num=$(jq -r --arg alias "$identifier" '.accounts | to_entries[] | select(.value.alias == $alias) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$account_num" && "$account_num" != "null" ]]; then
            echo "$account_num"
            return
        fi

        echo ""
    fi
}

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX")
    
    echo "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi
    
    mv "$temp_file" "$file"
    chmod 600 "$file"
}

# Check Bash version (4.4+ required)
check_bash_version() {
    local version
    version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if ! awk -v ver="$version" 'BEGIN { exit (ver >= 4.4 ? 0 : 1) }'; then
        echo "Error: Bash 4.4+ required (found $version)"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    for cmd in jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            echo "Install with: apt install $cmd (Linux) or brew install $cmd (macOS)"
            exit 1
        fi
    done
}

# Setup backup directories
setup_directories() {
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"/{configs,credentials}
}

# Claude Code process detection (Node.js app)
is_claude_running() {
    ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {exit 0} END {exit 1}'
}

# Wait for Claude Code to close (no timeout - user controlled)
wait_for_claude_close() {
    if ! is_claude_running; then
        return 0
    fi
    
    echo "Claude Code is running. Please close it first."
    echo "Waiting for Claude Code to close..."
    
    while is_claude_running; do
        sleep 1
    done
    
    echo "Claude Code closed. Continuing..."
}

# Get current account info from .claude.json
get_current_account() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo "none"
        return
    fi
    
    if ! validate_json "$(get_claude_config_path)"; then
        echo "none"
        return
    fi
    
    local email
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${email:-none}"
}

# Read credentials based on platform
read_credentials() {
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            if [[ -f "$HOME/.claude/.credentials.json" ]]; then
                cat "$HOME/.claude/.credentials.json"
            else
                echo ""
            fi
            ;;
    esac
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            mkdir -p "$HOME/.claude"
            printf '%s' "$credentials" > "$HOME/.claude/.credentials.json"
            chmod 600 "$HOME/.claude/.credentials.json"
            ;;
    esac
}

# Read account credentials from backup
read_account_credentials() {
    local account_num="$1"
    local email="$2"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-Account-${account_num}-${email}" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            if [[ -f "$cred_file" ]]; then
                cat "$cred_file"
            else
                echo ""
            fi
            ;;
    esac
}

# Write account credentials to backup
write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            printf '%s' "$credentials" > "$cred_file"
            chmod 600 "$cred_file"
            ;;
    esac
}

# Read account config from backup
read_account_config() {
    local account_num="$1"
    local email="$2"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    if [[ -f "$config_file" ]]; then
        cat "$config_file"
    else
        echo ""
    fi
}

# Write account config to backup
write_account_config() {
    local account_num="$1"
    local email="$2"
    local config="$3"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    echo "$config" > "$config_file"
    chmod 600 "$config_file"
}

# Cache management functions
# Purpose: Invalidates the in-memory cache of sequence data
# Parameters: None
# Returns: None (modifies global cache state)
# Usage: invalidate_cache
invalidate_cache() {
    CACHE_VALID=0
    CACHE=()
}

load_sequence_cache() {
    if [[ "$CACHE_VALID" -eq 1 ]]; then
        return 0
    fi

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi

    CACHE[sequence_json]=$(cat "$SEQUENCE_FILE")
    CACHE_VALID=1
}

get_cached_sequence() {
    load_sequence_cache
    echo "${CACHE[sequence_json]}"
}

# Initialize sequence.json if it doesn't exist
# Purpose: Creates the sequence.json file with default schema if not present
# Parameters: None
# Returns: None (creates file with side effects)
# Usage: init_sequence_file
init_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        local init_content='{
  "schemaVersion": "'"$SCHEMA_VERSION"'",
  "activeAccountNumber": null,
  "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "sequence": [],
  "accounts": {},
  "history": []
}'
        write_json "$SEQUENCE_FILE" "$init_content"
        invalidate_cache
    fi
}

# Migrate old schema to new schema
# Purpose: Automatically migrates sequence.json from v1.0 to v2.0 schema
# Parameters: None
# Returns: None (modifies sequence.json with backup)
# Usage: migrate_sequence_file
migrate_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 0
    fi

    local current_version
    current_version=$(jq -r '.schemaVersion // "1.0"' "$SEQUENCE_FILE")

    if [[ "$current_version" == "$SCHEMA_VERSION" ]]; then
        return 0
    fi

    show_progress "Migrating data to schema version $SCHEMA_VERSION"

    # Backup current file
    cp "$SEQUENCE_FILE" "$SEQUENCE_FILE.backup-$(date +%s)"

    # Migrate from 1.0 to 2.0
    if [[ "$current_version" == "1.0" ]]; then
        local migrated
        migrated=$(jq --arg version "$SCHEMA_VERSION" '
            .schemaVersion = $version |
            .history = [] |
            .accounts |= with_entries(
                .value |= . + {
                    alias: null,
                    lastUsed: null,
                    usageCount: 0,
                    healthStatus: "unknown"
                }
            )
        ' "$SEQUENCE_FILE")

        write_json "$SEQUENCE_FILE" "$migrated"
        invalidate_cache
    fi

    complete_progress
    log_success "Data migrated successfully (backup saved)"
}

# Get next account number
get_next_account_number() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "1"
        return
    fi
    
    local max_num
    max_num=$(jq -r '.accounts | keys | map(tonumber) | max // 0' "$SEQUENCE_FILE")
    echo $((max_num + 1))
}

# Check if account exists by email
account_exists() {
    local email="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi
    
    jq -e --arg email "$email" '.accounts[] | select(.email == $email)' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# Add account
# Purpose: Adds the currently logged-in Claude Code account to managed accounts
# Parameters: None
# Returns: Exit code 0 on success, 1 on failure
# Usage: cmd_add_account
# Preconditions: User must be logged into Claude Code
cmd_add_account() {
    setup_directories
    init_sequence_file
    migrate_sequence_file

    show_progress "Checking current account"
    local current_email
    current_email=$(get_current_account)
    complete_progress

    if [[ "$current_email" == "none" ]]; then
        log_error "No active Claude account found. Please log in first."
        exit 1
    fi

    if account_exists "$current_email"; then
        log_info "Account $current_email is already managed."
        exit 0
    fi

    local account_num
    account_num=$(get_next_account_number)

    show_progress "Reading credentials and configuration"
    # Backup current credentials and config
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")
    complete_progress

    if [[ -z "$current_creds" ]]; then
        log_error "No credentials found for current account"
        exit 1
    fi

    # Get account UUID
    local account_uuid
    account_uuid=$(jq -r '.oauthAccount.accountUuid' "$(get_claude_config_path)")

    show_progress "Storing account backups"
    # Store backups
    write_account_credentials "$account_num" "$current_email" "$current_creds"
    write_account_config "$account_num" "$current_email" "$current_config"
    complete_progress

    show_progress "Updating account registry"
    # Update sequence.json with new metadata fields
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg email "$current_email" --arg uuid "$account_uuid" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num] = {
            email: $email,
            uuid: $uuid,
            added: $now,
            alias: null,
            lastUsed: $now,
            usageCount: 1,
            healthStatus: "healthy"
        } |
        .sequence += [$num | tonumber] |
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"
    invalidate_cache
    complete_progress

    log_success "Added Account $account_num: $current_email"
}

# Remove account
cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        log_error "Usage: $0 --remove-account <account_number|email>"
        exit 1
    fi

    local identifier="$1"
    local account_num

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts are managed yet"
        exit 1
    fi

    migrate_sequence_file

    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        account_num="$identifier"
    else
        # Validate email format
        if ! validate_email "$identifier"; then
            log_error "Invalid email format: $identifier"
            exit 1
        fi

        # Resolve email to account number
        account_num=$(resolve_account_identifier "$identifier")
        if [[ -z "$account_num" ]]; then
            log_error "No account found with email: $identifier"
            exit 1
        fi
    fi

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        log_error "Account-$account_num does not exist"
        exit 1
    fi

    local email
    email=$(echo "$account_info" | jq -r '.email')

    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")

    if [[ "$active_account" == "$account_num" ]]; then
        log_warning "Account-$account_num ($email) is currently active"
    fi

    echo -e -n "${COLOR_YELLOW}Are you sure you want to permanently remove Account-$account_num ($email)?${COLOR_RESET} [y/N] "
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Cancelled"
        exit 0
    fi

    show_progress "Removing backup files"
    # Remove backup files
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security delete-generic-password -s "Claude Code-Account-${account_num}-${email}" 2>/dev/null || true
            ;;
        linux|wsl)
            rm -f "$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            ;;
    esac
    rm -f "$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    complete_progress

    show_progress "Updating account registry"
    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$num]) |
        .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"
    invalidate_cache
    complete_progress

    log_success "Account-$account_num ($email) has been removed"
}

# First-run setup workflow
first_run_setup() {
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "No active Claude account found. Please log in first."
        return 1
    fi
    
    echo -n "No managed accounts found. Add current account ($current_email) to managed list? [Y/n] "
    read -r response
    
    if [[ "$response" == "n" || "$response" == "N" ]]; then
        echo "Setup cancelled. You can run '$0 --add-account' later."
        return 1
    fi
    
    cmd_add_account
    return 0
}

# List accounts
cmd_list() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_info "No accounts are managed yet."
        first_run_setup
        exit 0
    fi

    migrate_sequence_file

    # Get current active account from .claude.json
    local current_email
    current_email=$(get_current_account)

    # Find which account number corresponds to the current email
    local active_account_num=""
    if [[ "$current_email" != "none" ]]; then
        active_account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    fi

    echo -e "${COLOR_BOLD}Accounts:${COLOR_RESET}"

    # Read each account and format with colors
    while IFS= read -r line; do
        local num email alias last_used usage_count health is_active
        num=$(echo "$line" | jq -r '.num')
        email=$(echo "$line" | jq -r '.email')
        alias=$(echo "$line" | jq -r '.alias // empty')
        last_used=$(echo "$line" | jq -r '.lastUsed // empty')
        usage_count=$(echo "$line" | jq -r '.usageCount // 0')
        health=$(echo "$line" | jq -r '.healthStatus // "unknown"')
        is_active=$(echo "$line" | jq -r '.isActive')

        # Format account line
        local account_line="  $num: $email"

        # Add alias if present
        if [[ -n "$alias" ]]; then
            account_line+=" ${COLOR_CYAN}[$alias]${COLOR_RESET}"
        fi

        # Add active indicator
        if [[ "$is_active" == "true" ]]; then
            account_line+=" ${COLOR_GREEN}(active)${COLOR_RESET}"
        fi

        # Add metadata on next line
        local metadata=""
        if [[ -n "$last_used" && "$last_used" != "null" ]]; then
            local last_used_formatted
            last_used_formatted=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_used" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$last_used")
            metadata+="     Last used: $last_used_formatted"
        fi

        if [[ "$usage_count" -gt 0 ]]; then
            metadata+=" | Used: ${usage_count}x"
        fi

        # Health indicator
        case "$health" in
            healthy)
                metadata+=" | ${COLOR_GREEN}●${COLOR_RESET} healthy"
                ;;
            degraded)
                metadata+=" | ${COLOR_YELLOW}●${COLOR_RESET} degraded"
                ;;
            unhealthy)
                metadata+=" | ${COLOR_RED}●${COLOR_RESET} unhealthy"
                ;;
        esac

        echo -e "$account_line"
        if [[ -n "$metadata" ]]; then
            echo -e "$metadata"
        fi
    done < <(jq -c --arg active "$active_account_num" '
        .sequence[] as $num |
        .accounts["\($num)"] + {
            num: $num,
            isActive: (if "\($num)" == $active then "true" else "false" end)
        }
    ' "$SEQUENCE_FILE")
}

# Switch to next account
cmd_switch() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found"
        exit 1
    fi
    
    # Check if current account is managed
    if ! account_exists "$current_email"; then
        echo "Notice: Active account '$current_email' was not managed."
        cmd_add_account
        local account_num
        account_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        echo "It has been automatically added as Account-$account_num."
        echo "Please run './ccswitch.sh --switch' again to switch to the next account."
        exit 0
    fi
    
    # wait_for_claude_close
    
    local active_account sequence
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    sequence=($(jq -r '.sequence[]' "$SEQUENCE_FILE"))
    
    # Find next account in sequence
    local next_account current_index=0
    for i in "${!sequence[@]}"; do
        if [[ "${sequence[i]}" == "$active_account" ]]; then
            current_index=$i
            break
        fi
    done
    
    next_account="${sequence[$(((current_index + 1) % ${#sequence[@]}))]}"
    
    perform_switch "$next_account"
}

# Switch to specific account
cmd_switch_to() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --switch-to <account_number|email>"
        exit 1
    fi
    
    local identifier="$1"
    local target_account
    
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    
    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        target_account="$identifier"
    else
        # Validate email format
        if ! validate_email "$identifier"; then
            echo "Error: Invalid email format: $identifier"
            exit 1
        fi
        
        # Resolve email to account number
        target_account=$(resolve_account_identifier "$identifier")
        if [[ -z "$target_account" ]]; then
            echo "Error: No account found with email: $identifier"
            exit 1
        fi
    fi
    
    local account_info
    account_info=$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    
    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$target_account does not exist"
        exit 1
    fi
    
    # wait_for_claude_close
    perform_switch "$target_account"
}

# Add history entry
add_history_entry() {
    local from_account="$1"
    local to_account="$2"
    local timestamp="$3"

    local updated_sequence
    updated_sequence=$(jq --arg from "$from_account" --arg to "$to_account" --arg ts "$timestamp" --argjson max "$MAX_HISTORY_ENTRIES" '
        .history += [{
            from: ($from | tonumber),
            to: ($to | tonumber),
            timestamp: $ts
        }] |
        .history = (.history | .[-$max:])
    ' "$SEQUENCE_FILE")

    echo "$updated_sequence"
}

# Perform the actual account switch
# Purpose: Switches authentication from current account to target account
# Parameters:
#   $1 - target_account: Account number to switch to
# Returns: Exit code 0 on success, 1 on failure
# Usage: perform_switch 2
# Side effects: Updates credentials, config files, and sequence.json with history
perform_switch() {
    local target_account="$1"

    show_progress "Validating target account"
    # Get current and target account info
    local current_account target_email current_email
    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
    current_email=$(get_current_account)
    complete_progress

    show_progress "Backing up current account"
    # Step 1: Backup current account (parallel safe operations)
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    write_account_credentials "$current_account" "$current_email" "$current_creds"
    write_account_config "$current_account" "$current_email" "$current_config"
    complete_progress

    show_progress "Retrieving target account data"
    # Step 2: Retrieve target account
    local target_creds target_config
    target_creds=$(read_account_credentials "$target_account" "$target_email")
    target_config=$(read_account_config "$target_account" "$target_email")

    if [[ -z "$target_creds" || -z "$target_config" ]]; then
        log_error "Missing backup data for Account-$target_account"
        exit 1
    fi
    complete_progress

    show_progress "Validating backup data"
    # Validate before switching
    if ! echo "$target_config" | jq -e '.oauthAccount' >/dev/null 2>&1; then
        log_error "Invalid oauthAccount in backup"
        exit 1
    fi
    complete_progress

    show_progress "Activating target account"
    # Step 3: Activate target account
    write_credentials "$target_creds"

    # Extract oauthAccount from backup and validate
    local oauth_section
    oauth_section=$(echo "$target_config" | jq '.oauthAccount' 2>/dev/null)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        log_error "Invalid oauthAccount in backup"
        exit 1
    fi

    # Merge with current config and validate
    local merged_config
    merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        log_error "Failed to merge config"
        exit 1
    fi

    # Use existing safe write_json function
    write_json "$(get_claude_config_path)" "$merged_config"
    complete_progress

    show_progress "Updating account metadata"
    # Step 4: Update state with history and metadata
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local updated_sequence
    updated_sequence=$(jq --arg num "$target_account" --arg now "$now" '
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now |
        .accounts[$num].lastUsed = $now |
        .accounts[$num].usageCount = ((.accounts[$num].usageCount // 0) + 1)
    ' "$SEQUENCE_FILE")

    # Add history entry
    updated_sequence=$(echo "$updated_sequence" | jq --arg from "$current_account" --arg to "$target_account" --arg ts "$now" --argjson max "$MAX_HISTORY_ENTRIES" '
        .history += [{
            from: ($from | tonumber),
            to: ($to | tonumber),
            timestamp: $ts
        }] |
        .history = (.history | .[-$max:])
    ')

    write_json "$SEQUENCE_FILE" "$updated_sequence"
    invalidate_cache
    complete_progress

    log_success "Switched to Account-$target_account ($target_email)"
    echo ""
    # Display updated account list
    cmd_list
    echo ""
    log_info "Please restart Claude Code to use the new authentication."
    echo ""
}

# Set account alias
# Purpose: Assigns a friendly name/alias to an account for easier identification
# Parameters:
#   $1 - identifier: Account number, email, or existing alias
#   $2 - alias: New alias to assign (alphanumeric, dash, underscore only)
# Returns: Exit code 0 on success, 1 on failure
# Usage: cmd_set_alias 1 work
cmd_set_alias() {
    if [[ $# -lt 2 ]]; then
        log_error "Usage: $0 --set-alias <account_number|email> <alias>"
        exit 1
    fi

    local identifier="$1"
    local alias="$2"
    local account_num

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts are managed yet"
        exit 1
    fi

    migrate_sequence_file

    # Resolve identifier to account number
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        account_num="$identifier"
    else
        if ! validate_email "$identifier"; then
            log_error "Invalid email format: $identifier"
            exit 1
        fi
        account_num=$(resolve_account_identifier "$identifier")
        if [[ -z "$account_num" ]]; then
            log_error "No account found with email: $identifier"
            exit 1
        fi
    fi

    # Validate account exists
    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    if [[ -z "$account_info" ]]; then
        log_error "Account-$account_num does not exist"
        exit 1
    fi

    # Validate alias format (alphanumeric, dash, underscore only)
    if [[ ! "$alias" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid alias format. Use only letters, numbers, dash, and underscore"
        exit 1
    fi

    show_progress "Setting alias for Account-$account_num"
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg alias "$alias" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num].alias = $alias |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"
    invalidate_cache
    complete_progress

    local email
    email=$(echo "$account_info" | jq -r '.email')
    log_success "Set alias '$alias' for Account-$account_num ($email)"
}

# Verify account backups
# Purpose: Validates integrity of account backups (credentials and config)
# Parameters:
#   $1 - target_account (optional): Specific account to verify, or all if omitted
# Returns: Exit code 0 if all verified accounts are healthy, 1 if issues found
# Usage: cmd_verify 1  OR  cmd_verify
cmd_verify() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts are managed yet"
        exit 1
    fi

    migrate_sequence_file

    local target_account="${1:-}"
    local accounts_to_check

    if [[ -n "$target_account" ]]; then
        # Verify specific account
        if [[ "$target_account" =~ ^[0-9]+$ ]]; then
            accounts_to_check=("$target_account")
        else
            local resolved
            resolved=$(resolve_account_identifier "$target_account")
            if [[ -z "$resolved" ]]; then
                log_error "No account found: $target_account"
                exit 1
            fi
            accounts_to_check=("$resolved")
        fi
    else
        # Verify all accounts
        mapfile -t accounts_to_check < <(jq -r '.sequence[]' "$SEQUENCE_FILE")
    fi

    echo -e "${COLOR_BOLD}Verification Results:${COLOR_RESET}"
    local all_healthy=1

    for account_num in "${accounts_to_check[@]}"; do
        local email health_status="healthy"
        email=$(jq -r --arg num "$account_num" '.accounts[$num].email' "$SEQUENCE_FILE")

        # Check if credentials exist
        local creds config
        creds=$(read_account_credentials "$account_num" "$email")
        config=$(read_account_config "$account_num" "$email")

        if [[ -z "$creds" ]]; then
            health_status="unhealthy"
            all_healthy=0
            echo -e "  ${COLOR_RED}✗${COLOR_RESET} Account-$account_num ($email): Missing credentials"
        elif [[ -z "$config" ]]; then
            health_status="unhealthy"
            all_healthy=0
            echo -e "  ${COLOR_RED}✗${COLOR_RESET} Account-$account_num ($email): Missing configuration"
        elif ! echo "$config" | jq -e '.oauthAccount' >/dev/null 2>&1; then
            health_status="degraded"
            all_healthy=0
            echo -e "  ${COLOR_YELLOW}⚠${COLOR_RESET} Account-$account_num ($email): Invalid configuration format"
        else
            echo -e "  ${COLOR_GREEN}✓${COLOR_RESET} Account-$account_num ($email): Healthy"
        fi

        # Update health status
        local updated_sequence
        updated_sequence=$(jq --arg num "$account_num" --arg health "$health_status" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
            .accounts[$num].healthStatus = $health |
            .lastUpdated = $now
        ' "$SEQUENCE_FILE")
        write_json "$SEQUENCE_FILE" "$updated_sequence"
    done

    invalidate_cache

    if [[ $all_healthy -eq 1 ]]; then
        echo ""
        log_success "All accounts verified successfully"
    else
        echo ""
        log_warning "Some accounts have issues. Run --add-account while logged in to repair."
    fi
}

# Show account status
cmd_status() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_info "No accounts are managed yet."
        exit 0
    fi

    migrate_sequence_file

    local current_email
    current_email=$(get_current_account)

    echo -e "${COLOR_BOLD}Claude Code Account Status${COLOR_RESET}"
    echo ""

    if [[ "$current_email" != "none" ]]; then
        local account_num
        account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)

        if [[ -n "$account_num" ]]; then
            local account_info
            account_info=$(jq -r --arg num "$account_num" '.accounts[$num]' "$SEQUENCE_FILE")

            local alias last_used usage_count health
            alias=$(echo "$account_info" | jq -r '.alias // "none"')
            last_used=$(echo "$account_info" | jq -r '.lastUsed // "unknown"')
            usage_count=$(echo "$account_info" | jq -r '.usageCount // 0')
            health=$(echo "$account_info" | jq -r '.healthStatus // "unknown"')

            echo -e "${COLOR_BOLD}Active Account:${COLOR_RESET} $current_email ${COLOR_GREEN}(Account-$account_num)${COLOR_RESET}"
            echo -e "  Alias: $alias"
            echo -e "  Usage count: ${usage_count}x"

            if [[ "$last_used" != "unknown" && "$last_used" != "null" ]]; then
                local last_used_formatted
                last_used_formatted=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_used" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$last_used")
                echo -e "  Last used: $last_used_formatted"
            fi

            case "$health" in
                healthy) echo -e "  Health: ${COLOR_GREEN}●${COLOR_RESET} healthy" ;;
                degraded) echo -e "  Health: ${COLOR_YELLOW}●${COLOR_RESET} degraded" ;;
                unhealthy) echo -e "  Health: ${COLOR_RED}●${COLOR_RESET} unhealthy" ;;
                *) echo -e "  Health: unknown" ;;
            esac
        else
            echo -e "${COLOR_BOLD}Active Account:${COLOR_RESET} $current_email ${COLOR_YELLOW}(not managed)${COLOR_RESET}"
        fi
    else
        echo -e "${COLOR_BOLD}Active Account:${COLOR_RESET} ${COLOR_RED}None${COLOR_RESET}"
    fi

    echo ""
    local total_accounts
    total_accounts=$(jq '.accounts | length' "$SEQUENCE_FILE")
    echo -e "${COLOR_BOLD}Total managed accounts:${COLOR_RESET} $total_accounts"

    local schema_version
    schema_version=$(jq -r '.schemaVersion // "1.0"' "$SEQUENCE_FILE")
    echo -e "${COLOR_BOLD}Data version:${COLOR_RESET} $schema_version"
}

# Show switch history
cmd_history() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_info "No switch history yet."
        exit 0
    fi

    migrate_sequence_file

    local history_count
    history_count=$(jq '.history | length' "$SEQUENCE_FILE")

    if [[ "$history_count" -eq 0 ]]; then
        log_info "No switch history yet."
        exit 0
    fi

    echo -e "${COLOR_BOLD}Account Switch History:${COLOR_RESET}"
    echo ""

    jq -r '.history | reverse | .[] |
        @json' "$SEQUENCE_FILE" | while read -r entry; do
        local from_num to_num timestamp
        from_num=$(echo "$entry" | jq -r '.from')
        to_num=$(echo "$entry" | jq -r '.to')
        timestamp=$(echo "$entry" | jq -r '.timestamp')

        local from_email to_email
        from_email=$(jq -r --arg num "$from_num" '.accounts["\($num)"].email // "Unknown"' "$SEQUENCE_FILE")
        to_email=$(jq -r --arg num "$to_num" '.accounts["\($num)"].email // "Unknown"' "$SEQUENCE_FILE")

        local time_formatted
        time_formatted=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$timestamp")

        echo -e "  ${COLOR_CYAN}→${COLOR_RESET} $time_formatted: Account-$from_num ($from_email) → Account-$to_num ($to_email)"
    done
}

# Undo last switch
cmd_undo() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts are managed yet"
        exit 1
    fi

    migrate_sequence_file

    local history_count
    history_count=$(jq '.history | length' "$SEQUENCE_FILE")

    if [[ "$history_count" -eq 0 ]]; then
        log_error "No switch history to undo"
        exit 1
    fi

    # Get last history entry
    local last_entry from_account
    last_entry=$(jq -r '.history | last' "$SEQUENCE_FILE")
    from_account=$(echo "$last_entry" | jq -r '.from')

    # Verify account still exists
    local account_exists
    account_exists=$(jq -e --arg num "$from_account" '.accounts[$num]' "$SEQUENCE_FILE" >/dev/null 2>&1 && echo "yes" || echo "no")

    if [[ "$account_exists" != "yes" ]]; then
        log_error "Cannot undo: Previous account (Account-$from_account) no longer exists"
        exit 1
    fi

    log_info "Undoing last switch to Account-$from_account..."
    perform_switch "$from_account"
}

# Export accounts to encrypted archive
cmd_export() {
    if [[ $# -eq 0 ]]; then
        log_error "Usage: $0 --export <output_path>"
        exit 1
    fi

    local output_path="$1"

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts to export"
        exit 1
    fi

    migrate_sequence_file

    show_progress "Creating export archive"

    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" EXIT

    # Copy sequence file
    cp "$SEQUENCE_FILE" "$temp_dir/sequence.json"

    # Copy configs
    cp -r "$BACKUP_DIR/configs" "$temp_dir/" 2>/dev/null || true

    # Export credentials based on platform
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            # Export macOS keychain entries
            local creds_dir="$temp_dir/credentials"
            mkdir -p "$creds_dir"

            while IFS= read -r line; do
                local num email
                num=$(echo "$line" | jq -r '.num')
                email=$(echo "$line" | jq -r '.email')

                local creds
                creds=$(read_account_credentials "$num" "$email")
                if [[ -n "$creds" ]]; then
                    echo "$creds" > "$creds_dir/.claude-credentials-${num}-${email}.json"
                    chmod 600 "$creds_dir/.claude-credentials-${num}-${email}.json"
                fi
            done < <(jq -c '.accounts | to_entries[] | {num: .key, email: .value.email}' "$SEQUENCE_FILE")
            ;;
        linux|wsl)
            # Copy credential files directly
            cp -r "$BACKUP_DIR/credentials" "$temp_dir/" 2>/dev/null || true
            ;;
    esac

    # Create tar archive
    tar -czf "$output_path" -C "$temp_dir" . 2>/dev/null
    complete_progress

    log_success "Exported to: $output_path"
    log_warning "Keep this file secure - it contains authentication credentials"
}

# Import accounts from archive
cmd_import() {
    if [[ $# -eq 0 ]]; then
        log_error "Usage: $0 --import <archive_path>"
        exit 1
    fi

    local archive_path="$1"

    if [[ ! -f "$archive_path" ]]; then
        log_error "Archive file not found: $archive_path"
        exit 1
    fi

    echo -e -n "${COLOR_YELLOW}This will merge imported accounts with existing ones. Continue?${COLOR_RESET} [y/N] "
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Cancelled"
        exit 0
    fi

    setup_directories
    init_sequence_file

    show_progress "Extracting archive"
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" EXIT

    tar -xzf "$archive_path" -C "$temp_dir" 2>/dev/null || {
        log_error "Failed to extract archive"
        exit 1
    }
    complete_progress

    if [[ ! -f "$temp_dir/sequence.json" ]]; then
        log_error "Invalid archive: missing sequence.json"
        exit 1
    fi

    show_progress "Importing accounts"

    # Merge sequence files
    local imported_sequence current_sequence merged_sequence
    imported_sequence=$(cat "$temp_dir/sequence.json")
    current_sequence=$(cat "$SEQUENCE_FILE")

    # Import each account
    local platform
    platform=$(detect_platform)

    while IFS= read -r line; do
        local num email
        num=$(echo "$line" | jq -r '.num')
        email=$(echo "$line" | jq -r '.email')

        # Check if account already exists
        if account_exists "$email"; then
            log_info "Skipping existing account: $email"
            continue
        fi

        # Get next available account number
        local new_num
        new_num=$(get_next_account_number)

        # Import config
        local config_file="$temp_dir/configs/.claude-config-${num}-${email}.json"
        if [[ -f "$config_file" ]]; then
            write_account_config "$new_num" "$email" "$(cat "$config_file")"
        fi

        # Import credentials
        case "$platform" in
            macos)
                local cred_file="$temp_dir/credentials/.claude-credentials-${num}-${email}.json"
                if [[ -f "$cred_file" ]]; then
                    write_account_credentials "$new_num" "$email" "$(cat "$cred_file")"
                fi
                ;;
            linux|wsl)
                local cred_file="$temp_dir/credentials/.claude-credentials-${num}-${email}.json"
                if [[ -f "$cred_file" ]]; then
                    cp "$cred_file" "$BACKUP_DIR/credentials/.claude-credentials-${new_num}-${email}.json"
                    chmod 600 "$BACKUP_DIR/credentials/.claude-credentials-${new_num}-${email}.json"
                fi
                ;;
        esac

        # Add to sequence
        local account_data
        account_data=$(echo "$imported_sequence" | jq -r --arg num "$num" '.accounts[$num]')

        local updated_sequence
        updated_sequence=$(jq --arg num "$new_num" --argjson data "$account_data" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
            .accounts[$num] = $data |
            .accounts[$num].added = $now |
            .sequence += [$num | tonumber] |
            .lastUpdated = $now
        ' "$SEQUENCE_FILE")

        write_json "$SEQUENCE_FILE" "$updated_sequence"

        log_info "Imported: $email as Account-$new_num"
    done < <(echo "$imported_sequence" | jq -c '.accounts | to_entries[] | {num: .key, email: .value.email}')

    invalidate_cache
    complete_progress

    log_success "Import completed"
}

# Interactive mode
# Purpose: Launches a menu-driven interface for account management
# Parameters: None
# Returns: Runs until user quits
# Usage: cmd_interactive
cmd_interactive() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_info "No accounts are managed yet."
        first_run_setup || exit 1
    fi

    migrate_sequence_file

    while true; do
        clear
        echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════════╗${COLOR_RESET}"
        echo -e "${COLOR_BOLD}║  Multi-Account Switcher for Claude Code         ║${COLOR_RESET}"
        echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════════╝${COLOR_RESET}"
        echo ""

        # Show current account
        local current_email
        current_email=$(get_current_account)

        if [[ "$current_email" != "none" ]]; then
            local account_num
            account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
            if [[ -n "$account_num" ]]; then
                local alias
                alias=$(jq -r --arg num "$account_num" '.accounts[$num].alias // "no alias"' "$SEQUENCE_FILE")
                echo -e "${COLOR_GREEN}●${COLOR_RESET} Current: Account-$account_num ($current_email) [$alias]"
            else
                echo -e "${COLOR_YELLOW}●${COLOR_RESET} Current: $current_email (not managed)"
            fi
        else
            echo -e "${COLOR_RED}●${COLOR_RESET} No active account"
        fi
        echo ""

        echo -e "${COLOR_BOLD}Available Accounts:${COLOR_RESET}"
        local idx=1
        declare -A account_map
        while IFS= read -r line; do
            local num email alias is_active
            num=$(echo "$line" | jq -r '.num')
            email=$(echo "$line" | jq -r '.email')
            alias=$(echo "$line" | jq -r '.alias // ""')
            is_active=$(echo "$line" | jq -r '.isActive')

            account_map[$idx]=$num

            local display="  $idx) Account-$num: $email"
            if [[ -n "$alias" ]]; then
                display+=" ${COLOR_CYAN}[$alias]${COLOR_RESET}"
            fi
            if [[ "$is_active" == "true" ]]; then
                display+=" ${COLOR_GREEN}(active)${COLOR_RESET}"
            fi
            echo -e "$display"
            ((idx++))
        done < <(jq -c --arg active "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" '
            .sequence[] as $num |
            .accounts["\($num)"] + {
                num: $num,
                isActive: (if "\($num)" == $active then "true" else "false" end)
            }
        ' "$SEQUENCE_FILE")

        echo ""
        echo -e "${COLOR_BOLD}Actions:${COLOR_RESET}"
        echo "  s) Switch to next account"
        echo "  a) Add current account"
        echo "  v) Verify all accounts"
        echo "  h) View switch history"
        echo "  u) Undo last switch"
        echo "  q) Quit"
        echo ""
        echo -n "Select an option (1-$((idx-1)) or action): "

        read -r choice

        case "$choice" in
            [0-9]*)
                if [[ -n "${account_map[$choice]:-}" ]]; then
                    local target_num="${account_map[$choice]}"
                    echo ""
                    perform_switch "$target_num"
                    echo ""
                    read -p "Press Enter to continue..."
                else
                    log_error "Invalid selection"
                    sleep 1
                fi
                ;;
            s|S)
                echo ""
                cmd_switch
                echo ""
                read -p "Press Enter to continue..."
                ;;
            a|A)
                echo ""
                cmd_add_account
                echo ""
                read -p "Press Enter to continue..."
                ;;
            v|V)
                echo ""
                cmd_verify
                echo ""
                read -p "Press Enter to continue..."
                ;;
            h|H)
                echo ""
                cmd_history
                echo ""
                read -p "Press Enter to continue..."
                ;;
            u|U)
                echo ""
                cmd_undo
                echo ""
                read -p "Press Enter to continue..."
                ;;
            q|Q)
                echo ""
                log_info "Goodbye!"
                exit 0
                ;;
            *)
                log_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# Show usage
show_usage() {
    echo -e "${COLOR_BOLD}Multi-Account Switcher for Claude Code${COLOR_RESET}"
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo -e "${COLOR_BOLD}Account Management:${COLOR_RESET}"
    echo "  --add-account                      Add current account to managed accounts"
    echo "  --remove-account <num|email>       Remove account by number or email"
    echo "  --list                             List all managed accounts with metadata"
    echo "  --status                           Show detailed status of active account"
    echo ""
    echo -e "${COLOR_BOLD}Switching:${COLOR_RESET}"
    echo "  --switch                           Rotate to next account in sequence"
    echo "  --switch-to <num|email|alias>      Switch to specific account"
    echo "  --undo                             Undo last account switch"
    echo "  --history                          Show account switch history"
    echo ""
    echo -e "${COLOR_BOLD}Aliases:${COLOR_RESET}"
    echo "  --set-alias <num|email> <alias>    Set friendly name for an account"
    echo ""
    echo -e "${COLOR_BOLD}Verification & Backup:${COLOR_RESET}"
    echo "  --verify [num|email]               Verify account backups (all or specific)"
    echo "  --export <path>                    Export all accounts to archive"
    echo "  --import <path>                    Import accounts from archive"
    echo ""
    echo -e "${COLOR_BOLD}Interactive:${COLOR_RESET}"
    echo "  --interactive                      Launch interactive menu mode"
    echo ""
    echo -e "${COLOR_BOLD}General:${COLOR_RESET}"
    echo "  --help                             Show this help message"
    echo "  --no-color                         Disable colored output (or set NO_COLOR=1)"
    echo ""
    echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
    echo "  $0 --interactive"
    echo "  $0 --add-account"
    echo "  $0 --set-alias 1 work"
    echo "  $0 --list"
    echo "  $0 --switch-to work"
    echo "  $0 --switch-to user@example.com"
    echo "  $0 --verify"
    echo "  $0 --export ~/accounts-backup.tar.gz"
    echo "  $0 --history"
    echo "  $0 --undo"
}

# Main script logic
main() {
    # Handle --no-color flag
    if [[ "${1:-}" == "--no-color" ]]; then
        NO_COLOR=1
        shift
    fi

    # Basic checks - allow root execution in containers
    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        log_error "Do not run this script as root (unless running in a container)"
        exit 1
    fi

    check_bash_version
    check_dependencies

    case "${1:-}" in
        --interactive|-i)
            cmd_interactive
            ;;
        --add-account)
            cmd_add_account
            ;;
        --remove-account)
            shift
            cmd_remove_account "$@"
            ;;
        --list)
            cmd_list
            ;;
        --status)
            cmd_status
            ;;
        --switch)
            cmd_switch
            ;;
        --switch-to)
            shift
            cmd_switch_to "$@"
            ;;
        --set-alias)
            shift
            cmd_set_alias "$@"
            ;;
        --verify)
            shift
            cmd_verify "$@"
            ;;
        --export)
            shift
            cmd_export "$@"
            ;;
        --import)
            shift
            cmd_import "$@"
            ;;
        --history)
            cmd_history
            ;;
        --undo)
            cmd_undo
            ;;
        --help)
            show_usage
            ;;
        "")
            show_usage
            ;;
        *)
            log_error "Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi