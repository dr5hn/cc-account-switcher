#!/usr/bin/env bats
# Regression tests for `ccm hook --isolated` (issue #9)
#
# Before the fix the hook compared the bound account number against
# _ccm_active_account (seeded from activeAccountNumber). Two consequences:
#   1. a directory bound to the DEFAULT account never exported anything
#   2. a stale CLAUDE_CONFIG_DIR in a long-lived shell was never corrected
# The hook now compares the resolved profile path against CLAUDE_CONFIG_DIR.

setup() {
    TEST_HOME="$(mktemp -d)"
    CCM_SH="${BATS_TEST_DIRNAME}/../ccm.sh"

    PROFILE_DIR="$TEST_HOME/.claude-switch-backup/profiles/personal"
    BOUND_DIR="$TEST_HOME/bound-dir"
    mkdir -p "$PROFILE_DIR" "$BOUND_DIR" "$TEST_HOME/stubbin"

    # Account 1 is the active/default account AND the bound account —
    # precisely the case issue #9 reported as broken.
    cat > "$TEST_HOME/.claude-switch-backup/sequence.json" <<JSON
{"schemaVersion":"3.1","activeAccountNumber":"1",
 "accounts":{"1":{"email":"a@example.com","alias":"personal"}},
 "bindings":{"$BOUND_DIR":"1"}}
JSON

    # Stub the ccm the hook shells out to; it just prints the profile path.
    printf '#!/bin/sh\necho "%s"\n' "$PROFILE_DIR" > "$TEST_HOME/stubbin/ccm"
    chmod +x "$TEST_HOME/stubbin/ccm"

    # Generate the hook from the ccm.sh under test, then point it at TEST_HOME
    bash "$CCM_SH" hook --isolated > "$TEST_HOME/hook.sh" 2>/dev/null

    export HOME="$TEST_HOME"
    export PATH="$TEST_HOME/stubbin:$PATH"
    unset CLAUDE_CONFIG_DIR
}

teardown() {
    rm -rf "$TEST_HOME"
}

@test "a directory bound to the default account exports CLAUDE_CONFIG_DIR" {
    run bash -c "
        source '$TEST_HOME/hook.sh'
        cd '$BOUND_DIR'
        _ccm_check_binding >/dev/null 2>&1
        echo \"\$CLAUDE_CONFIG_DIR\"
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$PROFILE_DIR" ]
}

@test "a stale CLAUDE_CONFIG_DIR is corrected on cd" {
    run bash -c "
        source '$TEST_HOME/hook.sh'
        export CLAUDE_CONFIG_DIR=/tmp/stale-from-last-week
        cd '$BOUND_DIR'
        _ccm_check_binding >/dev/null 2>&1
        echo \"\$CLAUDE_CONFIG_DIR\"
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$PROFILE_DIR" ]
}

@test "re-entering an already-active directory announces nothing" {
    run bash -c "
        source '$TEST_HOME/hook.sh'
        cd '$BOUND_DIR'
        _ccm_check_binding >/dev/null 2>&1
        _ccm_check_binding 2>&1
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "an unbound directory leaves CLAUDE_CONFIG_DIR alone" {
    run bash -c "
        source '$TEST_HOME/hook.sh'
        cd '$TEST_HOME'
        _ccm_check_binding >/dev/null 2>&1
        echo \"\${CLAUDE_CONFIG_DIR:-<unset>}\"
    "
    [ "$status" -eq 0 ]
    [ "$output" = "<unset>" ]
}

@test "the generated isolated hook is valid bash" {
    run bash -n "$TEST_HOME/hook.sh"
    [ "$status" -eq 0 ]
}

@test "the generated isolated hook no longer compares account numbers" {
    run grep -c 'bound_account" != "$_ccm_active_account' "$TEST_HOME/hook.sh"
    [ "$output" = "0" ]
}
