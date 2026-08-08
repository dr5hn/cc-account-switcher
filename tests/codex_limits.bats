#!/usr/bin/env bats
# Tests for the read-only Codex usage bridge

setup() {
    # Set HOME before sourcing so readonly globals (CODEX_DIR etc.) use TEST_HOME
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    unset CLAUDE_CONFIG_DIR
    source "${BATS_TEST_DIRNAME}/../ccm.sh"
    ROLLOUT_DIR="$TEST_HOME/.codex/sessions/2026/08/08"
}

teardown() {
    rm -rf "$TEST_HOME"
}

# Purpose: Writes a realistic Codex rollout JSONL fixture
# Parameters: $1 — destination file path
# Returns: Nothing
# Usage: write_rollout "$ROLLOUT_DIR/rollout-a.jsonl"
write_rollout() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'JSONL'
{"type":"turn_context","payload":{"model":"gpt-5.6-sol","cwd":"/tmp/x"}}
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":42.5,"window_minutes":10080,"resets_at":1786603510},"secondary":null,"credits":{"has_credits":true,"unlimited":false,"balance":"390.47"},"plan_type":"plus"},"info":{"total_token_usage":{"total_tokens":1000},"last_token_usage":{"total_tokens":500},"model_context_window":258400}}}
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":77.0,"window_minutes":10080,"resets_at":1786603999},"secondary":null,"credits":{"has_credits":true,"unlimited":false,"balance":"380.00"},"plan_type":"plus"},"info":{"total_token_usage":{"total_tokens":5678},"last_token_usage":{"total_tokens":1234},"model_context_window":258400}}}
JSONL
}

# ── degradation ────────────────────────────────────────────────────────────

@test "codex_read_limits fails cleanly when ~/.codex is absent" {
    run codex_read_limits
    [ "$status" -ne 0 ]
}

@test "codex_latest_rollout fails cleanly when there are no rollout files" {
    mkdir -p "$TEST_HOME/.codex/sessions"
    run codex_latest_rollout
    [ "$status" -ne 0 ]
}

@test "codex_read_limits fails cleanly on a rollout with no rate_limits" {
    mkdir -p "$ROLLOUT_DIR"
    printf '{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}\n' \
        > "$ROLLOUT_DIR/rollout-empty.jsonl"
    run codex_read_limits
    [ "$status" -ne 0 ]
}

@test "codex_status reports absence without crashing" {
    run codex_status
    [ "$status" -ne 0 ]
    [[ "$output" == *"not detected"* ]]
}

# ── reading ────────────────────────────────────────────────────────────────

@test "reads the most recent rate_limits record, not the first" {
    write_rollout "$ROLLOUT_DIR/rollout-a.jsonl"
    run codex_read_limits
    [ "$status" -eq 0 ]
    # jq 1.7 preserves the literal, so 77.0 stays "77.0" — compare numerically
    [ "$(echo "$output" | jq -r '.primary.used_percentage == 77.0')" = "true" ]
    [ "$(echo "$output" | jq -r '.primary.resets_at')" = "1786603999" ]
}

@test "reports plan type and credit balance" {
    write_rollout "$ROLLOUT_DIR/rollout-a.jsonl"
    run codex_read_limits
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.plan_type')" = "plus" ]
    [ "$(echo "$output" | jq -r '.credits.balance')" = "380.00" ]
}

@test "distinguishes cumulative session tokens from context occupancy" {
    write_rollout "$ROLLOUT_DIR/rollout-a.jsonl"
    run codex_read_limits
    [ "$status" -eq 0 ]
    # session_total is cumulative; context_used is the last turn only
    [ "$(echo "$output" | jq -r '.tokens.session_total')" = "5678" ]
    [ "$(echo "$output" | jq -r '.tokens.context_used')" = "1234" ]
    [ "$(echo "$output" | jq -r '.tokens.context_window')" = "258400" ]
}

@test "reports the model from turn_context" {
    write_rollout "$ROLLOUT_DIR/rollout-a.jsonl"
    run codex_read_limits
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.model')" = "gpt-5.6-sol" ]
}

@test "emits valid JSON" {
    write_rollout "$ROLLOUT_DIR/rollout-a.jsonl"
    run codex_read_limits
    [ "$status" -eq 0 ]
    echo "$output" | jq empty
}

@test "picks the newest rollout when several exist" {
    write_rollout "$ROLLOUT_DIR/rollout-old.jsonl"
    sed 's/"used_percent":77.0/"used_percent":12.5/' "$ROLLOUT_DIR/rollout-old.jsonl" \
        > "$ROLLOUT_DIR/rollout-new.jsonl"
    touch -t 202601010000 "$ROLLOUT_DIR/rollout-old.jsonl"
    run codex_read_limits
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.primary.used_percentage == 12.5')" = "true" ]
}

@test "tolerates a rollout missing last_token_usage" {
    mkdir -p "$ROLLOUT_DIR"
    cat > "$ROLLOUT_DIR/rollout-partial.jsonl" <<'JSONL'
{"type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":5,"window_minutes":300,"resets_at":100},"plan_type":"pro"},"info":{"total_token_usage":{"total_tokens":42},"model_context_window":1000}}}
JSONL
    run codex_read_limits
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.tokens.context_used')" = "0" ]
    [ "$(echo "$output" | jq -r '.tokens.session_total')" = "42" ]
}

# ── command surface ────────────────────────────────────────────────────────

@test "codex_status writes codex-limits.json" {
    mkdir -p "$BACKUP_DIR"
    write_rollout "$ROLLOUT_DIR/rollout-a.jsonl"
    run codex_status
    [ "$status" -eq 0 ]
    [ -f "$CODEX_LIMITS_FILE" ]
    run jq empty "$CODEX_LIMITS_FILE"
    [ "$status" -eq 0 ]
}

@test "cmd_codex rejects an unknown subcommand" {
    run cmd_codex bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown codex subcommand"* ]]
}

@test "format_epoch handles bad input without crashing" {
    run format_epoch "not-a-number"
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
    run format_epoch 0
    [ "$output" = "unknown" ]
}

# ── the module must never write to ~/.codex ────────────────────────────────

@test "reading Codex data leaves ~/.codex byte-identical" {
    write_rollout "$ROLLOUT_DIR/rollout-a.jsonl"
    mkdir -p "$BACKUP_DIR"
    local before after
    before=$(find "$TEST_HOME/.codex" -type f -exec shasum {} + | shasum)
    codex_status >/dev/null 2>&1
    after=$(find "$TEST_HOME/.codex" -type f -exec shasum {} + | shasum)
    [ "$before" = "$after" ]
}
