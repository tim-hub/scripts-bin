#!/usr/bin/env zsh

# Multi-Account Switcher for Claude Code
# Simple tool to manage and switch between multiple Claude Code accounts
# Accounts are identified by their OAuth accountUuid

set -euo pipefail

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly STATE_FILE="$BACKUP_DIR/state.json"

# Get Claude configuration file path with fallback
get_claude_config_path() {
    local primary_config="$HOME/.claude/.claude.json"
    local fallback_config="$HOME/.claude.json"

    if [[ -f "$primary_config" ]]; then
        if jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
            echo "$primary_config"
            return
        fi
    fi

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

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX")

    printf '%s\n' "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi

    mv "$temp_file" "$file"
    chmod 600 "$file"
}

# Check zsh version (5.9+ required)
check_zsh_version() {
    local major="${ZSH_VERSION%%.*}"
    local minor="${${ZSH_VERSION#*.}%%.*}"
    if (( major < 5 || (major == 5 && minor < 9) )); then
        echo "Error: zsh 5.9+ required (found ${ZSH_VERSION})"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    for cmd in jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            echo "Install with: brew install $cmd"
            exit 1
        fi
    done
}

# Setup backup directories
setup_directories() {
    mkdir -p "$BACKUP_DIR/configs"
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR/configs"
}

# Claude Code process detection
is_claude_running() {
    ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" { found=1; exit } END { exit !found }'
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

# Get current account uuid from .claude.json
get_current_uuid() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo ""
        return
    fi

    if ! validate_json "$(get_claude_config_path)"; then
        echo ""
        return
    fi

    local uuid
    uuid=$(jq -r '.oauthAccount.accountUuid // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${uuid:-}"
}

# Get current account email from .claude.json
get_current_email() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo ""
        return
    fi

    local email
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${email:-}"
}

# Read credentials from Keychain
read_credentials() {
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo ""
}

# Write credentials to Keychain
write_credentials() {
    local credentials="$1"
    security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null
}

# Read account credentials from Keychain (keyed by uuid)
read_account_credentials() {
    local uuid="$1"
    security find-generic-password -s "Claude Code-Account-${uuid}" -w 2>/dev/null || echo ""
}

# Write account credentials to Keychain (keyed by uuid)
write_account_credentials() {
    local uuid="$1"
    local credentials="$2"
    security add-generic-password -U -s "Claude Code-Account-${uuid}" -a "$USER" -w "$credentials" 2>/dev/null
}

# Read account config from backup (keyed by uuid)
read_account_config() {
    local uuid="$1"
    local config_file="$BACKUP_DIR/configs/.claude-config-${uuid}.json"

    if [[ -f "$config_file" ]]; then
        cat "$config_file"
    else
        echo ""
    fi
}

# Write account config to backup (keyed by uuid)
write_account_config() {
    local uuid="$1"
    local config="$2"
    local config_file="$BACKUP_DIR/configs/.claude-config-${uuid}.json"

    printf '%s\n' "$config" > "$config_file"
    chmod 600 "$config_file"
}

# Initialize state.json if it doesn't exist
init_state_file() {
    if [[ ! -f "$STATE_FILE" ]]; then
        local init_content='{
  "activeAccount": null,
  "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "sequence": [],
  "accounts": {}
}'
        write_json "$STATE_FILE" "$init_content"
    fi
}

# Resolve uuid or uuid prefix to full uuid
resolve_uuid() {
    local identifier="$1"

    # Exact uuid match
    if jq -e --arg id "$identifier" '.accounts[$id]' "$STATE_FILE" >/dev/null 2>&1; then
        echo "$identifier"
        return
    fi

    # Partial uuid prefix match
    local matches
    matches=$(jq -r --arg prefix "$identifier" '[.accounts | keys[] | select(startswith($prefix))] | .[]' "$STATE_FILE" 2>/dev/null)
    local match_count
    match_count=$(printf '%s\n' "$matches" | grep -c . 2>/dev/null || echo "0")

    if [[ "$match_count" -eq 1 ]]; then
        echo "$matches"
        return
    elif [[ "$match_count" -gt 1 ]]; then
        echo "Error: Ambiguous prefix '$identifier' matches $match_count accounts:" >&2
        printf '%s\n' "$matches" | while read -r m; do
            local email
            email=$(jq -r --arg id "$m" '.accounts[$id].email' "$STATE_FILE")
            echo "  ${m:0:8}… ($email)" >&2
        done
        echo ""
        return
    fi

    echo ""
}

