#!/usr/bin/env bats
# Tests for get_claude_config_path, focused on CLAUDE_CONFIG_DIR support

setup() {
    # Set HOME before sourcing so readonly globals (BACKUP_DIR etc.) use TEST_HOME
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    unset CLAUDE_CONFIG_DIR

    # BASH_SOURCE guard in ccm.sh prevents main() from running when sourced
    # shellcheck source=../ccm.sh
    source "${BATS_TEST_DIRNAME}/../ccm.sh"
}

teardown() {
    rm -rf "$TEST_HOME"
}

# ---------------------------------------------------------------------------
# CLAUDE_CONFIG_DIR behaviour
# ---------------------------------------------------------------------------

@test "returns CLAUDE_CONFIG_DIR/.claude.json when env var is set and file exists" {
    local custom_dir="$TEST_HOME/.claude-custom"
    mkdir -p "$custom_dir"
    printf '{"oauthAccount":{"emailAddress":"test@example.com"}}\n' \
        > "$custom_dir/.claude.json"

    export CLAUDE_CONFIG_DIR="$custom_dir"
    run get_claude_config_path

    [ "$status" -eq 0 ]
    [ "$output" = "$custom_dir/.claude.json" ]
}

@test "falls through to primary when CLAUDE_CONFIG_DIR is set but .claude.json is absent" {
    local custom_dir="$TEST_HOME/.claude-empty"
    mkdir -p "$custom_dir"
    # No .claude.json in custom_dir — should fall through

    mkdir -p "$TEST_HOME/.claude"
    printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}\n' \
        > "$TEST_HOME/.claude/.claude.json"

    export CLAUDE_CONFIG_DIR="$custom_dir"
    run get_claude_config_path

    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_HOME/.claude/.claude.json" ]
}

# ---------------------------------------------------------------------------
# Original behaviour (CLAUDE_CONFIG_DIR unset)
# ---------------------------------------------------------------------------

@test "returns ~/.claude/.claude.json when CLAUDE_CONFIG_DIR is unset and primary exists" {
    mkdir -p "$TEST_HOME/.claude"
    printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}\n' \
        > "$TEST_HOME/.claude/.claude.json"

    run get_claude_config_path

    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_HOME/.claude/.claude.json" ]
}

@test "skips primary when it has no oauthAccount and returns ~/.claude.json fallback" {
    mkdir -p "$TEST_HOME/.claude"
    printf '{"someOtherField":true}\n' > "$TEST_HOME/.claude/.claude.json"

    run get_claude_config_path

    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_HOME/.claude.json" ]
}

@test "returns ~/.claude.json fallback when CLAUDE_CONFIG_DIR is unset and primary is missing" {
    # Neither ~/.claude/.claude.json nor CLAUDE_CONFIG_DIR — pure fallback path
    run get_claude_config_path

    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_HOME/.claude.json" ]
}
