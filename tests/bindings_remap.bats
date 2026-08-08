#!/usr/bin/env bats
# Tests for remap_bindings — the reorder binding remap (issue #8)
#
# These call ccm.sh's own remap_bindings function rather than a copy of its
# jq expression, so reintroducing the `. as $v` bug in ccm.sh fails the suite.

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

# Purpose: Calls ccm.sh's remap_bindings and compacts the result for comparison
# Parameters: $1 — sequence JSON, $2 — account number map JSON
# Returns: Prints the remapped JSON on a single line
# Usage: run remap '{"bindings":{}}' '{"1":"2"}'
remap() {
    remap_bindings "$1" "$2" | jq -c .
}

@test "remap_bindings is defined by ccm.sh" {
    run declare -F remap_bindings
    [ "$status" -eq 0 ]
}

@test "remaps binding values to their new account numbers" {
    run remap '{"bindings":{"/p/alpha":"1","/p/beta":"3"}}' '{"1":"2","3":"1"}'
    [ "$status" -eq 0 ]
    [ "$output" = '{"bindings":{"/p/alpha":"2","/p/beta":"1"}}' ]
}

@test "leaves unmapped binding values untouched" {
    run remap '{"bindings":{"/p/alpha":"7"}}' '{"1":"2"}'
    [ "$status" -eq 0 ]
    [ "$output" = '{"bindings":{"/p/alpha":"7"}}' ]
}

@test "never produces object-valued bindings" {
    run remap '{"bindings":{"/p/alpha":"1"}}' '{"1":"2"}'
    [ "$status" -eq 0 ]
    [[ "$output" != *'"key"'* ]]
}

@test "handles an empty bindings object" {
    run remap '{"bindings":{}}' '{"1":"2"}'
    [ "$status" -eq 0 ]
    [ "$output" = '{"bindings":{}}' ]
}

@test "handles a missing bindings key" {
    run remap '{}' '{"1":"2"}'
    [ "$status" -eq 0 ]
    [ "$output" = '{"bindings":{}}' ]
}

@test "preserves other top-level keys while remapping" {
    run remap '{"schemaVersion":"3.1","bindings":{"/p/a":"1"}}' '{"1":"2"}'
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.schemaVersion')" = "3.1" ]
    [ "$(echo "$output" | jq -r '.bindings["/p/a"]')" = "2" ]
}