# Check if account exists by uuid
account_exists_by_uuid() {
    local uuid="$1"
    if [[ ! -f "$STATE_FILE" ]]; then
        return 1
    fi

    jq -e --arg id "$uuid" '.accounts[$id]' "$STATE_FILE" >/dev/null 2>&1
}

# Add account
cmd_add_account() {
    setup_directories
    init_state_file

    local current_uuid
    current_uuid=$(get_current_uuid)

    if [[ -z "$current_uuid" ]]; then
        echo "Error: No active Claude account found. Please log in first."
        exit 1
    fi

    if account_exists_by_uuid "$current_uuid"; then
        local existing_email
        existing_email=$(jq -r --arg id "$current_uuid" '.accounts[$id].email' "$STATE_FILE")
        echo "Account ${current_uuid:0:8}… ($existing_email) is already managed."
        exit 0
    fi

    local current_email current_creds current_config
    current_email=$(get_current_email)
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi

    write_account_credentials "$current_uuid" "$current_creds"
    write_account_config "$current_uuid" "$current_config"

    local updated_state
    updated_state=$(jq --arg uuid "$current_uuid" --arg email "$current_email" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$uuid] = {
            email: $email,
            added: $now
        } |
        .sequence += [$uuid] |
        .activeAccount = $uuid |
        .lastUpdated = $now
    ' "$STATE_FILE")

    write_json "$STATE_FILE" "$updated_state"

    echo "Added ${current_uuid:0:8}… ($current_email)"
}

# Remove account
cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --remove-account <uuid>"
        exit 1
    fi

    local identifier="$1"

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local target_uuid
    target_uuid=$(resolve_uuid "$identifier")
    if [[ -z "$target_uuid" ]]; then
        echo "Error: No account found for: $identifier"
        exit 1
    fi

    local email
    email=$(jq -r --arg id "$target_uuid" '.accounts[$id].email' "$STATE_FILE")

    local active_account
    active_account=$(jq -r '.activeAccount' "$STATE_FILE")

    if [[ "$active_account" == "$target_uuid" ]]; then
        echo "Warning: ${target_uuid:0:8}… ($email) is currently active"
    fi

    echo -n "Are you sure you want to permanently remove ${target_uuid:0:8}… ($email)? [y/N] "
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled"
        exit 0
    fi

    security delete-generic-password -s "Claude Code-Account-${target_uuid}" 2>/dev/null || true
    rm -f "$BACKUP_DIR/configs/.claude-config-${target_uuid}.json"

    local updated_state
    updated_state=$(jq --arg id "$target_uuid" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$id]) |
        .sequence = (.sequence | map(select(. != $id))) |
        (if .activeAccount == $id then .activeAccount = null else . end) |
        .lastUpdated = $now
    ' "$STATE_FILE")

    write_json "$STATE_FILE" "$updated_state"

    echo "${target_uuid:0:8}… ($email) has been removed"
}

# First-run setup workflow
first_run_setup() {
    local current_uuid
    current_uuid=$(get_current_uuid)

    if [[ -z "$current_uuid" ]]; then
        echo "No active Claude account found. Please log in first."
        return 1
    fi

    local current_email
    current_email=$(get_current_email)

    echo -n "No managed accounts found. Add current account ($current_email)? [Y/n] "
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
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "No accounts are managed yet."
        first_run_setup
        exit 0
    fi

    local current_uuid
    current_uuid=$(get_current_uuid)

    echo "Accounts:"
    jq -r --arg active "$current_uuid" '
        .sequence[] as $uuid |
        .accounts[$uuid] |
        "\($uuid[:8])… \(.email)" + (if $uuid == $active then " (active)" else "" end) |
        "  " + .
    ' "$STATE_FILE"
}

# Show current active account
cmd_current() {
    local uuid email
    uuid=$(get_current_uuid)
    email=$(get_current_email)

    if [[ -z "$uuid" ]]; then
        echo "No active Claude account found."
        exit 1
    fi

    echo "${uuid:0:8}… ($email)"
}

