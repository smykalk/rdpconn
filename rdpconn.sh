#!/usr/bin/env bash

# error handling
set -euo pipefail
# correct word splitting
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_FILE="$CONFIG_HOME/rdpconn.conf"
DEFAULT_CONFIG_FILE="$SCRIPT_DIR/rdpconn.conf"

log() {
    printf '%s\n' "$*"
}

log_err() {
    printf '%s\n' "$*" >&2
}

trim_ws() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

parse_server_entry() {
    local entry=$1
    local -n out_name=$2
    local -n out_url=$3
    local -n out_org_raw=$4
    local -n out_pers_raw=$5
    local extra
    local pipes=${entry//[^|]/}

    if ((${#pipes} != 3)); then
        log "Error: Invalid server entry '$entry'. Expected 'NAME|URL|UP_VPNS|DOWN_VPNS'."
        return 1
    fi

    IFS='|' read -r out_name out_url out_org_raw out_pers_raw extra <<< "$entry"
    out_name=$(trim_ws "$out_name")
    out_url=$(trim_ws "$out_url")

    if [[ -n ${extra:-} || -z $out_name || -z $out_url ]]; then
        log "Error: Invalid server entry '$entry'. Expected 'NAME|URL|UP_VPNS|DOWN_VPNS'."
        return 1
    fi

    return 0
}

split_list() {
    local raw=$1
    local -n out=$2
    local -a parts=()
    local part
    local trimmed

    out=()
    IFS=',' read -r -a parts <<< "$raw"
    for part in "${parts[@]}"; do
        trimmed=$(trim_ws "$part")
        if [[ -n $trimmed ]]; then
            out+=("$trimmed")
        fi
    done
}

resolve_vpn_list() {
    local raw=$1
    local default_var=$2
    local out_var=$3
    local -n out=$out_var
    local -n defaults=$default_var

    raw=$(trim_ws "$raw")

    if [[ $raw == "*" ]]; then
        out=("${defaults[@]}")
        return 0
    fi

    if [[ -z $raw || $raw == "-" ]]; then
        out=()
        return 0
    fi

    split_list "$raw" "$out_var"
}

config_var_exists() {
    declare -p "$1" >/dev/null 2>&1
}

load_user_config() {
    if [[ -f $CONFIG_FILE ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        log "Loaded config from '$CONFIG_FILE'"
        return 0
    fi

    if [[ -f $DEFAULT_CONFIG_FILE ]]; then
        # shellcheck disable=SC1090
        source "$DEFAULT_CONFIG_FILE"
        log "Loaded config from '$DEFAULT_CONFIG_FILE'"
        return 0
    fi

    log "Error: Configuration file not found. Looked for '$CONFIG_FILE' and '$DEFAULT_CONFIG_FILE'"
    return 1
}


validate_config() {
    local display_mode=$1
    local missing=()
    local clients_var

    clients_var=$(rdp_clients_var_for_display_mode "$display_mode")

    config_var_exists DOWN_VPNS || missing+=(DOWN_VPNS)
    config_var_exists UP_VPNS || missing+=(UP_VPNS)
    config_var_exists SERVERS || missing+=(SERVERS)
    config_var_exists KWALLET || missing+=(KWALLET)
    config_var_exists KWALLET_FOLDER || missing+=(KWALLET_FOLDER)
    config_var_exists RDP_ARGS_X11 || missing+=(RDP_ARGS_X11)
    config_var_exists RDP_ARGS_WAYLAND || missing+=(RDP_ARGS_WAYLAND)

    if ! declare -p "$clients_var" >/dev/null 2>&1; then
        if config_var_exists RDP_CLIENTS; then
            log "Error: RDP_CLIENTS is no longer supported. Define RDP_CLIENTS_X11 and RDP_CLIENTS_WAYLAND instead. '${clients_var}' is required for a '${display_mode}' session."
            return 1
        fi
        missing+=("$clients_var")
    fi

    if ((${#missing[@]} > 0)); then
        log "Error: Missing configuration variables: ${missing[*]}"
        return 1
    fi

    if ((${#SERVERS[@]} == 0)); then
        log "Error: SERVERS array is empty"
        return 1
    fi

    local entry
    local name
    local url
    local org_raw
    local pers_raw
    for entry in "${SERVERS[@]}"; do
        if ! parse_server_entry "$entry" name url org_raw pers_raw; then
            return 1
        fi
    done

    local -n rdp_clients="$clients_var"
    if ((${#rdp_clients[@]} == 0)); then
        log "Error: ${clients_var} array is empty"
        return 1
    fi

    return 0
}

ACTIVE_DOWN_VPNS=()
UP_VPNS_STARTED=()
SERVER_USERNAME=""
SERVER_PASSWORD=""

cleanup() {
    local exit_code=$1

    trap - EXIT INT TERM

    local vpn
    for vpn in "${UP_VPNS_STARTED[@]}"; do
        log "Disconnecting from org VPN '$vpn'"
        if ! nmcli connection down id "$vpn" >/dev/null; then
            log "Warning: Failed to disconnect org VPN '$vpn'"
        fi
    done

    for vpn in "${ACTIVE_DOWN_VPNS[@]}"; do
        log "Reconnecting to personal VPN '$vpn'"
        if ! nmcli connection up id "$vpn" >/dev/null; then
            log "Warning: Failed to reconnect personal VPN '$vpn'"
        fi
    done

    exit "$exit_code"
}

trap 'cleanup "$?"' EXIT
trap 'cleanup 130' INT TERM

select_server() {
    local -a labels=()
    local entry
    local name
    local url
    local org_raw
    local pers_raw
    for entry in "${SERVERS[@]}"; do
        if ! parse_server_entry "$entry" name url org_raw pers_raw; then
            return 1
        fi
        labels+=("${name} (${url})")
    done

    local choice
    PS3="Enter choice (1-${#labels[@]}): "
    select choice in "${labels[@]}"; do
        if [[ -n ${choice:-} ]]; then
            local index=$((REPLY - 1))
            log_err "Selected: '${labels[$index]}'"
            printf '%s' "${SERVERS[$index]}"
            return
        fi
        log_err "Invalid choice. Try again."
    done
}

detect_display_mode() {
    local session=${XDG_SESSION_TYPE:-}
    if [[ ${session,,} == "wayland" ]]; then
        printf '%s' "wayland"
    else
        printf '%s' "x11"
    fi
}

rdp_clients_var_for_display_mode() {
    local display_mode=$1

    if [[ $display_mode == "wayland" ]]; then
        printf '%s' "RDP_CLIENTS_WAYLAND"
    else
        printf '%s' "RDP_CLIENTS_X11"
    fi
}

select_rdp_client() {
    local display_mode=$1
    local clients_var
    clients_var=$(rdp_clients_var_for_display_mode "$display_mode")
    local -n rdp_clients="$clients_var"
    local client
    for client in "${rdp_clients[@]}"; do
        if command -v "$client" >/dev/null 2>&1; then
            printf '%s' "$client"
            return 0
        fi
    done

    log_err "Error: None of the configured RDP clients for '${display_mode}' are available from ${clients_var}: ${rdp_clients[*]}"
    return 1
}

is_connection_active() {
    local target=$1
    local active

    while IFS= read -r active; do
        if [[ $active == "$target" ]]; then
            return 0
        fi
    done < <(nmcli -t -f NAME connection show --active)

    return 1
}

disconnect_personal_vpns() {
    local -n vpns=$1
    local vpn

    for vpn in "${vpns[@]}"; do
        if is_connection_active "$vpn"; then
            ACTIVE_DOWN_VPNS+=("$vpn")
            log "Disconnecting from personal VPN '$vpn'"
            if ! nmcli connection down id "$vpn" >/dev/null; then
                log "Warning: Failed to disconnect personal VPN '$vpn'"
            fi
        fi
    done
}

ensure_org_vpns_connected() {
    local -n vpns=$1
    local vpn

    for vpn in "${vpns[@]}"; do
        if is_connection_active "$vpn"; then
            log "Org VPN '$vpn' is already active"
            continue
        fi

        log "Connecting to org VPN '$vpn'"
        nmcli connection up id "$vpn" >/dev/null
        UP_VPNS_STARTED+=("$vpn")
    done
}

read_kwallet_secret() {
    local key=$1
    local value=""
    if ! value=$(kwallet-query -r "$key" -f "$KWALLET_FOLDER" "$KWALLET" 2>/dev/null); then
        value=""
    fi
    printf '%s' "$value"
}

retrieve_credentials() {
    local name=$1
    local url=$2
    local secret=""

    secret=$(read_kwallet_secret "$url")
    if [[ -n $secret ]]; then
        if [[ $secret != *:* ]]; then
            log "Error: KWallet entry '$url' must be in 'username:password' format"
            return 1
        fi
        SERVER_USERNAME=${secret%%:*}
        SERVER_PASSWORD=${secret#*:}
    fi

    if [[ -z $SERVER_USERNAME || -z $SERVER_PASSWORD ]]; then
        log "Error: Failed to retrieve credentials from KWallet for server '$name' ('$url')"
        log "Ensure wallet '$KWALLET', folder '$KWALLET_FOLDER' contains:"
        log "  - ${url} (format: username:password)"
        return 1
    fi

    log "Credentials retrieved successfully"
}

build_rdp_args() {
    local client=$1
    local display_mode=$2
    local -n out=$3
    local sanitized=${client^^}
    sanitized=${sanitized//[^A-Z0-9]/_}
    local specific_var="RDP_ARGS_${sanitized}"

    local display_var
    if [[ $display_mode == "wayland" ]]; then
        display_var="RDP_ARGS_WAYLAND"
    else
        display_var="RDP_ARGS_X11"
    fi

    if declare -p "$specific_var" >/dev/null 2>&1; then
        local -n specific_args="$specific_var"
        out=("${specific_args[@]}")
        return
    fi

    if declare -p "$display_var" >/dev/null 2>&1; then
        local -n display_args="$display_var"
        out=("${display_args[@]}")
        return
    fi

    out=()
}

build_rdp_env() {
    local client=$1
    local -n out=$2
    local sanitized=${client^^}
    sanitized=${sanitized//[^A-Z0-9]/_}
    local env_var="RDP_ENV_${sanitized}"

    if declare -p "$env_var" >/dev/null 2>&1; then
        local -n env_ref="$env_var"
        out=("${env_ref[@]}")
        return
    fi

    out=()
}

is_freerdp_client() {
    local name=${1##*/}

    [[ $name =~ freerdp([0-9]+)?$ ]]
}

build_freerdp_args_payload() {
    local -n in=$1
    local -n out=$2
    local arg

    for arg in "${in[@]}"; do
        if [[ $arg == *$'\n'* ]]; then
            log "Error: RDP argument contains a newline and cannot be passed securely: '$arg'"
            return 1
        fi
    done

    printf -v out '%s\n' "${in[@]}"
}

launch_freerdp_session() {
    local client=$1
    local -n args_ref=$2
    local -n env_ref=$3
    local payload=""
    local args_fd
    local status

    if ! is_freerdp_client "$client"; then
        log "Error: Unsupported RDP client '$client'. Secure password transport is only implemented for FreeRDP frontends."
        return 1
    fi

    if ! build_freerdp_args_payload args_ref payload; then
        return 1
    fi

    exec {args_fd}<<<"$payload"

    if ((${#env_ref[@]} > 0)); then
        if env "${env_ref[@]}" "$client" "/args-from:fd:${args_fd}"; then
            status=0
        else
            status=$?
        fi
    else
        if "$client" "/args-from:fd:${args_fd}"; then
            status=0
        else
            status=$?
        fi
    fi

    exec {args_fd}<&-
    return "$status"
}

start_rdp_session() {
    local client=$1
    local display_mode=$2
    local server=$3
    local username=$4
    local password=$5

    local -a args=()
    build_rdp_args "$client" "$display_mode" args

    args+=(
        "/v:${server}"
        "/u:${username}"
        "/p:${password}"
        "/d:"
    )

    local share="${RDP_SHARE:-}"
    if [[ -n $share ]]; then
        mkdir -p "$share"
        args+=("/drive:rdp-share,${share}")
    fi

    local -a env_vars=()
    build_rdp_env "$client" env_vars

    launch_freerdp_session "$client" args env_vars
}

main() {
    if ! load_user_config; then
        exit 1
    fi

    local display_mode
    display_mode=$(detect_display_mode)

    if ! validate_config "$display_mode"; then
        exit 1
    fi

    local server_entry
    local server_name
    local server_url
    local org_raw
    local pers_raw
    if ((${#SERVERS[@]} == 1)); then
        server_entry=${SERVERS[0]}
        if ! parse_server_entry "$server_entry" server_name server_url org_raw pers_raw; then
            exit 1
        fi
        log "Auto-selecting: '${server_name} (${server_url})'"
    else
        if ! server_entry=$(select_server); then
            exit 1
        fi
        if ! parse_server_entry "$server_entry" server_name server_url org_raw pers_raw; then
            exit 1
        fi
    fi

    local -a selected_org_vpns=()
    local -a selected_pers_vpns=()
    resolve_vpn_list "$org_raw" UP_VPNS selected_org_vpns
    resolve_vpn_list "$pers_raw" DOWN_VPNS selected_pers_vpns

    disconnect_personal_vpns selected_pers_vpns
    ensure_org_vpns_connected selected_org_vpns

    if ! retrieve_credentials "$server_name" "$server_url"; then
        exit 1
    fi

    local rdp_client
    if ! rdp_client=$(select_rdp_client "$display_mode"); then
        exit 1
    fi

    log "Using RDP client '$rdp_client' on display mode '$display_mode'"

    start_rdp_session "$rdp_client" "$display_mode" "$server_url" "$SERVER_USERNAME" "$SERVER_PASSWORD"
}

main "$@"
