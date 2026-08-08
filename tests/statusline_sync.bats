#!/usr/bin/env bats
# Guards the statusline against silent divergence.
#
# The statusline exists twice: as a heredoc inside cmd_statusline() in ccm.sh,
# and as the standalone installer statusline.sh. CLAUDE.md requires both to be
# updated together. PR #7 patched only ccm.sh, which is exactly the failure
# these tests catch.

setup() {
    CCM_SH="${BATS_TEST_DIRNAME}/../ccm.sh"
    STATUSLINE_SH="${BATS_TEST_DIRNAME}/../statusline.sh"
}

# Purpose: Extracts the CLAUDE_CONFIG_DIR-aware CONF resolution block
# Parameters: $1 — file to extract from
# Returns: Prints the block, whitespace-normalised
conf_block() {
    grep -A8 'Resolve the config file for the ACTIVE session' "$1" | sed 's/[[:space:]]\+/ /g'
}

@test "both statusline sources resolve CONF identically" {
    run diff <(conf_block "$CCM_SH") <(conf_block "$STATUSLINE_SH")
    [ "$status" -eq 0 ]
}

@test "ccm.sh statusline honors CLAUDE_CONFIG_DIR" {
    run grep -c 'CONF="$CLAUDE_CONFIG_DIR/.claude.json"' "$CCM_SH"
    [ "$output" -ge 1 ]
}

@test "statusline.sh honors CLAUDE_CONFIG_DIR" {
    run grep -c 'CONF="$CLAUDE_CONFIG_DIR/.claude.json"' "$STATUSLINE_SH"
    [ "$output" -ge 1 ]
}

@test "neither source keeps the old unconditional global path" {
    run grep -c '^CONF="$HOME/.claude/.claude.json"$' "$STATUSLINE_SH"
    [ "$output" = "0" ]
}

@test "statusline.sh is valid bash" {
    run bash -n "$STATUSLINE_SH"
    [ "$status" -eq 0 ]
}
