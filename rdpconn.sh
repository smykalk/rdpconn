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
    local missing=()

    [[ -v PERS_VPNS ]] || missing+=(PERS_VPNS)
    [[ -v ORG_VPN ]] || missing+=(ORG_VPN)
    [[ -v SERVERS ]] || missing+=(SERVERS)
    [[ -v KWALLET ]] || missing+=(KWALLET)
    [[ -v KWALLET_FOLDER ]] || missing+=(KWALLET_FOLDER)
    [[ -v RDP_ARGS ]] || missing+=(RDP_ARGS)

    if ((${#missing[@]} > 0)); then
        log "Error: Missing configuration variables: ${missing[*]}"
        return 1
    fi

    if ((${#SERVERS[@]} == 0)); then
        log "Error: SERVERS array is empty"
        return 1
    fi

    return 0
}

ACTIVE_PERS_VPN=""
ORG_VPN_WAS_ACTIVE=1
SERVER_USERNAME=""
SERVER_PASSWORD=""

cleanup() {
    local exit_code=$1

    trap - EXIT INT TERM

    if [[ ${ORG_VPN_WAS_ACTIVE:-1} -eq 0 ]]; then
        log "Disconnecting from org VPN '$ORG_VPN'"
        if ! nmcli connection down id "$ORG_VPN" >/dev/null; then
            log "Warning: Failed to disconnect org VPN '$ORG_VPN'"
        fi
    fi

    if [[ -n ${ACTIVE_PERS_VPN:-} ]]; then
        log "Reconnecting to personal VPN '$ACTIVE_PERS_VPN'"
        if ! nmcli connection up id "$ACTIVE_PERS_VPN" >/dev/null; then
            log "Warning: Failed to reconnect personal VPN '$ACTIVE_PERS_VPN'"
        fi
    fi

    exit "$exit_code"
}

trap 'cleanup "$?"' EXIT
trap 'cleanup 130' INT TERM

select_server() {
    local choice
    PS3="Enter choice (1-${#SERVERS[@]}): "
    select choice in "${SERVERS[@]}"; do
        if [[ -n ${choice:-} ]]; then
            log "Selected: '$choice'"
            printf '%s' "$choice"
            return
        fi
        log "Invalid choice. Try again."
    done
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

disconnect_personal_vpn() {
    local vpn
    for vpn in "${PERS_VPNS[@]}"; do
        if is_connection_active "$vpn"; then
            ACTIVE_PERS_VPN="$vpn"
            log "Disconnecting from personal VPN '$vpn'"
            if ! nmcli connection down id "$vpn" >/dev/null; then
                log "Warning: Failed to disconnect personal VPN '$vpn'"
            fi
            break
        fi
    done
}

ensure_org_vpn_connected() {
    if is_connection_active "$ORG_VPN"; then
        log "Org VPN '$ORG_VPN' is already active"
        ORG_VPN_WAS_ACTIVE=1
        return
    fi

    log "Connecting to org VPN '$ORG_VPN'"
    nmcli connection up id "$ORG_VPN" >/dev/null
    ORG_VPN_WAS_ACTIVE=0
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
    local server=$1
    SERVER_USERNAME=$(read_kwallet_secret "${server}_username")
    SERVER_PASSWORD=$(read_kwallet_secret "${server}_password")

    if [[ -z $SERVER_USERNAME || -z $SERVER_PASSWORD ]]; then
        log "Error: Failed to retrieve credentials from KWallet for server '$server'"
        log "Ensure wallet '$KWALLET', folder '$KWALLET_FOLDER' contains:"
        log "  - ${server}_username"
        log "  - ${server}_password"
        return 1
    fi

    log "Credentials retrieved successfully"
}

start_rdp_session() {
    local server=$1
    local username=$2
    local password=$3

    local args=(
        "${RDP_ARGS[@]}"
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

    xfreerdp3 "${args[@]}"
}

main() {
    if ! load_user_config || ! validate_config; then
        exit 1
    fi

    local server
    if ((${#SERVERS[@]} == 1)); then
        server=${SERVERS[0]}
        log "Auto-selecting: '$server'"
    else
        if ! server=$(select_server); then
            exit 1
        fi
    fi

    disconnect_personal_vpn
    ensure_org_vpn_connected

    if ! retrieve_credentials "$server"; then
        exit 1
    fi

    start_rdp_session "$server" "$SERVER_USERNAME" "$SERVER_PASSWORD"
}

main "$@"