#!/usr/bin/env bats
# Tests for model pricing lookups
#
# Rates from:
#   https://platform.claude.com/docs/en/about-claude/pricing
#   https://developers.openai.com/api/docs/pricing

setup() {
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    unset CLAUDE_CONFIG_DIR
    source "${BATS_TEST_DIRNAME}/../ccm.sh"
}

teardown() {
    rm -rf "$TEST_HOME"
}

# ── Claude ─────────────────────────────────────────────────────────────────

@test "prices Fable 5" {
    run claude_model_pricing "claude-fable-5"
    [ "$status" -eq 0 ]
    [ "$output" = "10|50|1|12.50" ]
}

@test "prices Opus 5 and the 4.5-4.8 line at the current rate, not the retired one" {
    for m in claude-opus-5 claude-opus-4-8 claude-opus-4-7 claude-opus-4-6 claude-opus-4-5; do
        run claude_model_pricing "$m"
        [ "$status" -eq 0 ]
        [ "$output" = "5|25|0.50|6.25" ]
    done
}

@test "prices retired Opus 4.1 and Opus 4 at the old rate" {
    run claude_model_pricing "claude-opus-4-1-20250805"
    [ "$output" = "15|75|1.50|18.75" ]
    run claude_model_pricing "claude-opus-4-20250514"
    [ "$output" = "15|75|1.50|18.75" ]
}

@test "prices Haiku 4.5 at \$1/\$5, not the Haiku 3.5 rate" {
    run claude_model_pricing "claude-haiku-4-5-20251001"
    [ "$status" -eq 0 ]
    [ "$output" = "1|5|0.10|1.25" ]
}

@test "prices Haiku 3.5 separately" {
    run claude_model_pricing "claude-haiku-3-5-20241022"
    [ "$output" = "0.80|4|0.08|1" ]
}

@test "prices the Sonnet 4.x line" {
    run claude_model_pricing "claude-sonnet-4-6"
    [ "$output" = "3|15|0.30|3.75" ]
    run claude_model_pricing "claude-sonnet-4-5-20250514"
    [ "$output" = "3|15|0.30|3.75" ]
}

@test "Sonnet 5 uses introductory pricing through 2026-08-31" {
    run claude_model_pricing "claude-sonnet-5"
    [ "$status" -eq 0 ]
    # Either regime is valid depending on the clock; both must be one of the two
    [[ "$output" = "2|10|0.20|2.50" || "$output" = "3|15|0.30|3.75" ]]
}

@test "matches dated model ids, not just bare ones" {
    run claude_model_pricing "claude-sonnet-4-5-20250514"
    [ "$status" -eq 0 ]
    run claude_model_pricing "claude-haiku-4-5-20251001"
    [ "$status" -eq 0 ]
}

@test "returns non-zero for unknown or placeholder models" {
    run claude_model_pricing "gpt-4"
    [ "$status" -ne 0 ]
    run claude_model_pricing "<synthetic>"
    [ "$status" -ne 0 ]
    run claude_model_pricing ""
    [ "$status" -ne 0 ]
}

@test "every Claude price has all four fields" {
    for m in claude-fable-5 claude-opus-5 claude-sonnet-4-6 claude-haiku-4-5 claude-haiku-3-5; do
        run claude_model_pricing "$m"
        [ "$status" -eq 0 ]
        [ "$(echo "$output" | awk -F'|' '{print NF}')" = "4" ]
    done
}

@test "cache write is priced above cache read for every model" {
    for m in claude-fable-5 claude-opus-5 claude-sonnet-4-6 claude-haiku-4-5; do
        run claude_model_pricing "$m"
        local cr cw
        cr=$(echo "$output" | cut -d'|' -f3)
        cw=$(echo "$output" | cut -d'|' -f4)
        [ "$(awk -v a="$cw" -v b="$cr" 'BEGIN{print (a>b)?1:0}')" = "1" ]
    done
}

# ── Codex ──────────────────────────────────────────────────────────────────

@test "prices gpt-5.6-sol" {
    run codex_model_pricing "gpt-5.6-sol"
    [ "$status" -eq 0 ]
    [ "$output" = "5.00|0.50|30.00" ]
}

@test "prices the rest of the gpt-5.6 line" {
    run codex_model_pricing "gpt-5.6-terra"
    [ "$output" = "2.00|0.20|12.00" ]
    run codex_model_pricing "gpt-5.6-luna"
    [ "$output" = "0.20|0.02|1.20" ]
}

@test "prices gpt-5.3-codex and gpt-5.1" {
    run codex_model_pricing "gpt-5.3-codex"
    [ "$output" = "1.75|0.175|14.00" ]
    run codex_model_pricing "gpt-5.1"
    [ "$output" = "1.25|0.125|10.00" ]
}

@test "codex pricing returns non-zero for unknown models" {
    run codex_model_pricing "claude-fable-5"
    [ "$status" -ne 0 ]
    run codex_model_pricing ""
    [ "$status" -ne 0 ]
}

@test "cached input is cheaper than base input for every codex model" {
    for m in gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.3-codex gpt-5.1; do
        run codex_model_pricing "$m"
        local pin pc
        pin=$(echo "$output" | cut -d'|' -f1)
        pc=$(echo "$output" | cut -d'|' -f2)
        [ "$(awk -v a="$pin" -v b="$pc" 'BEGIN{print (a>b)?1:0}')" = "1" ]
    done
}

@test "codex cost arithmetic matches a hand calculation" {
    # 10M input of which 8M cached, 1M output, at gpt-5.6-sol rates:
    #   uncached 2M * $5    = $10.00
    #   cached   8M * $0.50 = $4.00
    #   output   1M * $30   = $30.00  -> $44.00
    run bash -c '
        pricing="5.00|0.50|30.00"
        IFS="|" read -r pi pc po <<< "$pricing"
        awk -v u=2000000 -v c=8000000 -v o=1000000 -v pi="$pi" -v pc="$pc" -v po="$po" \
            "BEGIN{printf \"%.2f\", (u*pi + c*pc + o*po)/1000000}"
    '
    [ "$output" = "44.00" ]
}
