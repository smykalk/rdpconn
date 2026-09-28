#!/usr/bin/env bash

# error handling
set -euo pipefail
# correct word splitting
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_FILE="$CONFIG_HOME/rdpconn.conf"
DEFAULT_CONFIG_FILE="$SCRIPT_DIR/rdpconn.conf"

RDPCONN_VERSION="1.0.0"

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
RDP_FAILURE_DETAIL=""

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
    log_err "Enter 'e' to edit servers."
    PS3="Enter choice (1-${#labels[@]}) or e to edit: "
    select choice in "${labels[@]}"; do
        if [[ ${REPLY,,} == "e" ]]; then
            printf '%s' "__EDIT__"
            return
        fi
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

collect_available_rdp_clients() {
    local display_mode=$1
    local out_var=$2
    local -n available_out=$out_var
    local clients_var
    clients_var=$(rdp_clients_var_for_display_mode "$display_mode")
    local -n configured_clients="$clients_var"
    local client
    local -a available_clients=()

    for client in "${configured_clients[@]}"; do
        if command -v "$client" >/dev/null 2>&1; then
            available_clients+=("$client")
        fi
    done

    available_out=("${available_clients[@]}")
    if ((${#available_out[@]} == 0)); then
        log_err "Error: None of the configured RDP clients for '${display_mode}' are available from ${clients_var}: ${configured_clients[*]}"
        return 1
    fi
}

is_connection_active() {
    local target=$1
    local active

    while IFS= read -r active; do
        if [[ $active == "$target" ]]; then
            return 0
        fi
    done < <(nmcli -t -e no -f NAME connection show --active)

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

describe_monitor() {
    local index=$1
    local name=${MONITOR_NAMES[$index]:-}

    printf '[%s] %s %s %s' "${MONITOR_IDS[$index]}" "${name:-unnamed}" "${MONITOR_SIZES[$index]}" "${MONITOR_POSITIONS[$index]}"
}

log_available_monitors() {
    local i

    log_err "Available monitors:"
    for i in "${!MONITOR_IDS[@]}"; do
        log_err "  $(describe_monitor "$i")"
    done
}

load_monitor_list() {
    local client=$1
    local -n env_ref=$2
    local output
    local line
    local status=0
    local position
    local -a unparsed=()

    # Some clients (sdl-freerdp3) print the monitor list and then exit nonzero,
    # so parse the output instead of relying on the exit status.
    output=$(env "${env_ref[@]}" "$client" /list:monitor 2>/dev/null) || status=$?

    MONITOR_IDS=()
    MONITOR_NAMES=()
    MONITOR_SIZES=()
    MONITOR_POSITIONS=()
    MONITOR_NAMES_PRESENT=0

    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*\*?[[:space:]]*\[([0-9]+)\][[:space:]]*(\[([^]]*)\])?[[:space:]]*([0-9]+x[0-9]+)[[:space:]]*\+(-?[0-9]+)\+(-?[0-9]+) ]]; then
            printf -v position '%+d%+d' "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
            MONITOR_IDS+=("${BASH_REMATCH[1]}")
            MONITOR_NAMES+=("${BASH_REMATCH[3]}")
            MONITOR_SIZES+=("${BASH_REMATCH[4]}")
            MONITOR_POSITIONS+=("$position")
            if [[ -n ${BASH_REMATCH[3]} ]]; then
                MONITOR_NAMES_PRESENT=1
            fi
        elif [[ $line == *'['* ]]; then
            unparsed+=("$line")
        fi
    done <<< "$output"

    if ((${#unparsed[@]} > 0)); then
        log_err "Warning: Ignored unrecognized monitor list line(s):"
        for line in "${unparsed[@]}"; do
            log_err "  $line"
        done
    fi

    if ((${#MONITOR_IDS[@]} == 0)); then
        log_err "Error: Could not parse monitor list from '$client /list:monitor' (exit status $status)"
        RDP_FAILURE_DETAIL="could not provide a monitor list"
        return 1
    fi
}

valid_monitor_token() {
    local token=$1

    if [[ $token == name:* ]]; then
        [[ -n $(trim_ws "${token#name:}") ]]
        return
    fi

    [[ $token =~ ^[+-][0-9]+[+-][0-9]+$ ]]
}

# Expects a token already accepted by valid_monitor_token.
resolve_monitor_token() {
    local token=$1
    local -n out_index=$2
    local matches=()
    local i

    if [[ $token == name:* ]]; then
        local needle
        local needle_lower
        local name_lower

        needle=$(trim_ws "${token#name:}")
        if ((MONITOR_NAMES_PRESENT == 0)); then
            log_err "Error: The selected RDP client does not report monitor names; use a signed position like '+1080+360' instead of '$token'"
            return 1
        fi
        needle_lower=${needle,,}
        for i in "${!MONITOR_IDS[@]}"; do
            name_lower=${MONITOR_NAMES[i],,}
            if [[ -n $name_lower && $name_lower == *"$needle_lower"* ]]; then
                matches+=("$i")
            fi
        done
    elif [[ $token =~ ^([+-][0-9]+)([+-][0-9]+)$ ]]; then
        local position

        printf -v position '%+d%+d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        for i in "${!MONITOR_IDS[@]}"; do
            if [[ ${MONITOR_POSITIONS[i]} == "$position" ]]; then
                matches+=("$i")
            fi
        done
    fi

    if ((${#matches[@]} == 0)); then
        log_err "Error: /monitors token '$token' did not match any monitor"
        log_available_monitors
        return 1
    fi

    if ((${#matches[@]} > 1)); then
        log_err "Error: /monitors token '$token' is ambiguous and matched multiple monitors:"
        for i in "${matches[@]}"; do
            log_err "  $(describe_monitor "$i")"
        done
        log_err "Use an exact signed position (e.g. '-1920+0') instead."
        return 1
    fi

    out_index=${matches[0]}
}

resolve_monitor_args() {
    local client=$1
    local -n args_ref=$2
    local env_var_name=$3
    local monitors_index=-1
    local i

    for i in "${!args_ref[@]}"; do
        if [[ ${args_ref[i]} == /monitors:* ]]; then
            if ((monitors_index >= 0)); then
                log_err "Error: Multiple /monitors arguments are not supported"
                return 1
            fi
            monitors_index=$i
        fi
    done

    if ((monitors_index < 0)); then
        return 0
    fi

    if ! is_freerdp_client "$client"; then
        log_err "Error: Dynamic /monitors resolution requires a FreeRDP client, got '$client'"
        return 1
    fi

    local value=${args_ref[monitors_index]#/monitors:}
    local -a tokens=()
    local token

    split_list "$value" tokens
    if ((${#tokens[@]} == 0)); then
        log_err "Error: /monitors argument must contain at least one 'name:<substring>' or signed position token"
        return 1
    fi

    for token in "${tokens[@]}"; do
        if ! valid_monitor_token "$token"; then
            log_err "Error: Invalid /monitors token '$token'. Use 'name:<substring>' or a signed position like '+1080+360' or '-1920+0'."
            return 1
        fi
    done

    if ! load_monitor_list "$client" "$env_var_name"; then
        return 1
    fi

    local -a resolved=()
    local monitor_index
    local id
    local existing

    for token in "${tokens[@]}"; do
        if ! resolve_monitor_token "$token" monitor_index; then
            return 1
        fi
        id=${MONITOR_IDS[monitor_index]}
        for existing in "${resolved[@]}"; do
            if [[ $existing == "$id" ]]; then
                log_err "Error: /monitors token '$token' selects monitor '$id' more than once"
                return 1
            fi
        done
        resolved+=("$id")
    done

    local joined
    local resolved_ids

    printf -v joined '%s,' "${resolved[@]}"
    resolved_ids=${joined%,}
    args_ref[monitors_index]="/monitors:${resolved_ids}"

    log "Resolved '/monitors:${value}' to '/monitors:${resolved_ids}'"
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
    if ((status != 0)); then
        RDP_FAILURE_DETAIL="exited with status ${status}"
    fi
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

    if ! resolve_monitor_args "$client" args env_vars; then
        return 1
    fi

    launch_freerdp_session "$client" args env_vars
}

confirm_client_fallback() {
    local failed_client=$1
    local failure_detail=$2
    local next_client=$3
    local answer

    log_err "RDP client '${failed_client}' ${failure_detail}."
    log_err "Try next client '${next_client}'? [y/N]: "
    if ! read -r answer; then
        return 1
    fi

    [[ ${answer,,} == "y" ]]
}

launch_with_fallback() {
    local display_mode=$1
    local server=$2
    local username=$3
    local password=$4
    local clients_var=$5
    local -n clients=$clients_var
    local i
    local client
    local next_client
    local status

    for i in "${!clients[@]}"; do
        client=${clients[$i]}
        RDP_FAILURE_DETAIL=""
        log "Using RDP client '${client}' on display mode '${display_mode}'"
        if start_rdp_session "$client" "$display_mode" "$server" "$username" "$password"; then
            return 0
        else
            status=$?
        fi

        if [[ -z $RDP_FAILURE_DETAIL ]]; then
            return "$status"
        fi

        if ((i + 1 == ${#clients[@]})); then
            log_err "RDP client '${client}' ${RDP_FAILURE_DETAIL}; no clients left to try"
            return "$status"
        fi

        next_client=${clients[$((i + 1))]}
        if ! confirm_client_fallback "$client" "$RDP_FAILURE_DETAIL" "$next_client"; then
            log_err "Fallback cancelled"
            return "$status"
        fi
    done
}

require_user_config_for_edit() {
    if [[ ! -f $CONFIG_FILE ]]; then
        log "Error: Edit mode requires user config at '$CONFIG_FILE'. Run install first or create it from '$DEFAULT_CONFIG_FILE'."
        return 1
    fi
}

validate_edit_config() {
    local missing=()

    config_var_exists SERVERS || missing+=(SERVERS)
    config_var_exists KWALLET || missing+=(KWALLET)
    config_var_exists KWALLET_FOLDER || missing+=(KWALLET_FOLDER)

    if ((${#missing[@]} > 0)); then
        log "Error: Missing configuration variables: ${missing[*]}"
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
}

server_entry() {
    local name=$1
    local url=$2
    local up=$3
    local down=$4

    printf '%s|%s|%s|%s' "$name" "$url" "$up" "$down"
}

validate_server_field() {
    local label=$1
    local value=$2

    if [[ -z $value ]]; then
        log "Error: ${label} cannot be empty"
        return 1
    fi

    if [[ $value == *"|"* ]]; then
        log "Error: ${label} cannot contain '|'"
        return 1
    fi
}

validate_vpn_field() {
    local label=$1
    local value=$2

    if [[ $value == *"|"* ]]; then
        log "Error: ${label} cannot contain '|'"
        return 1
    fi
}

normalize_vpn_field() {
    local value
    value=$(trim_ws "$1")

    if [[ -z $value ]]; then
        printf '%s' "*"
    else
        printf '%s' "$value"
    fi
}

server_url_exists_except() {
    local target=$1
    local except_index=$2
    local entry
    local name
    local url
    local org_raw
    local pers_raw
    local i

    for i in "${!SERVERS[@]}"; do
        if [[ $i == "$except_index" ]]; then
            continue
        fi
        entry=${SERVERS[$i]}
        parse_server_entry "$entry" name url org_raw pers_raw || return 1
        if [[ $url == "$target" ]]; then
            return 0
        fi
    done

    return 1
}

line_closes_servers_block() {
    local line=$1
    local i
    local ch
    local next
    local in_quote=""
    local ansi_c=0
    local paren_depth=0

    for ((i = 0; i < ${#line}; i++)); do
        ch=${line:$i:1}

        if [[ $in_quote == '"' ]]; then
            if [[ $ch == '"' ]]; then
                in_quote=""
            elif [[ $ch == "\\" ]]; then
                i=$((i + 1))
            fi
            continue
        fi

        if [[ $in_quote == "'" ]]; then
            if ((ansi_c)) && [[ $ch == "\\" ]]; then
                i=$((i + 1))
                continue
            fi
            if [[ $ch == "'" ]]; then
                in_quote=""
                ansi_c=0
            fi
            continue
        fi

        # Outside quotes a backslash escapes the next character. This covers the
        # '\'' idiom that ${var@Q} emits for embedded single quotes; without it
        # the escaped quote toggles the quote state and a ')' in the entry is
        # mistaken for the end of the SERVERS block.
        if [[ $ch == "\\" ]]; then
            i=$((i + 1))
            continue
        fi

        # Treat $'...' as ANSI-C quoting and $"..." as plain double quoting so
        # backslash escapes inside $'...' do not toggle the quote state.
        if [[ $ch == '$' ]]; then
            next=${line:$((i + 1)):1}
            if [[ $next == "'" ]]; then
                in_quote="'"
                ansi_c=1
                i=$((i + 1))
            elif [[ $next == '"' ]]; then
                in_quote='"'
                i=$((i + 1))
            fi
            continue
        fi

        if [[ $ch == '"' || $ch == "'" ]]; then
            in_quote=$ch
            continue
        fi

        if [[ $ch == '#' ]]; then
            break
        fi

        if [[ $ch == '(' ]]; then
            paren_depth=$((paren_depth + 1))
        elif [[ $ch == ')' ]]; then
            paren_depth=$((paren_depth - 1))
            if ((paren_depth <= 0)); then
                return 0
            fi
        fi
    done

    return 1
}

write_servers_config() {
    local servers_var=$1
    local -n servers_ref=$servers_var
    local target=$CONFIG_FILE
    local tmp
    local line
    local in_servers=0
    local wrote=0
    local entry

    if [[ -L $target ]]; then
        if ! target=$(readlink -f -- "$target"); then
            log "Error: Failed to resolve symlink '$CONFIG_FILE'"
            return 1
        fi
    fi

    tmp="${target}.tmp.$$"

    while IFS= read -r line || [[ -n $line ]]; do
        if ((in_servers)); then
            if line_closes_servers_block "$line"; then
                in_servers=0
            fi
            continue
        fi

        if [[ $line =~ ^[[:space:]]*SERVERS= ]]; then
            printf 'SERVERS=(\n' >>"$tmp"
            for entry in "${servers_ref[@]}"; do
                printf '    %s\n' "${entry@Q}" >>"$tmp"
            done
            printf ')\n' >>"$tmp"
            wrote=1
            if ! line_closes_servers_block "$line"; then
                in_servers=1
            fi
            continue
        fi

        printf '%s\n' "$line" >>"$tmp"
    done <"$CONFIG_FILE"

    if ((wrote == 0)); then
        rm -f "$tmp"
        log "Error: SERVERS block not found in '$CONFIG_FILE'"
        return 1
    fi

    mv "$tmp" "$target"
    SERVERS=("${servers_ref[@]}")
}

kwallet_open_handle() {
    local appid=$1
    qdbus6 org.kde.kwalletd6 /modules/kwalletd6 org.kde.KWallet.open "$KWALLET" 0 "$appid"
}

kwallet_has_entry() {
    local key=$1
    local appid="rdpconn"
    local handle
    local result

    if ! command -v qdbus6 >/dev/null 2>&1; then
        return 1
    fi

    handle=$(kwallet_open_handle "$appid") || return 1
    result=$(qdbus6 org.kde.kwalletd6 /modules/kwalletd6 org.kde.KWallet.hasEntry "$handle" "$KWALLET_FOLDER" "$key" "$appid") || return 1
    [[ $result == "true" ]]
}

kwallet_delete_entry() {
    local key=$1
    local appid="rdpconn"
    local handle
    local result

    if ! command -v qdbus6 >/dev/null 2>&1; then
        log "Error: qdbus6 is required to remove credentials"
        return 1
    fi

    handle=$(kwallet_open_handle "$appid") || return 1
    if ! result=$(qdbus6 org.kde.kwalletd6 /modules/kwalletd6 org.kde.KWallet.removeEntry "$handle" "$KWALLET_FOLDER" "$key" "$appid"); then
        log "Error: Failed to remove credential for '$key'"
        return 1
    fi
    if [[ $result != 0 ]]; then
        log "Error: Failed to remove credential for '$key': $result"
        return 1
    fi
    log "Removed credential for '$key'"
}

kwallet_write_python() {
    local key=$1
    local secret=$2

    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    if ! python3 -c 'import dbus' >/dev/null 2>&1; then
        return 1
    fi

    printf '%s' "$secret" | python3 -c '
import sys
import dbus

key, wallet, folder = sys.argv[1:4]
secret = sys.stdin.read()
appid = "rdpconn"
bus = dbus.SessionBus()
obj = bus.get_object("org.kde.kwalletd6", "/modules/kwalletd6")
kwallet = dbus.Interface(obj, "org.kde.KWallet")
handle = kwallet.open(wallet, 0, appid)
if handle < 0:
    raise SystemExit(f"failed to open wallet: {handle}")
if not kwallet.hasFolder(handle, folder, appid):
    kwallet.createFolder(handle, folder, appid)
rc = kwallet.writePassword(handle, folder, key, secret, appid)
if rc != 0:
    raise SystemExit(f"writePassword failed: {rc}")
if not kwallet.hasEntry(handle, folder, key, appid):
    raise SystemExit("entry was not created")
' "$key" "$KWALLET" "$KWALLET_FOLDER"
}

kwallet_write_qdbus() {
    local key=$1
    local secret=$2
    local appid="rdpconn"
    local handle
    local result

    if ! command -v qdbus6 >/dev/null 2>&1; then
        log "Error: qdbus6 is required for fallback credential writes"
        return 1
    fi

    log "Warning: Python DBus unavailable; falling back to qdbus6. Secret may be visible in process arguments briefly."
    handle=$(kwallet_open_handle "$appid") || return 1
    result=$(qdbus6 org.kde.kwalletd6 /modules/kwalletd6 org.kde.KWallet.writePassword "$handle" "$KWALLET_FOLDER" "$key" "$secret" "$appid") || return 1
    if [[ $result != 0 ]]; then
        log "Error: writePassword failed: $result"
        return 1
    fi
}

prompt_credential_secret() {
    local -n out=$1

    read -r -s -p "Enter username:password: " out
    printf '\n'

    if [[ -z $out || $out != *:* ]]; then
        log "Error: credential must be in 'username:password' format"
        return 1
    fi
}

set_credential_for_url() {
    local url=$1
    local secret

    prompt_credential_secret secret || return 1

    if kwallet_write_python "$url" "$secret"; then
        log "Saved credential for '$url'"
        return 0
    fi

    kwallet_write_qdbus "$url" "$secret" || return 1
    log "Saved credential for '$url'"
}

print_server_list() {
    local stream=${1:-stdout}
    local entry
    local name
    local url
    local org_raw
    local pers_raw
    local status
    local i=1

    for entry in "${SERVERS[@]}"; do
        parse_server_entry "$entry" name url org_raw pers_raw || return 1
        if kwallet_has_entry "$url"; then
            status="present"
        else
            status="missing"
        fi
        if [[ $stream == "stderr" ]]; then
            log_err "${i}) ${name} (${url}) credential: ${status} up: ${org_raw} down: ${pers_raw}"
        else
            log "${i}) ${name} (${url}) credential: ${status} up: ${org_raw} down: ${pers_raw}"
        fi
        ((i++))
    done
}

select_server_index() {
    local choice

    while true; do
        print_server_list stderr
        log_err "b) Back"
        if ! read -r -p "Enter choice (or b to back): " choice; then
            return 1
        fi

        case ${choice,,} in
            b)
                log_err "Cancelled"
                return 1
                ;;
            l)
                continue
                ;;
        esac

        if [[ ! $choice =~ ^[0-9]+$ || $choice -lt 1 || $choice -gt ${#SERVERS[@]} ]]; then
            log_err "Error: Invalid choice"
            continue
        fi

        printf '%s' "$((choice - 1))"
        return 0
    done
}

edit_add_server() {
    local name
    local url
    local up
    local down
    local set_cred
    local -a new_servers=("${SERVERS[@]}")

    read -r -p "Name: " name
    read -r -p "URL: " url
    read -r -p "UP_VPNS [*]: " up
    read -r -p "DOWN_VPNS [*]: " down

    name=$(trim_ws "$name")
    url=$(trim_ws "$url")
    up=$(normalize_vpn_field "$up")
    down=$(normalize_vpn_field "$down")

    validate_server_field "Name" "$name" || return 1
    validate_server_field "URL" "$url" || return 1
    validate_vpn_field "UP_VPNS" "$up" || return 1
    validate_vpn_field "DOWN_VPNS" "$down" || return 1

    if server_url_exists_except "$url" "-1"; then
        log "Error: Server URL '$url' already exists"
        return 1
    fi

    new_servers+=("$(server_entry "$name" "$url" "$up" "$down")")
    write_servers_config new_servers || return 1
    log "Added server '$name ($url)'"

    read -r -p "Set credential now? [y/N]: " set_cred
    if [[ ${set_cred,,} == "y" ]]; then
        set_credential_for_url "$url"
    fi
}

edit_update_server() {
    local index
    local entry
    local old_name
    local old_url
    local old_up
    local old_down
    local name
    local url
    local up
    local down
    local -a new_servers=("${SERVERS[@]}")

    index=$(select_server_index) || return 1
    entry=${SERVERS[$index]}
    parse_server_entry "$entry" old_name old_url old_up old_down || return 1

    read -r -p "Name [$old_name]: " name
    read -r -p "URL [$old_url]: " url
    read -r -p "UP_VPNS [$old_up]: " up
    read -r -p "DOWN_VPNS [$old_down]: " down

    name=$(trim_ws "${name:-$old_name}")
    url=$(trim_ws "${url:-$old_url}")
    up=$(trim_ws "${up:-$old_up}")
    down=$(trim_ws "${down:-$old_down}")

    validate_server_field "Name" "$name" || return 1
    validate_server_field "URL" "$url" || return 1
    validate_vpn_field "UP_VPNS" "$up" || return 1
    validate_vpn_field "DOWN_VPNS" "$down" || return 1

    if server_url_exists_except "$url" "$index"; then
        log "Error: Server URL '$url' already exists"
        return 1
    fi

    new_servers[$index]="$(server_entry "$name" "$url" "$up" "$down")"
    write_servers_config new_servers || return 1
    log "Updated server '$name ($url)'"
}

edit_delete_server() {
    local index
    local entry
    local name
    local url
    local up
    local down
    local confirm
    local delete_cred
    local -a new_servers=()
    local i

    index=$(select_server_index) || return 1
    entry=${SERVERS[$index]}
    parse_server_entry "$entry" name url up down || return 1

    read -r -p "Delete server '$name ($url)'? [y/N]: " confirm
    if [[ ${confirm,,} != "y" ]]; then
        log "Delete cancelled"
        return 0
    fi

    for i in "${!SERVERS[@]}"; do
        if [[ $i != "$index" ]]; then
            new_servers+=("${SERVERS[$i]}")
        fi
    done

    write_servers_config new_servers || return 1
    log "Deleted server '$name ($url)'"

    read -r -p "Delete matching credential? [Y/n]: " delete_cred
    if [[ -z $delete_cred || ${delete_cred,,} == "y" ]]; then
        kwallet_delete_entry "$url"
    fi
}

edit_set_credential() {
    local index
    local entry
    local name
    local url
    local up
    local down

    index=$(select_server_index) || return 1
    entry=${SERVERS[$index]}
    parse_server_entry "$entry" name url up down || return 1
    set_credential_for_url "$url"
}

edit_remove_credential() {
    local index
    local entry
    local name
    local url
    local up
    local down

    index=$(select_server_index) || return 1
    entry=${SERVERS[$index]}
    parse_server_entry "$entry" name url up down || return 1
    kwallet_delete_entry "$url"
}

print_edit_menu() {
    local allow_main_menu=${1:-0}

    log "a) Add server"
    log "e) Edit server"
    log "d) Delete server"
    log "c) Set/update credential"
    log "r) Remove credential"
    log "l) List servers"
    if ((allow_main_menu)); then
        log "m) Main menu"
    fi
    log "q) Quit"
}

prepare_edit_action() {
    local allow_main_menu=${1:-0}

    clear 2>/dev/null || true
    print_edit_menu "$allow_main_menu"
    log ""
}

run_edit_action() {
    "$@" || true
    log ""
}

edit_menu() {
    local allow_main_menu=${1:-0}
    local action
    local menu_visible=0

    clear 2>/dev/null || true
    while true; do
        if ((menu_visible == 0)); then
            print_edit_menu "$allow_main_menu"
            menu_visible=1
        fi
        if ! read -r -p "Choice: " action; then
            return 0
        fi

        case ${action,,} in
            a)
                prepare_edit_action "$allow_main_menu"
                menu_visible=1
                run_edit_action edit_add_server
                ;;
            e)
                prepare_edit_action "$allow_main_menu"
                menu_visible=1
                run_edit_action edit_update_server
                ;;
            d)
                prepare_edit_action "$allow_main_menu"
                menu_visible=1
                run_edit_action edit_delete_server
                ;;
            c)
                prepare_edit_action "$allow_main_menu"
                menu_visible=1
                run_edit_action edit_set_credential
                ;;
            r)
                prepare_edit_action "$allow_main_menu"
                menu_visible=1
                run_edit_action edit_remove_credential
                ;;
            l)
                prepare_edit_action "$allow_main_menu"
                menu_visible=1
                run_edit_action print_server_list
                ;;
            m)
                if ((allow_main_menu)); then
                    return 2
                fi
                prepare_edit_action "$allow_main_menu"
                menu_visible=1
                log "Error: Unknown choice '$action'"
                log ""
                ;;
            q) return 0 ;;
            *)
                prepare_edit_action "$allow_main_menu"
                menu_visible=1
                log "Error: Unknown choice '$action'"
                log ""
                ;;
        esac
    done
}

run_edit_mode() {
    local allow_main_menu=${1:-0}

    require_user_config_for_edit || return 1
    load_user_config || return 1
    validate_edit_config || return 1
    edit_menu "$allow_main_menu"
}

main() {
    if [[ ${1:-} == "--version" || ${1:-} == "-v" ]]; then
        printf 'rdpconn %s\n' "$RDPCONN_VERSION"
        exit 0
    fi

    if [[ ${1:-} == "edit" ]]; then
        shift
        if (($# > 0)); then
            log "Error: edit mode does not accept arguments"
            exit 1
        fi
        run_edit_mode
        exit $?
    fi

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
    while true; do
        if ((${#SERVERS[@]} == 1)); then
            server_entry=${SERVERS[0]}
            if ! parse_server_entry "$server_entry" server_name server_url org_raw pers_raw; then
                exit 1
            fi
            log "Auto-selecting: '${server_name} (${server_url})'"
            break
        fi

        if ! server_entry=$(select_server); then
            exit 1
        fi
        if [[ $server_entry == "__EDIT__" ]]; then
            set +e
            run_edit_mode 1
            local edit_status=$?
            set -e
            if [[ $edit_status -eq 2 ]]; then
                if ! load_user_config; then
                    exit 1
                fi
                if ! validate_config "$display_mode"; then
                    exit 1
                fi
                continue
            fi
            exit "$edit_status"
        fi
        if ! parse_server_entry "$server_entry" server_name server_url org_raw pers_raw; then
            exit 1
        fi
        break
    done

    local -a selected_org_vpns=()
    local -a selected_pers_vpns=()
    resolve_vpn_list "$org_raw" UP_VPNS selected_org_vpns
    resolve_vpn_list "$pers_raw" DOWN_VPNS selected_pers_vpns

    disconnect_personal_vpns selected_pers_vpns
    ensure_org_vpns_connected selected_org_vpns

    if ! retrieve_credentials "$server_name" "$server_url"; then
        exit 1
    fi

    local -a rdp_clients=()
    if ! collect_available_rdp_clients "$display_mode" rdp_clients; then
        exit 1
    fi

    launch_with_fallback "$display_mode" "$server_url" "$SERVER_USERNAME" "$SERVER_PASSWORD" rdp_clients
}

main "$@"
