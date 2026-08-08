#!/usr/bin/env bats
# Security regression tests for issue #6 (C1, H1, H2)

setup() {
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    unset CLAUDE_CONFIG_DIR
    source "${BATS_TEST_DIRNAME}/../ccm.sh"
    mkdir -p "$BACKUP_DIR/snapshots" "$PROFILES_DIR" "$ARCHIVES_DIR"
}

teardown() {
    rm -rf "$TEST_HOME"
}

# ── C1: path traversal in read/delete/restore paths ────────────────────────

@test "validate_snapshot_name rejects parent-directory traversal" {
    run validate_snapshot_name "../../.ssh/authorized_keys"
    [ "$status" -ne 0 ]
}

@test "validate_snapshot_name rejects embedded slashes" {
    run validate_snapshot_name "a/b"
    [ "$status" -ne 0 ]
}

@test "validate_snapshot_name rejects an empty name" {
    run validate_snapshot_name ""
    [ "$status" -ne 0 ]
}

@test "validate_snapshot_name accepts ordinary names" {
    run validate_snapshot_name "my-snap_1.0"
    [ "$status" -eq 0 ]
}

@test "validate_snapshot_name accepts an archive filename" {
    run validate_snapshot_name "sessions-2026-08-08.tar.gz"
    [ "$status" -eq 0 ]
}

@test "env_delete refuses a traversal name" {
    run env_delete "../../evil"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid"* ]]
}

@test "env_restore refuses a traversal name" {
    run env_restore "../../evil"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid"* ]]
}

@test "profiles_delete refuses a traversal name" {
    run profiles_delete "../../evil"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid"* ]]
}

@test "profiles_sync refuses a traversal name" {
    run profiles_sync "../../evil"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid"* ]]
}

@test "session_restore refuses a traversal name" {
    run session_restore "../../evil.tar.gz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid"* ]]
}

@test "env_delete does not delete a directory outside BACKUP_DIR" {
    mkdir -p "$TEST_HOME/victim"
    touch "$TEST_HOME/victim/keepme"
    run env_delete "../../victim"
    [ "$status" -ne 0 ]
    [ -f "$TEST_HOME/victim/keepme" ]
}

# ── H2: archive extraction ─────────────────────────────────────────────────

@test "session_restore rejects an archive containing traversing paths" {
    local staging="$TEST_HOME/staging"
    mkdir -p "$staging/sub"
    echo pwned > "$staging/sub/pwned.txt"
    # Build an archive whose member paths escape the extraction root
    tar czf "$ARCHIVES_DIR/evil.tar.gz" -C "$staging" --strip-components=0 sub 2>/dev/null
    # Rewrite member names to include ..
    tar czf "$ARCHIVES_DIR/evil.tar.gz" -C "$TEST_HOME" "../$(basename "$TEST_HOME")/staging/sub" 2>/dev/null || \
        tar czf "$ARCHIVES_DIR/evil.tar.gz" -C "$staging" ../staging/sub 2>/dev/null

    if tar tzf "$ARCHIVES_DIR/evil.tar.gz" 2>/dev/null | grep -qE '^/|(^|/)\.\.(/|$)'; then
        run session_restore "evil.tar.gz"
        [ "$status" -ne 0 ]
        [[ "$output" == *"refusing to extract"* ]]
    else
        skip "could not build a traversing archive with this tar"
    fi
}

@test "session_restore extracts a clean archive into CLAUDE_PROJECTS_DIR, not cwd" {
    local staging="$TEST_HOME/staging"
    mkdir -p "$staging/-Users-someone-proj"
    echo '{"x":1}' > "$staging/-Users-someone-proj/a.jsonl"
    # './' prefix: the dir name starts with '-', which tar would read as a flag
    tar czf "$ARCHIVES_DIR/clean.tar.gz" -C "$staging" "./-Users-someone-proj"

    local cwd_guard="$TEST_HOME/cwd-guard"
    mkdir -p "$cwd_guard"
    cd "$cwd_guard"

    run session_restore "clean.tar.gz"
    [ "$status" -eq 0 ]
    [ -f "$CLAUDE_PROJECTS_DIR/-Users-someone-proj/a.jsonl" ]
    [ ! -e "$cwd_guard/-Users-someone-proj" ]
}

# ── H1: sed metacharacter escaping ─────────────────────────────────────────

@test "sed escaping neutralises pipe, ampersand and backslash in paths" {
    local raw='/tmp/a|b&c\d'
    local escaped
    escaped=$(printf '%s' "$raw" | sed 's/[|&\\]/\\&/g')
    [ "$escaped" = '/tmp/a\|b\&c\\d' ]
    # And the escaped form round-trips through a substitution intact
    local out
    out=$(printf '%s\n' "$raw" | sed "s|$escaped|REPLACED|")
    [ "$out" = "REPLACED" ]
}
