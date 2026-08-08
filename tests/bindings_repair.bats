#!/usr/bin/env bats
# Tests for repair_bindings — recovery from issue #8 corruption

setup() {
    # Set HOME before sourcing so readonly globals (BACKUP_DIR etc.) use TEST_HOME
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    unset CLAUDE_CONFIG_DIR

    # BASH_SOURCE guard in ccm.sh prevents main() from running when sourced
    # shellcheck source=../ccm.sh
    source "${BATS_TEST_DIRNAME}/../ccm.sh"
    mkdir -p "$BACKUP_DIR"
}

teardown() {
    rm -rf "$TEST_HOME"
}

# Purpose: Writes a sequence.json containing the given bindings fragment
# Parameters: $1 — JSON value for the .bindings key
# Returns: Nothing (writes $SEQUENCE_FILE)
# Usage: write_seq '{"/p/alpha":"1"}'
write_seq() {
    printf '{"schemaVersion":"3.1","accounts":{},"bindings":%s}\n' "$1" > "$SEQUENCE_FILE"
}

@test "unwraps singly-nested corrupted bindings" {
    write_seq '{"/p/alpha":{"key":"/p/alpha","value":"1"}}'
    run repair_bindings
    [ "$status" -eq 0 ]
    [ "$(jq -c '.bindings' "$SEQUENCE_FILE")" = '{"/p/alpha":"1"}' ]
}

@test "unwraps doubly-nested corrupted bindings from repeated reorders" {
    write_seq '{"/p/a":{"key":"/p/a","value":{"key":"/p/a","value":"2"}}}'
    run repair_bindings
    [ "$status" -eq 0 ]
    [ "$(jq -c '.bindings' "$SEQUENCE_FILE")" = '{"/p/a":"2"}' ]
}

@test "leaves healthy bindings untouched" {
    write_seq '{"/p/alpha":"1","/p/beta":"2"}'
    run repair_bindings
    [ "$status" -eq 0 ]
    [ "$(jq -c '.bindings' "$SEQUENCE_FILE")" = '{"/p/alpha":"1","/p/beta":"2"}' ]
}

@test "makes no backup when bindings are already healthy" {
    write_seq '{"/p/alpha":"1"}'
    run repair_bindings
    [ "$status" -eq 0 ]
    run bash -c "ls '$BACKUP_DIR'/sequence.json.backup-bindings-* 2>/dev/null | wc -l"
    [ "$(echo "$output" | tr -d ' ')" = "0" ]
}

@test "writes a backup before repairing" {
    write_seq '{"/p/alpha":{"key":"/p/alpha","value":"1"}}'
    run repair_bindings
    [ "$status" -eq 0 ]
    run bash -c "ls '$BACKUP_DIR'/sequence.json.backup-bindings-* 2>/dev/null | wc -l"
    [ "$(echo "$output" | tr -d ' ')" = "1" ]
}

@test "coerces numeric binding values to strings" {
    write_seq '{"/p/alpha":1}'
    run repair_bindings
    [ "$status" -eq 0 ]
    [ "$(jq -c '.bindings' "$SEQUENCE_FILE")" = '{"/p/alpha":"1"}' ]
}

@test "drops unrecoverable binding values but keeps healthy ones" {
    write_seq '{"/p/alpha":{"nope":true},"/p/beta":"2"}'
    run repair_bindings
    [ "$status" -eq 0 ]
    [ "$(jq -c '.bindings' "$SEQUENCE_FILE")" = '{"/p/beta":"2"}' ]
}

@test "drops non-numeric string values" {
    write_seq '{"/p/alpha":{"key":"/p/alpha","value":"not-a-number"},"/p/beta":"2"}'
    run repair_bindings
    [ "$status" -eq 0 ]
    [ "$(jq -c '.bindings' "$SEQUENCE_FILE")" = '{"/p/beta":"2"}' ]
}

@test "is idempotent" {
    write_seq '{"/p/alpha":{"key":"/p/alpha","value":"1"}}'
    repair_bindings
    run repair_bindings
    [ "$status" -eq 0 ]
    [ "$(jq -c '.bindings' "$SEQUENCE_FILE")" = '{"/p/alpha":"1"}' ]
}

@test "preserves other top-level keys" {
    write_seq '{"/p/alpha":{"key":"/p/alpha","value":"1"}}'
    run repair_bindings
    [ "$status" -eq 0 ]
    [ "$(jq -r '.schemaVersion' "$SEQUENCE_FILE")" = "3.1" ]
}

@test "is a no-op when sequence.json does not exist" {
    rm -f "$SEQUENCE_FILE"
    run repair_bindings
    [ "$status" -eq 0 ]
}

@test "migrate_sequence_file repairs even at the current schema version" {
    # The version check in migrate_sequence_file early-returns at $SCHEMA_VERSION;
    # repair must still run, since corruption exists at the current version.
    printf '{"schemaVersion":"%s","accounts":{},"bindings":{"/p/a":{"key":"/p/a","value":"3"}}}\n' \
        "$SCHEMA_VERSION" > "$SEQUENCE_FILE"
    run migrate_sequence_file
    [ "$status" -eq 0 ]
    [ "$(jq -c '.bindings' "$SEQUENCE_FILE")" = '{"/p/a":"3"}' ]
}