# Switch to next account
cmd_switch() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local current_uuid
    current_uuid=$(get_current_uuid)

    if [[ -z "$current_uuid" ]]; then
        echo "Error: No active Claude account found"
        exit 1
    fi

    if ! account_exists_by_uuid "$current_uuid"; then
        echo "Notice: Active account '${current_uuid:0:8}…' was not managed."
        cmd_add_account
        echo "It has been automatically added."
        echo "Please run './ccswitch.sh --switch' again to switch to the next account."
        exit 0
    fi

    # wait_for_claude_close

    local -a sequence
    sequence=("${(@f)$(jq -r '.sequence[]' "$STATE_FILE")}")

    # Find current index (1-based) and compute next (zsh arrays are 1-indexed)
    local current_index=1
    for (( i=1; i<=${#sequence}; i++ )); do
        if [[ "${sequence[$i]}" == "$current_uuid" ]]; then
            current_index=$i
            break
        fi
    done

    local next_uuid
    next_uuid="${sequence[$(( current_index % ${#sequence} + 1 ))]}"

    perform_switch "$next_uuid"
}

# Switch to specific account
cmd_switch_to() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --switch-to <uuid>"
        exit 1
    fi

    local identifier="$1"

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local target_uuid
    target_uuid=$(resolve_uuid "$identifier")
    if [[ -z "$target_uuid" ]]; then
        echo "Error: No account found for: $identifier"
        exit 1
    fi

    # wait_for_claude_close
    perform_switch "$target_uuid"
}

# Perform the actual account switch
perform_switch() {
    local target_uuid="$1"

    local current_uuid target_email current_email
    current_uuid=$(get_current_uuid)
    target_email=$(jq -r --arg id "$target_uuid" '.accounts[$id].email' "$STATE_FILE")
    current_email=$(get_current_email)

    # Step 1: Backup current account
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    write_account_credentials "$current_uuid" "$current_creds"
    write_account_config "$current_uuid" "$current_config"

    # Step 2: Retrieve target account
    local target_creds target_config
    target_creds=$(read_account_credentials "$target_uuid")
    target_config=$(read_account_config "$target_uuid")

    if [[ -z "$target_creds" || -z "$target_config" ]]; then
        echo "Error: Missing backup data for ${target_uuid:0:8}…"
        exit 1
    fi

    # Step 3: Activate target account
    write_credentials "$target_creds"

    local oauth_section
    oauth_section=$(printf '%s' "$target_config" | jq '.oauthAccount' 2>/dev/null)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        echo "Error: Invalid oauthAccount in backup"
        exit 1
    fi

    local merged_config
    merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to merge config"
        exit 1
    fi

    write_json "$(get_claude_config_path)" "$merged_config"

    # Step 4: Update state
    local updated_state
    updated_state=$(jq --arg id "$target_uuid" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .activeAccount = $id |
        .lastUpdated = $now
    ' "$STATE_FILE")

    write_json "$STATE_FILE" "$updated_state"

    echo "Switched to ${target_uuid:0:8}… ($target_email)"
    cmd_list
    echo ""
    echo "Please restart Claude Code to use the new authentication."
    echo ""
}

# Show usage
show_usage() {
    echo "Multi-Account Switcher for Claude Code"
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  -c, --current                Show current active account"
    echo "  -a, --add-account            Add current account to managed accounts"
    echo "  -r, --remove-account <uuid>  Remove account by uuid (or prefix)"
    echo "  -l, --list                   List all managed accounts"
    echo "  -s, --switch                 Rotate to next account in sequence"
    echo "  -t, --switch-to <uuid>       Switch to account by uuid (or prefix)"
    echo "  -h, --help                   Show this help message"
    echo ""
    echo "Accounts are identified by their OAuth accountUuid."
    echo "You can use a uuid prefix (e.g., 'a1b2c3d4') instead of the full uuid."
}

# Main script logic
main() {
    if [[ $EUID -eq 0 ]]; then
        echo "Error: Do not run this script as root"
        exit 1
    fi

    check_zsh_version
    check_dependencies

    case "${1:-}" in
        -c|--current)
            cmd_current
            ;;
        -a|--add-account)
            cmd_add_account
            ;;
        -r|--remove-account)
            shift
            cmd_remove_account "$@"
            ;;
        -l|--list)
            cmd_list
            ;;
        -s|--switch)
            cmd_switch
            ;;
        -t|--switch-to)
            shift
            cmd_switch_to "$@"
            ;;
        -h|--help)
            show_usage
            ;;
        "")
            cmd_switch
            ;;
        *)
            echo "Error: Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
