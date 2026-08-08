#!/usr/bin/env bats
# Tests for the reorder binding remap expression (issue #8)

# Purpose: Runs the binding remap jq expression exactly as cmd_reorder does.
# Parameters: $1 — input JSON, $2 — account number map JSON
# Returns: Prints remapped JSON
remap() {
    echo "$1" | jq -c --argjson map "$2" '
        .bindings = (.bindings // {} | with_entries(
            .value = (.value as $v | if $map[$v | tostring] != null then ($map[$v | tostring] | tostring) else $v end)
        ))
    '
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
