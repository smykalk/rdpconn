#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

CURRENT_TEST_TMP=""
BIN_DIR=""
CONFIG_HOME=""
OUTPUT_FILE=""
PAYLOAD_FILE=""
ARGV_FILE=""
ENV_FILE=""
PID_FILE=""
NMCLI_LOG=""
KWALLET_LOG=""
KWALLET_KEYS_FILE=""
MONITOR_LIST_FILE=""
MONITOR_CALL_FILE=""
MONITOR_ENV_FILE=""
MONITOR_EXIT_CODE=""
RDP_STATUS=0
RDP_PID=""
SESSION_TYPE="x11"
ACTIVE_CONNECTIONS=""
KWALLET_SECRET="alice:super-secret"
KWALLET_FAIL=0
CLIENT_SLEEP=0
PYTHON_DBUS_AVAILABLE=1

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local file=$1
    local pattern=$2

    if ! grep -Fq -- "$pattern" "$file"; then
        printf 'Expected to find %s in %s\n' "$pattern" "$file" >&2
        cat "$file" >&2
        exit 1
    fi
}

assert_not_contains() {
    local file=$1
    local pattern=$2

    if grep -Fq -- "$pattern" "$file"; then
        printf 'Did not expect to find %s in %s\n' "$pattern" "$file" >&2
        cat "$file" >&2
        exit 1
    fi
}

assert_line() {
    local file=$1
    local line=$2

    if ! grep -Fxq -- "$line" "$file"; then
        printf 'Expected to find line %s in %s\n' "$line" "$file" >&2
        cat "$file" >&2
        exit 1
    fi
}

assert_status() {
    local expected=$1

    if [[ $RDP_STATUS -ne $expected ]]; then
        printf 'Expected exit status %s, got %s\n' "$expected" "$RDP_STATUS" >&2
        cat "$OUTPUT_FILE" >&2
        exit 1
    fi
}

assert_success() {
    if [[ $RDP_STATUS -ne 0 ]]; then
        printf 'Expected command to succeed, got %s\n' "$RDP_STATUS" >&2
        cat "$OUTPUT_FILE" >&2
        exit 1
    fi
}

assert_failure() {
    if [[ $RDP_STATUS -eq 0 ]]; then
        printf 'Expected command to fail\n' >&2
        cat "$OUTPUT_FILE" >&2
        exit 1
    fi
}

assert_file_exists() {
    local path=$1

    [[ -f $path ]] || fail "Expected file to exist: $path"
}

wait_for_file() {
    local path=$1
    local attempt

    for attempt in {1..50}; do
        if [[ -f $path ]]; then
            return 0
        fi
        sleep 0.1
    done

    printf 'Timed out waiting for %s\n' "$path" >&2
    exit 1
}

write_stubs() {
    cat >"$BIN_DIR/nmcli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log=${RDP_TEST_NMCLI_LOG:?}

if [[ ${1:-} == "-t" ]]; then
    shift
    escape=yes
    if [[ ${1:-} == "-e" ]]; then
        if [[ ${2:-} == "no" ]]; then
            escape=no
        fi
        shift 2
    fi
    if [[ ${1:-} == "-f" && ${2:-} == "NAME" && ${3:-} == "connection" && ${4:-} == "show" && ${5:-} == "--active" ]]; then
        printf '%s\n' "show-active" >>"$log"
        active_csv=${RDP_TEST_ACTIVE_CONNECTIONS-}
        if [[ -n $active_csv ]]; then
            IFS=',' read -r -a active_connections <<<"$active_csv"
            for active_name in "${active_connections[@]}"; do
                if [[ $escape == "yes" ]]; then
                    active_name=${active_name//\\/\\\\}
                    active_name=${active_name//:/\\:}
                fi
                printf '%s\n' "$active_name"
            done
        fi
        exit 0
    fi
fi

if [[ ${1:-} == "connection" && ${2:-} == "down" && ${3:-} == "id" ]]; then
    printf 'down:%s\n' "${4:-}" >>"$log"
    exit 0
fi

if [[ ${1:-} == "connection" && ${2:-} == "up" && ${3:-} == "id" ]]; then
    printf 'up:%s\n' "${4:-}" >>"$log"
    exit 0
fi

printf 'nmcli:%s\n' "$*" >>"$log"
exit 0
EOF

    cat >"$BIN_DIR/kwallet-query" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${RDP_TEST_KWALLET_LOG:?}"

if [[ ${RDP_TEST_KWALLET_FAIL:-0} == 1 ]]; then
    exit 1
fi

if [[ ${1:-} == "-f" && ${3:-} == "-l" ]]; then
    if [[ -f ${RDP_TEST_KWALLET_KEYS_FILE:-} ]]; then
        cat "$RDP_TEST_KWALLET_KEYS_FILE"
    fi
    exit 0
fi

printf '%s' "${RDP_TEST_KWALLET_SECRET-alice:super-secret}"
EOF

    cat >"$BIN_DIR/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ ${RDP_TEST_PYTHON_DBUS_AVAILABLE:-1} != 1 ]]; then
    exit 1
fi

if [[ ${1:-} == "-c" && ${2:-} == "import dbus" ]]; then
    exit 0
fi

key=${3:-}
wallet=${4:-}
folder=${5:-}
secret=$(cat)
printf 'python-write:%s:%s:%s:%s\n' "$wallet" "$folder" "$key" "$secret" >>"${RDP_TEST_KWALLET_LOG:?}"
printf '%s\n' "$key" >>"${RDP_TEST_KWALLET_KEYS_FILE:?}"
EOF

    cat >"$BIN_DIR/qdbus6" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method=${3:-}
case "$method" in
    org.kde.KWallet.open)
        printf '42\n'
        ;;
    org.kde.KWallet.entryList)
        if [[ -f ${RDP_TEST_KWALLET_KEYS_FILE:-} ]]; then
            cat "$RDP_TEST_KWALLET_KEYS_FILE"
        fi
        ;;
    org.kde.KWallet.hasEntry)
        key=${6:-}
        if [[ -f ${RDP_TEST_KWALLET_KEYS_FILE:-} ]] && grep -Fx -- "$key" "$RDP_TEST_KWALLET_KEYS_FILE" >/dev/null; then
            printf 'true\n'
        else
            printf 'false\n'
        fi
        ;;
    org.kde.KWallet.hasFolder|org.kde.KWallet.createFolder)
        printf 'true\n'
        ;;
    org.kde.KWallet.writePassword)
        key=${6:-}
        secret=${7:-}
        printf 'qdbus-write:%s:%s\n' "$key" "$secret" >>"${RDP_TEST_KWALLET_LOG:?}"
        printf '%s\n' "$key" >>"${RDP_TEST_KWALLET_KEYS_FILE:?}"
        printf '0\n'
        ;;
    org.kde.KWallet.removeEntry)
        key=${6:-}
        printf 'remove:%s\n' "$key" >>"${RDP_TEST_KWALLET_LOG:?}"
        if [[ -f ${RDP_TEST_KWALLET_KEYS_FILE:-} ]]; then
            grep -Fxv -- "$key" "$RDP_TEST_KWALLET_KEYS_FILE" >"${RDP_TEST_KWALLET_KEYS_FILE}.tmp" || true
            mv "${RDP_TEST_KWALLET_KEYS_FILE}.tmp" "$RDP_TEST_KWALLET_KEYS_FILE"
        fi
        printf '0\n'
        ;;
    *)
        printf 'qdbus:%s\n' "$*" >>"${RDP_TEST_KWALLET_LOG:?}"
        ;;
esac
EOF

    cat >"$BIN_DIR/fake-freerdp3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == "/list:monitor" ]]; then
    printf '%s\n' "$@" >"${RDP_TEST_MONITOR_CALL_FILE:?}"
    env | sort >"${RDP_TEST_MONITOR_ENV_FILE:?}"
    cat "${RDP_TEST_MONITOR_LIST_FILE:?}"
    exit "${RDP_TEST_MONITOR_EXIT_CODE:-0}"
fi

printf '%s\n' "$$" >"${RDP_TEST_PID_FILE:?}"
printf '%s\n' "$@" >"${RDP_TEST_ARGV_FILE:?}"
env | sort >"${RDP_TEST_ENV_FILE:?}"

fd_arg=${1:-}
if [[ $fd_arg != /args-from:fd:* ]]; then
    printf 'unexpected argv: %s\n' "$fd_arg" >&2
    exit 1
fi

fd=${fd_arg#/args-from:fd:}
cat <&"$fd" >"${RDP_TEST_FD_PAYLOAD_FILE:?}"
sleep "${RDP_TEST_CLIENT_SLEEP:-0}"
EOF

    cp "$BIN_DIR/fake-freerdp3" "$BIN_DIR/xfreerdp3"
    cp "$BIN_DIR/fake-freerdp3" "$BIN_DIR/sdl-freerdp3"

    cat >"$BIN_DIR/unsupported-client" <<'EOF'
#!/usr/bin/env bash
sleep 1
EOF

    cat >"$BIN_DIR/clear" <<'EOF'
#!/usr/bin/env bash
printf 'clear\n' >>"${RDP_TEST_CLEAR_LOG:?}"
EOF

    chmod +x "$BIN_DIR/nmcli" "$BIN_DIR/kwallet-query" "$BIN_DIR/python3" "$BIN_DIR/qdbus6" "$BIN_DIR/fake-freerdp3" "$BIN_DIR/xfreerdp3" "$BIN_DIR/sdl-freerdp3" "$BIN_DIR/unsupported-client" "$BIN_DIR/clear"
}

setup_test() {
    local name=$1

    CURRENT_TEST_TMP=$(mktemp -d "$TEST_ROOT/${name}.XXXXXX")
    BIN_DIR="$CURRENT_TEST_TMP/bin"
    CONFIG_HOME="$CURRENT_TEST_TMP/config"
    OUTPUT_FILE="$CURRENT_TEST_TMP/output.log"
    PAYLOAD_FILE="$CURRENT_TEST_TMP/client.args"
    ARGV_FILE="$CURRENT_TEST_TMP/client.argv"
    ENV_FILE="$CURRENT_TEST_TMP/client.env"
    PID_FILE="$CURRENT_TEST_TMP/client.pid"
    NMCLI_LOG="$CURRENT_TEST_TMP/nmcli.log"
    KWALLET_LOG="$CURRENT_TEST_TMP/kwallet.log"
    KWALLET_KEYS_FILE="$CURRENT_TEST_TMP/kwallet.keys"
    CLEAR_LOG="$CURRENT_TEST_TMP/clear.log"
    MONITOR_LIST_FILE="$CURRENT_TEST_TMP/monitors.list"
    MONITOR_CALL_FILE="$CURRENT_TEST_TMP/monitors.calls"
    MONITOR_ENV_FILE="$CURRENT_TEST_TMP/monitors.env"
    MONITOR_EXIT_CODE=0
    RDP_STATUS=0
    RDP_PID=""
    SESSION_TYPE="x11"
    ACTIVE_CONNECTIONS=""
    KWALLET_SECRET="alice:super-secret"
    KWALLET_FAIL=0
    CLIENT_SLEEP=0
    PYTHON_DBUS_AVAILABLE=1

    mkdir -p "$BIN_DIR" "$CONFIG_HOME"
    : >"$NMCLI_LOG"
    : >"$KWALLET_LOG"
    : >"$KWALLET_KEYS_FILE"
    : >"$CLEAR_LOG"
    : >"$MONITOR_LIST_FILE"
    : >"$MONITOR_CALL_FILE"
    : >"$MONITOR_ENV_FILE"
    write_stubs
}

run_rdpconn() {
    local stdin=${1-}

    set +e
    if (($# > 0)); then
        printf '%s' "$stdin" | env \
            PATH="$BIN_DIR:$PATH" \
            XDG_CONFIG_HOME="$CONFIG_HOME" \
            XDG_SESSION_TYPE="$SESSION_TYPE" \
            RDP_TEST_ACTIVE_CONNECTIONS="$ACTIVE_CONNECTIONS" \
            RDP_TEST_NMCLI_LOG="$NMCLI_LOG" \
            RDP_TEST_KWALLET_LOG="$KWALLET_LOG" \
            RDP_TEST_KWALLET_KEYS_FILE="$KWALLET_KEYS_FILE" \
            RDP_TEST_KWALLET_SECRET="$KWALLET_SECRET" \
            RDP_TEST_KWALLET_FAIL="$KWALLET_FAIL" \
            RDP_TEST_PYTHON_DBUS_AVAILABLE="$PYTHON_DBUS_AVAILABLE" \
            RDP_TEST_CLEAR_LOG="$CLEAR_LOG" \
            RDP_TEST_PID_FILE="$PID_FILE" \
            RDP_TEST_ARGV_FILE="$ARGV_FILE" \
            RDP_TEST_ENV_FILE="$ENV_FILE" \
            RDP_TEST_FD_PAYLOAD_FILE="$PAYLOAD_FILE" \
            RDP_TEST_CLIENT_SLEEP="$CLIENT_SLEEP" \
            RDP_TEST_MONITOR_LIST_FILE="$MONITOR_LIST_FILE" \
            RDP_TEST_MONITOR_CALL_FILE="$MONITOR_CALL_FILE" \
            RDP_TEST_MONITOR_ENV_FILE="$MONITOR_ENV_FILE" \
            RDP_TEST_MONITOR_EXIT_CODE="$MONITOR_EXIT_CODE" \
            "$REPO_ROOT/rdpconn.sh" >"$OUTPUT_FILE" 2>&1
    else
        env \
            PATH="$BIN_DIR:$PATH" \
            XDG_CONFIG_HOME="$CONFIG_HOME" \
            XDG_SESSION_TYPE="$SESSION_TYPE" \
            RDP_TEST_ACTIVE_CONNECTIONS="$ACTIVE_CONNECTIONS" \
            RDP_TEST_NMCLI_LOG="$NMCLI_LOG" \
            RDP_TEST_KWALLET_LOG="$KWALLET_LOG" \
            RDP_TEST_KWALLET_KEYS_FILE="$KWALLET_KEYS_FILE" \
            RDP_TEST_KWALLET_SECRET="$KWALLET_SECRET" \
            RDP_TEST_KWALLET_FAIL="$KWALLET_FAIL" \
            RDP_TEST_PYTHON_DBUS_AVAILABLE="$PYTHON_DBUS_AVAILABLE" \
            RDP_TEST_CLEAR_LOG="$CLEAR_LOG" \
            RDP_TEST_PID_FILE="$PID_FILE" \
            RDP_TEST_ARGV_FILE="$ARGV_FILE" \
            RDP_TEST_ENV_FILE="$ENV_FILE" \
            RDP_TEST_FD_PAYLOAD_FILE="$PAYLOAD_FILE" \
            RDP_TEST_CLIENT_SLEEP="$CLIENT_SLEEP" \
            RDP_TEST_MONITOR_LIST_FILE="$MONITOR_LIST_FILE" \
            RDP_TEST_MONITOR_CALL_FILE="$MONITOR_CALL_FILE" \
            RDP_TEST_MONITOR_ENV_FILE="$MONITOR_ENV_FILE" \
            RDP_TEST_MONITOR_EXIT_CODE="$MONITOR_EXIT_CODE" \
            "$REPO_ROOT/rdpconn.sh" >"$OUTPUT_FILE" 2>&1
    fi
    RDP_STATUS=$?
    set -e
}

run_rdpconn_async() {
    env \
        PATH="$BIN_DIR:$PATH" \
        XDG_CONFIG_HOME="$CONFIG_HOME" \
        XDG_SESSION_TYPE="$SESSION_TYPE" \
        RDP_TEST_ACTIVE_CONNECTIONS="$ACTIVE_CONNECTIONS" \
        RDP_TEST_NMCLI_LOG="$NMCLI_LOG" \
        RDP_TEST_KWALLET_LOG="$KWALLET_LOG" \
        RDP_TEST_KWALLET_KEYS_FILE="$KWALLET_KEYS_FILE" \
        RDP_TEST_KWALLET_SECRET="$KWALLET_SECRET" \
        RDP_TEST_KWALLET_FAIL="$KWALLET_FAIL" \
        RDP_TEST_PYTHON_DBUS_AVAILABLE="$PYTHON_DBUS_AVAILABLE" \
        RDP_TEST_CLEAR_LOG="$CLEAR_LOG" \
        RDP_TEST_PID_FILE="$PID_FILE" \
        RDP_TEST_ARGV_FILE="$ARGV_FILE" \
        RDP_TEST_ENV_FILE="$ENV_FILE" \
        RDP_TEST_FD_PAYLOAD_FILE="$PAYLOAD_FILE" \
        RDP_TEST_CLIENT_SLEEP="$CLIENT_SLEEP" \
        RDP_TEST_MONITOR_LIST_FILE="$MONITOR_LIST_FILE" \
        RDP_TEST_MONITOR_CALL_FILE="$MONITOR_CALL_FILE" \
        RDP_TEST_MONITOR_ENV_FILE="$MONITOR_ENV_FILE" \
        RDP_TEST_MONITOR_EXIT_CODE="$MONITOR_EXIT_CODE" \
        "$REPO_ROOT/rdpconn.sh" >"$OUTPUT_FILE" 2>&1 &
    RDP_PID=$!
}

run_rdpconn_edit() {
    local stdin=${1-}

    set +e
    printf '%s' "$stdin" | env \
        PATH="$BIN_DIR:$PATH" \
        XDG_CONFIG_HOME="$CONFIG_HOME" \
        XDG_SESSION_TYPE="$SESSION_TYPE" \
        RDP_TEST_ACTIVE_CONNECTIONS="$ACTIVE_CONNECTIONS" \
        RDP_TEST_NMCLI_LOG="$NMCLI_LOG" \
        RDP_TEST_KWALLET_LOG="$KWALLET_LOG" \
        RDP_TEST_KWALLET_KEYS_FILE="$KWALLET_KEYS_FILE" \
        RDP_TEST_KWALLET_SECRET="$KWALLET_SECRET" \
        RDP_TEST_KWALLET_FAIL="$KWALLET_FAIL" \
        RDP_TEST_PYTHON_DBUS_AVAILABLE="$PYTHON_DBUS_AVAILABLE" \
        RDP_TEST_CLEAR_LOG="$CLEAR_LOG" \
        RDP_TEST_PID_FILE="$PID_FILE" \
        RDP_TEST_ARGV_FILE="$ARGV_FILE" \
        RDP_TEST_ENV_FILE="$ENV_FILE" \
        RDP_TEST_FD_PAYLOAD_FILE="$PAYLOAD_FILE" \
        RDP_TEST_CLIENT_SLEEP="$CLIENT_SLEEP" \
        RDP_TEST_MONITOR_LIST_FILE="$MONITOR_LIST_FILE" \
        RDP_TEST_MONITOR_CALL_FILE="$MONITOR_CALL_FILE" \
        RDP_TEST_MONITOR_ENV_FILE="$MONITOR_ENV_FILE" \
        RDP_TEST_MONITOR_EXIT_CODE="$MONITOR_EXIT_CODE" \
        "$REPO_ROOT/rdpconn.sh" edit >"$OUTPUT_FILE" 2>&1
    RDP_STATUS=$?
    set -e
}

wait_for_rdpconn() {
    set +e
    wait "$RDP_PID"
    RDP_STATUS=$?
    set -e
}

write_basic_config() {
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF
}

write_client_config() {
    local client
    local clients=""
    for client in "$@"; do
        clients+=" \"$client\""
    done

    cat >"$CONFIG_HOME/rdpconn.conf" <<EOF
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=(${clients})
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF
}

write_failing_client() {
    local name=$1
    local status=$2

    cat >"$BIN_DIR/$name" <<EOF
#!/usr/bin/env bash
exit $status
EOF
    chmod +x "$BIN_DIR/$name"
}

test_secure_launch_hides_password_and_uses_client_args() {
    setup_test "${FUNCNAME[0]}"
    CLIENT_SLEEP=2
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/display-default")
RDP_ARGS_WAYLAND=("/wayland-default")
RDP_ARGS_FAKE_FREERDP3=("/client-specific")
EOF

    run_rdpconn_async
    wait_for_file "$PID_FILE"

    local client_pid
    client_pid=$(<"$PID_FILE")
    ps -o command= -p "$client_pid" >"$CURRENT_TEST_TMP/ps-command.log"

    wait_for_rdpconn
    assert_success
    assert_contains "$OUTPUT_FILE" "Using RDP client 'fake-freerdp3' on display mode 'x11'"
    assert_contains "$ARGV_FILE" "/args-from:fd:"
    assert_not_contains "$ARGV_FILE" "super-secret"
    assert_not_contains "$CURRENT_TEST_TMP/ps-command.log" "super-secret"
    assert_contains "$PAYLOAD_FILE" "/u:alice"
    assert_contains "$PAYLOAD_FILE" "/p:super-secret"
    assert_contains "$PAYLOAD_FILE" "/v:server.example"
    assert_contains "$PAYLOAD_FILE" "/d:"
    assert_contains "$PAYLOAD_FILE" "/client-specific"
    assert_not_contains "$PAYLOAD_FILE" "/display-default"
}

test_display_mode_and_client_selection() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config
    SESSION_TYPE="wayland"

    run_rdpconn
    assert_success
    assert_contains "$OUTPUT_FILE" "Using RDP client 'sdl-freerdp3' on display mode 'wayland'"
    assert_contains "$PAYLOAD_FILE" "/wayland-default"
    assert_not_contains "$PAYLOAD_FILE" "/x11-default"
}

test_client_fallback_and_no_available_client_error() {
    setup_test "${FUNCNAME[0]}"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("missing-freerdp3" "fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn
    assert_success
    assert_contains "$OUTPUT_FILE" "Using RDP client 'fake-freerdp3' on display mode 'x11'"

    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("missing-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "None of the configured RDP clients for 'x11' are available"
}

test_menu_selection_uses_selected_server() {
    setup_test "${FUNCNAME[0]}"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=(
    "First|first.example|-|-"
    "Second|second.example|-|-"
)
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn $'2\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Selected: 'Second (second.example)'"
    assert_contains "$PAYLOAD_FILE" "/v:second.example"
    assert_contains "$KWALLET_LOG" "-r second.example"
}

test_vpn_defaults_and_cleanup() {
    setup_test "${FUNCNAME[0]}"
    ACTIVE_CONNECTIONS="personal-active,org-active"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("org-active" "org-inactive")
DOWN_VPNS=("personal-active" "personal-inactive")
SERVERS=("Test|server.example|*|*")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn $'y\n'
    assert_success
    assert_contains "$NMCLI_LOG" "down:personal-active"
    assert_contains "$NMCLI_LOG" "up:org-inactive"
    assert_contains "$NMCLI_LOG" "down:org-inactive"
    assert_contains "$NMCLI_LOG" "up:personal-active"
    assert_not_contains "$NMCLI_LOG" "down:personal-inactive"
    assert_not_contains "$NMCLI_LOG" "up:org-active"
    assert_not_contains "$NMCLI_LOG" "down:org-active"
}

test_cleanup_asks_before_disconnecting_org_vpn() {
    setup_test "${FUNCNAME[0]}_default"
    ACTIVE_CONNECTIONS="personal-active,org-active"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("org-active" "org-inactive")
DOWN_VPNS=("personal-active")
SERVERS=("Test|server.example|*|*")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn $'\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Disconnect from org VPN 'org-inactive'? [Y/n]: "
    assert_contains "$NMCLI_LOG" "down:org-inactive"
    assert_contains "$NMCLI_LOG" "up:personal-active"
    assert_not_contains "$OUTPUT_FILE" "Disconnect from org VPN 'org-active'"

    setup_test "${FUNCNAME[0]}_declined"
    ACTIVE_CONNECTIONS="personal-active,org-active"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("org-active" "org-inactive")
DOWN_VPNS=("personal-active")
SERVERS=("Test|server.example|*|*")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn $'n\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Disconnect from org VPN 'org-inactive'? [Y/n]: "
    assert_contains "$OUTPUT_FILE" "Keeping org VPN 'org-inactive' connected"
    assert_contains "$OUTPUT_FILE" "Leaving personal VPN 'personal-active' disconnected: an org VPN is still connected"
    assert_not_contains "$NMCLI_LOG" "down:org-inactive"
    assert_not_contains "$NMCLI_LOG" "up:personal-active"

    setup_test "${FUNCNAME[0]}_eof"
    ACTIVE_CONNECTIONS="personal-active,org-active"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("org-active" "org-inactive")
DOWN_VPNS=("personal-active")
SERVERS=("Test|server.example|*|*")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn ""
    assert_success
    assert_contains "$NMCLI_LOG" "down:org-inactive"
}

test_explicit_server_vpn_lists_are_trimmed() {
    setup_test "${FUNCNAME[0]}"
    ACTIVE_CONNECTIONS="personal-one"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("global-org")
DOWN_VPNS=("global-personal")
SERVERS=("Test|server.example| org-one, org-two | personal-one ")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn $'y\ny\n'
    assert_success
    assert_contains "$NMCLI_LOG" "up:org-one"
    assert_contains "$NMCLI_LOG" "up:org-two"
    assert_contains "$NMCLI_LOG" "down:personal-one"
    assert_not_contains "$NMCLI_LOG" "up:global-org"
    assert_not_contains "$NMCLI_LOG" "down:global-personal"
}

test_vpn_names_with_colon_are_matched_active() {
    setup_test "${FUNCNAME[0]}"
    ACTIVE_CONNECTIONS="work:personal,work:org"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("work:org")
DOWN_VPNS=("work:personal")
SERVERS=("Test|server.example|*|*")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn
    assert_success
    assert_contains "$NMCLI_LOG" "down:work:personal"
    assert_not_contains "$NMCLI_LOG" "up:work:org"
}

test_rdp_env_and_share_are_passed() {
    setup_test "${FUNCNAME[0]}"
    cat >"$CONFIG_HOME/rdpconn.conf" <<EOF
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_SHARE="$CURRENT_TEST_TMP/share"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
RDP_ENV_FAKE_FREERDP3=("RDP_MARKER=present" "SDL_VIDEODRIVER=wayland")
EOF

    run_rdpconn
    assert_success
    [[ -d "$CURRENT_TEST_TMP/share" ]] || fail "Expected RDP share directory to be created"
    assert_contains "$PAYLOAD_FILE" "/drive:rdp-share,$CURRENT_TEST_TMP/share"
    assert_contains "$ENV_FILE" "RDP_MARKER=present"
    assert_contains "$ENV_FILE" "SDL_VIDEODRIVER=wayland"
}

test_credential_domain_is_passed() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config
    KWALLET_SECRET='UP\alice:super-secret'

    run_rdpconn
    assert_success
    assert_line "$PAYLOAD_FILE" "/u:alice"
    assert_line "$PAYLOAD_FILE" "/p:super-secret"
    assert_line "$PAYLOAD_FILE" "/d:UP"

    setup_test "${FUNCNAME[0]}_no_domain"
    write_basic_config

    run_rdpconn
    assert_success
    assert_line "$PAYLOAD_FILE" "/u:alice"
    assert_line "$PAYLOAD_FILE" "/d:"
    assert_not_contains "$PAYLOAD_FILE" "/d:UP"
}

test_edit_rejects_malformed_credentials() {
    local -a secrets=(
        '\alice:secret'
        'UP\:secret'
        'UP\alice\extra:secret'
        'alice:'
        'nopass'
    )
    local i
    local secret

    for i in "${!secrets[@]}"; do
        secret=${secrets[$i]}
        setup_test "${FUNCNAME[0]}_$i"
        write_basic_config

        run_rdpconn_edit $'c\n1\n'"$secret"$'\nq\n'
        assert_success
        assert_contains "$OUTPUT_FILE" "credential must be in 'username:password' or 'domain\\username:password' format"
        assert_not_contains "$KWALLET_LOG" "write:"
    done
}

test_validation_errors() {
    setup_test "${FUNCNAME[0]}_missing"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF
    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "Missing configuration variables: UP_VPNS"

    setup_test "${FUNCNAME[0]}_legacy_clients"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS=("fake-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF
    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "RDP_CLIENTS is no longer supported"

    setup_test "${FUNCNAME[0]}_empty_servers"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=()
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF
    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "SERVERS array is empty"

    setup_test "${FUNCNAME[0]}_bad_server"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("server.example")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF
    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "Invalid server entry 'server.example'"

    setup_test "${FUNCNAME[0]}_empty_clients"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=()
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF
    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "RDP_CLIENTS_X11 array is empty"
}

test_version_flag_reports_version_without_config() {
    setup_test "${FUNCNAME[0]}"
    rm -f "$CONFIG_HOME/rdpconn.conf"

    local expected
    expected=$(sed -n 's/^RDPCONN_VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/rdpconn.sh")
    [[ -n $expected ]] || fail "Could not read RDPCONN_VERSION from rdpconn.sh"

    set +e
    env PATH="$BIN_DIR:$PATH" XDG_CONFIG_HOME="$CONFIG_HOME" "$REPO_ROOT/rdpconn.sh" --version >"$OUTPUT_FILE" 2>&1
    RDP_STATUS=$?
    set -e
    assert_success
    assert_contains "$OUTPUT_FILE" "rdpconn $expected"
    assert_not_contains "$OUTPUT_FILE" "Configuration file not found"
    [[ ! -f $ARGV_FILE ]] || fail "Client must not be launched for --version"
}

test_credential_errors() {
    setup_test "${FUNCNAME[0]}_missing"
    write_basic_config
    KWALLET_SECRET=""
    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "Failed to retrieve credentials from KWallet"

    setup_test "${FUNCNAME[0]}_invalid"
    write_basic_config
    KWALLET_SECRET="not-a-credential-pair"
    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "must be in 'username:password' or 'domain\\username:password' format"

    setup_test "${FUNCNAME[0]}_empty_domain"
    write_basic_config
    KWALLET_SECRET='\alice:super-secret'
    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "must be in 'username:password' or 'domain\\username:password' format"

    setup_test "${FUNCNAME[0]}_empty_user"
    write_basic_config
    KWALLET_SECRET='UP\:super-secret'
    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "must be in 'username:password' or 'domain\\username:password' format"

    setup_test "${FUNCNAME[0]}_extra_backslash"
    write_basic_config
    KWALLET_SECRET='UP\alice\extra:super-secret'
    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "must be in 'username:password' or 'domain\\username:password' format"

    setup_test "${FUNCNAME[0]}_query_failure"
    write_basic_config
    KWALLET_FAIL=1
    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "Failed to retrieve credentials from KWallet"
}

test_launch_rejections() {
    setup_test "${FUNCNAME[0]}_unsupported_client"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("unsupported-client")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF
    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "Unsupported RDP client 'unsupported-client'"

    setup_test "${FUNCNAME[0]}_newline_arg"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=($'/bad\narg')
RDP_ARGS_WAYLAND=("/wayland-default")
EOF
    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "RDP argument contains a newline"
}

test_runtime_fallback_confirmed_uses_next_client() {
    setup_test "${FUNCNAME[0]}"
    write_failing_client failing-freerdp3 130
    write_client_config failing-freerdp3 fake-freerdp3

    run_rdpconn $'y\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Using RDP client 'failing-freerdp3' on display mode 'x11'"
    assert_contains "$OUTPUT_FILE" "RDP client 'failing-freerdp3' exited with status 130."
    assert_contains "$OUTPUT_FILE" "Try next client 'fake-freerdp3'? [y/N]: "
    assert_contains "$OUTPUT_FILE" "Using RDP client 'fake-freerdp3' on display mode 'x11'"
    assert_contains "$PAYLOAD_FILE" "/v:server.example"
    assert_contains "$PAYLOAD_FILE" "/p:super-secret"
}

test_runtime_fallback_declined_exits_with_status() {
    setup_test "${FUNCNAME[0]}"
    write_failing_client failing-freerdp3 130
    write_client_config failing-freerdp3 fake-freerdp3

    run_rdpconn $'n\n'
    assert_status 130
    assert_contains "$OUTPUT_FILE" "Fallback cancelled"
    assert_not_contains "$OUTPUT_FILE" "Using RDP client 'fake-freerdp3'"
    [[ ! -f $ARGV_FILE ]] || fail "Client must not be launched when fallback is declined"
}

test_runtime_fallback_bare_enter_stops() {
    setup_test "${FUNCNAME[0]}"
    write_failing_client failing-freerdp3 130
    write_client_config failing-freerdp3 fake-freerdp3

    run_rdpconn $'\n'
    assert_status 130
    assert_contains "$OUTPUT_FILE" "Fallback cancelled"
    [[ ! -f $ARGV_FILE ]] || fail "Client must not be launched when fallback is not confirmed"
}

test_runtime_fallback_eof_stops() {
    setup_test "${FUNCNAME[0]}"
    write_failing_client failing-freerdp3 130
    write_client_config failing-freerdp3 fake-freerdp3

    run_rdpconn ""
    assert_status 130
    assert_contains "$OUTPUT_FILE" "Fallback cancelled"
    [[ ! -f $ARGV_FILE ]] || fail "Client must not be launched when the fallback prompt cannot be answered"
}

test_runtime_fallback_exhausts_all_clients() {
    setup_test "${FUNCNAME[0]}"
    write_failing_client failing-freerdp3 130
    write_failing_client also-failing-freerdp3 131
    write_client_config failing-freerdp3 also-failing-freerdp3

    run_rdpconn $'y\n'
    assert_status 131
    assert_contains "$OUTPUT_FILE" "RDP client 'failing-freerdp3' exited with status 130."
    assert_contains "$OUTPUT_FILE" "Try next client 'also-failing-freerdp3'? [y/N]: "
    assert_contains "$OUTPUT_FILE" "RDP client 'also-failing-freerdp3' exited with status 131; no clients left to try"
}

test_runtime_fallback_skips_missing_binary() {
    setup_test "${FUNCNAME[0]}"
    write_failing_client failing-freerdp3 130
    write_client_config missing-freerdp3 failing-freerdp3 fake-freerdp3

    run_rdpconn $'y\n'
    assert_success
    assert_not_contains "$OUTPUT_FILE" "Using RDP client 'missing-freerdp3'"
    assert_not_contains "$OUTPUT_FILE" "Try next client 'failing-freerdp3'"
    assert_contains "$OUTPUT_FILE" "Try next client 'fake-freerdp3'? [y/N]: "
    assert_contains "$OUTPUT_FILE" "Using RDP client 'fake-freerdp3' on display mode 'x11'"
    assert_contains "$PAYLOAD_FILE" "/v:server.example"
}

test_runtime_session_end_does_not_prompt_fallback() {
    local status
    for status in 1 2 3 4 5 11 12; do
        setup_test "${FUNCNAME[0]}_${status}"
        write_failing_client failing-freerdp3 "$status"
        write_client_config failing-freerdp3 fake-freerdp3

        run_rdpconn $'y\n'
        assert_success
        assert_contains "$OUTPUT_FILE" "RDP client 'failing-freerdp3' session ended (exit status ${status})"
        assert_not_contains "$OUTPUT_FILE" "Try next client"
        assert_not_contains "$OUTPUT_FILE" "Using RDP client 'fake-freerdp3'"
        [[ ! -f $ARGV_FILE ]] || fail "Client must not be launched after session end status ${status}"
    done
}

test_runtime_client_failure_still_prompts_fallback() {
    local status
    for status in 6 7 9 10 131; do
        setup_test "${FUNCNAME[0]}_${status}"
        write_failing_client failing-freerdp3 "$status"
        write_client_config failing-freerdp3 fake-freerdp3

        run_rdpconn $'y\n'
        assert_success
        assert_contains "$OUTPUT_FILE" "RDP client 'failing-freerdp3' exited with status ${status}."
        assert_contains "$OUTPUT_FILE" "Try next client 'fake-freerdp3'? [y/N]: "
        assert_contains "$OUTPUT_FILE" "Using RDP client 'fake-freerdp3' on display mode 'x11'"
    done
}

test_prelaunch_error_does_not_prompt_fallback() {
    setup_test "${FUNCNAME[0]}"
    write_client_config unsupported-client fake-freerdp3

    run_rdpconn $'y\n'
    assert_status 1
    assert_contains "$OUTPUT_FILE" "Unsupported RDP client 'unsupported-client'"
    assert_not_contains "$OUTPUT_FILE" "Try next client"
    [[ ! -f $ARGV_FILE ]] || fail "Client must not be launched after a pre-launch validation error"
}

test_monitor_list_failure_offers_fallback() {
    setup_test "${FUNCNAME[0]}"
    cat >"$MONITOR_LIST_FILE" <<'EOF'
      * [0] 1920x1080 +1080+360
        [1] 1920x1080 +3000+360
EOF
    cat >"$BIN_DIR/broken-freerdp3" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$BIN_DIR/broken-freerdp3"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("broken-freerdp3" "fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/multimon" "/monitors:+1080+360" "/f")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn $'y\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Could not parse monitor list from 'broken-freerdp3 /list:monitor'"
    assert_contains "$OUTPUT_FILE" "RDP client 'broken-freerdp3' could not provide a monitor list."
    assert_contains "$OUTPUT_FILE" "Try next client 'fake-freerdp3'? [y/N]: "
    assert_contains "$OUTPUT_FILE" "Using RDP client 'fake-freerdp3' on display mode 'x11'"
    assert_contains "$PAYLOAD_FILE" "/monitors:0"
    assert_not_contains "$PAYLOAD_FILE" "+1080+360"
}

test_monitor_list_failure_exhausted_reports_no_clients_left() {
    setup_test "${FUNCNAME[0]}"
    cat >"$MONITOR_LIST_FILE" <<'EOF'
      * [0] 1920x1080 +1080+360
EOF
    cat >"$BIN_DIR/broken-freerdp3" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$BIN_DIR/broken-freerdp3"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("broken-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/multimon" "/monitors:+1080+360" "/f")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn ""
    assert_status 1
    assert_contains "$OUTPUT_FILE" "RDP client 'broken-freerdp3' could not provide a monitor list; no clients left to try"
    assert_not_contains "$OUTPUT_FILE" "Try next client"
}

test_monitor_matcher_errors_do_not_prompt_fallback() {
    setup_test "${FUNCNAME[0]}"
    cat >"$MONITOR_LIST_FILE" <<'EOF'
      * [0] 1920x1080 +1080+360
        [1] 1920x1080 +3000+360
EOF
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3" "xfreerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/monitors:+9999+9999")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn $'y\n'
    assert_failure
    assert_contains "$OUTPUT_FILE" "did not match any monitor"
    assert_not_contains "$OUTPUT_FILE" "Try next client"
    [[ ! -f $ARGV_FILE ]] || fail "Client must not be launched for unmatched /monitors tokens"
}

test_monitors_position_tokens_resolve() {
    setup_test "${FUNCNAME[0]}"
    cat >"$MONITOR_LIST_FILE" <<'EOF'
      * [0] 1920x1080 +1080+360
        [1] 1920x1080 +3000+360
        [2] 1080x1920 +0+0
EOF
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/multimon" "/monitors:+1080+360,+3000+360" "/f")
RDP_ARGS_WAYLAND=("/wayland-default")
RDP_ENV_FAKE_FREERDP3=("MONITOR_QUERY_MARKER=1")
EOF

    run_rdpconn
    assert_success
    assert_contains "$OUTPUT_FILE" "Resolved '/monitors:+1080+360,+3000+360' to '/monitors:0,1'"
    assert_contains "$MONITOR_CALL_FILE" "/list:monitor"
    assert_contains "$MONITOR_ENV_FILE" "MONITOR_QUERY_MARKER=1"
    assert_contains "$PAYLOAD_FILE" "/monitors:0,1"
    assert_not_contains "$PAYLOAD_FILE" "+1080+360"
}

test_monitors_name_tokens_resolve() {
    setup_test "${FUNCNAME[0]}"
    SESSION_TYPE="wayland"
    cat >"$MONITOR_LIST_FILE" <<'EOF'
listing 3 monitors:
     * [3] [Hewlett Packard HP E240] 1920x1080 +1080+360
       [4] [Samsung Electric Company SyncMaster] 1080x1920 +0+0
       [5] [AOC 2460G5] 1920x1080 +3000+360
EOF
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/monitors:name:hp e240,name:AOC 2460G5")
EOF

    # sdl-freerdp3 prints the monitor list but exits 255; resolution must still succeed.
    MONITOR_EXIT_CODE=255

    run_rdpconn
    assert_success
    assert_contains "$OUTPUT_FILE" "Resolved '/monitors:name:hp e240,name:AOC 2460G5' to '/monitors:3,5'"
    assert_contains "$PAYLOAD_FILE" "/monitors:3,5"
    assert_not_contains "$PAYLOAD_FILE" "name:"
}

test_monitors_invalid_or_unmatched_tokens_abort() {
    setup_test "${FUNCNAME[0]}_numeric"
    cat >"$MONITOR_LIST_FILE" <<'EOF'
      * [0] 1920x1080 +1080+360
        [1] 1920x1080 +3000+360
EOF
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/monitors:0,1")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "Invalid /monitors token '0'"
    [[ ! -s $MONITOR_CALL_FILE ]] || fail "Monitor list must not be queried for invalid /monitors tokens"
    [[ ! -f $ARGV_FILE ]] || fail "Client must not be launched for invalid /monitors tokens"

    setup_test "${FUNCNAME[0]}_unmatched"
    cat >"$MONITOR_LIST_FILE" <<'EOF'
      * [0] 1920x1080 +1080+360
        [1] 1920x1080 +3000+360
EOF
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/monitors:+9999+9999")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "did not match any monitor"
    assert_contains "$OUTPUT_FILE" "Available monitors:"
    assert_contains "$OUTPUT_FILE" "[0] unnamed 1920x1080 +1080+360"
    [[ ! -f $ARGV_FILE ]] || fail "Client must not be launched for unmatched /monitors tokens"
}

test_monitors_name_tokens_require_named_client() {
    setup_test "${FUNCNAME[0]}"
    cat >"$MONITOR_LIST_FILE" <<'EOF'
      * [0] 1920x1080 +1080+360
        [1] 1920x1080 +3000+360
EOF
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/monitors:name:HP E240")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "does not report monitor names"
    [[ ! -f $ARGV_FILE ]] || fail "Client must not be launched when monitor names are unavailable"
}

test_monitors_ambiguous_name_tokens_abort() {
    setup_test "${FUNCNAME[0]}"
    SESSION_TYPE="wayland"
    cat >"$MONITOR_LIST_FILE" <<'EOF'
     * [3] [Dell U2412M] 1920x1200 +0+0
       [4] [Dell U2412M] 1920x1200 +1920+0
EOF
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/monitors:name:Dell U2412M")
EOF

    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "is ambiguous and matched multiple monitors"
    assert_contains "$OUTPUT_FILE" "[3] Dell U2412M 1920x1200 +0+0"
    [[ ! -f $ARGV_FILE ]] || fail "Client must not be launched for ambiguous /monitors tokens"
}

test_monitors_negative_position_tokens_resolve() {
    setup_test "${FUNCNAME[0]}"
    cat >"$MONITOR_LIST_FILE" <<'EOF'
      * [0] 1920x1080 +0+0
        [1] 1920x1080 +-1920+0
        [2] 1920x1080 +0+-1080
EOF
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/monitors:-1920+0,+0-1080")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn
    assert_success
    assert_contains "$OUTPUT_FILE" "Resolved '/monitors:-1920+0,+0-1080' to '/monitors:1,2'"
    assert_contains "$PAYLOAD_FILE" "/monitors:1,2"
}

test_monitors_duplicate_and_multiple_args_abort() {
    setup_test "${FUNCNAME[0]}_duplicate"
    SESSION_TYPE="wayland"
    cat >"$MONITOR_LIST_FILE" <<'EOF'
     * [3] [Dell U2412M] 1920x1200 +0+0
       [4] [Hewlett Packard HP E240] 1920x1080 +1920+0
EOF
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/monitors:name:Dell U2412M,name:Dell")
EOF

    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "selects monitor '3' more than once"
    [[ ! -f $ARGV_FILE ]] || fail "Client must not be launched for duplicate /monitors tokens"

    setup_test "${FUNCNAME[0]}_multiple"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/monitors:+0+0" "/monitors:+1920+0")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn
    assert_failure
    assert_contains "$OUTPUT_FILE" "Multiple /monitors arguments are not supported"
    [[ ! -f $ARGV_FILE ]] || fail "Client must not be launched with multiple /monitors arguments"
}

test_monitors_unparsable_lines_are_reported() {
    setup_test "${FUNCNAME[0]}"
    cat >"$MONITOR_LIST_FILE" <<'EOF'
listing 2 monitors:
      * [0] 1920x1080 +0+0
        [1] Dell U2412M 1920x1080 +1920+0
EOF
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=("Test|server.example|-|-")
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/monitors:+0+0")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn
    assert_success
    assert_contains "$OUTPUT_FILE" "Warning: Ignored unrecognized monitor list line(s):"
    assert_contains "$OUTPUT_FILE" "Dell U2412M 1920x1080 +1920+0"
    assert_contains "$PAYLOAD_FILE" "/monitors:0"
}

test_bundled_fallback_config_validates() {
    setup_test "${FUNCNAME[0]}"
    rm -f "$CONFIG_HOME/rdpconn.conf"

    run_rdpconn $'1\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Loaded config from '$REPO_ROOT/rdpconn.conf'"
    assert_contains "$OUTPUT_FILE" "Using RDP client 'xfreerdp3' on display mode 'x11'"
    assert_not_contains "$OUTPUT_FILE" "Missing configuration variables"
}

test_edit_add_server_and_python_credential() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config

    run_rdpconn_edit $'a\nAdded\nadded.example\n\n-\ny\nalice:secret\nq\n'
    assert_success
    assert_contains "$CONFIG_HOME/rdpconn.conf" "'Test|server.example|-|-'"
    assert_contains "$CONFIG_HOME/rdpconn.conf" "'Added|added.example|*|-'"
    assert_contains "$KWALLET_LOG" "python-write:kdewallet:RDP:added.example:alice:secret"
    assert_contains "$OUTPUT_FILE" "Saved credential for 'added.example'"
    assert_not_contains "$KWALLET_LOG" "-r added.example"
}

test_edit_list_marks_credentials_without_reading_values() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config
    printf '%s\n' "server.example" >"$KWALLET_KEYS_FILE"

    run_rdpconn_edit $'l\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Test (server.example) credential: present"
    assert_not_contains "$KWALLET_LOG" "-r server.example"
}

test_edit_update_server_keeps_blank_fields() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config

    run_rdpconn_edit $'e\n1\nRenamed\nrenamed.example\n\npersonal-one\nq\n'
    assert_success
    assert_contains "$CONFIG_HOME/rdpconn.conf" "'Renamed|renamed.example|-|personal-one'"
    assert_not_contains "$CONFIG_HOME/rdpconn.conf" "'Test|server.example|-|-'"
}

test_edit_delete_server_and_credential() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config
    printf '%s\n' "server.example" >"$KWALLET_KEYS_FILE"

    run_rdpconn_edit $'d\n1\ny\ny\nq\n'
    assert_success
    assert_not_contains "$CONFIG_HOME/rdpconn.conf" "'Test|server.example|-|-'"
    assert_contains "$KWALLET_LOG" "remove:server.example"
}

test_edit_set_credential_bash_fallback_warns() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config
    PYTHON_DBUS_AVAILABLE=0

    run_rdpconn_edit $'c\n1\nalice:secret\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Warning: Python DBus unavailable; falling back to qdbus6. Secret may be visible in process arguments briefly."
    assert_contains "$KWALLET_LOG" "qdbus-write:server.example:alice:secret"
}

test_edit_nested_server_choice_can_back_out() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config

    run_rdpconn_edit $'e\nb\nd\nb\nc\nb\nr\nb\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "b) Back"
    assert_contains "$OUTPUT_FILE" "Cancelled"
    assert_contains "$CONFIG_HOME/rdpconn.conf" '"Test|server.example|-|-"'
    assert_not_contains "$KWALLET_LOG" "remove:server.example"
}

test_edit_nested_server_choice_can_refresh_list() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config

    run_rdpconn_edit $'c\nl\nb\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "b) Back"
    assert_not_contains "$OUTPUT_FILE" "Error: Invalid choice"
}

test_edit_rejects_fallback_config() {
    setup_test "${FUNCNAME[0]}"
    rm -f "$CONFIG_HOME/rdpconn.conf"

    run_rdpconn_edit $'q\n'
    assert_failure
    assert_contains "$OUTPUT_FILE" "Edit mode requires user config"
}

test_launch_selector_e_enters_edit_mode() {
    setup_test "${FUNCNAME[0]}"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=(
    "First|first.example|-|-"
    "Second|second.example|-|-"
)
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn $'e\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Enter 'e' to edit servers"
    assert_contains "$OUTPUT_FILE" "a) Add server"
}

test_launch_selector_edit_can_return_to_main_menu() {
    setup_test "${FUNCNAME[0]}"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=(
    "First|first.example|-|-"
    "Second|second.example|-|-"
)
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn $'e\nm\n2\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "m) Main menu"
    assert_contains "$OUTPUT_FILE" "Selected: 'Second (second.example)'"
    assert_contains "$PAYLOAD_FILE" "/v:second.example"
}

test_edit_mode_clears_on_entry() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config

    run_rdpconn_edit $'q\n'
    assert_success
    assert_contains "$CLEAR_LOG" "clear"
}

test_edit_mode_clears_after_choice() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config

    run_rdpconn_edit $'l\nq\n'
    assert_success
    assert_contains "$CLEAR_LOG" "clear"
}

test_edit_invalid_nested_choice_does_not_exit() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config

    run_rdpconn_edit $'c\nx\nb\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Error: Invalid choice"
    assert_contains "$OUTPUT_FILE" "Cancelled"
}

test_edit_reports_credential_removal_failure() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config
    printf '%s\n' "server.example" >"$KWALLET_KEYS_FILE"
    mv "$BIN_DIR/qdbus6" "$BIN_DIR/qdbus6.real"
    cat >"$BIN_DIR/qdbus6" <<'EOF'
#!/usr/bin/env bash
if [[ ${3:-} == "org.kde.KWallet.removeEntry" ]]; then
    printf 'dbus error\n' >&2
    exit 1
fi
exec "$(dirname "$0")/qdbus6.real" "$@"
EOF
    chmod +x "$BIN_DIR/qdbus6"

    run_rdpconn_edit $'d\n1\ny\ny\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Error: Failed to remove credential for 'server.example'"
    assert_not_contains "$OUTPUT_FILE" "Removed credential"
}

test_edit_survives_clear_failure() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config
    cat >"$BIN_DIR/clear" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$BIN_DIR/clear"

    run_rdpconn_edit $'l\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "a) Add server"
}

test_edit_preserves_symlinked_config() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config
    local real_config="$CURRENT_TEST_TMP/dotfiles/rdpconn.conf"
    mkdir -p "$CURRENT_TEST_TMP/dotfiles"
    mv "$CONFIG_HOME/rdpconn.conf" "$real_config"
    ln -s "$real_config" "$CONFIG_HOME/rdpconn.conf"

    run_rdpconn_edit $'a\nAdded\nadded.example\n\n-\nn\nq\n'
    assert_success
    [[ -L "$CONFIG_HOME/rdpconn.conf" ]] || fail "Config symlink was replaced by a regular file"
    assert_contains "$real_config" "'Added|added.example|*|-'"
}

test_edit_preserves_servers_block_with_parenthesis_in_comment() {
    setup_test "${FUNCNAME[0]}"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=(
    # legacy host (old)
    "Test|server.example|-|-"
)
EOF

    run_rdpconn_edit $'a\nAdded\nadded.example\n\n-\nn\nq\n'
    assert_success
    assert_contains "$CONFIG_HOME/rdpconn.conf" "'Added|added.example|*|-'"
    assert_contains "$CONFIG_HOME/rdpconn.conf" "'Test|server.example|-|-'"

    local closers
    closers=$(grep -c '^)[[:space:]]*$' "$CONFIG_HOME/rdpconn.conf" || true)
    [[ $closers -eq 1 ]] || fail "Expected exactly one SERVERS closing paren, found $closers"

    run_rdpconn_edit $'l\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Test (server.example)"
    assert_contains "$OUTPUT_FILE" "Added (added.example)"
}

test_edit_preserves_servers_block_with_parenthesis_in_name() {
    setup_test "${FUNCNAME[0]}"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=(
    "My server (test)|server.example|-|-"
    "Another|another.example|-|-"
)
EOF

    run_rdpconn_edit $'a\nAdded\nadded.example\n\n-\nn\nq\n'
    assert_success
    assert_contains "$CONFIG_HOME/rdpconn.conf" "'Added|added.example|*|-'"
    assert_contains "$CONFIG_HOME/rdpconn.conf" "'My server (test)|server.example|-|-'"
    assert_contains "$CONFIG_HOME/rdpconn.conf" "'Another|another.example|-|-'"

    local closers
    closers=$(grep -c '^)[[:space:]]*$' "$CONFIG_HOME/rdpconn.conf" || true)
    [[ $closers -eq 1 ]] || fail "Expected exactly one SERVERS closing paren, found $closers"

    run_rdpconn_edit $'l\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "My server (test) (server.example)"
    assert_contains "$OUTPUT_FILE" "Another (another.example)"
    assert_contains "$OUTPUT_FILE" "Added (added.example)"
}

test_edit_preserves_servers_entries_with_quote_and_parenthesis() {
    setup_test "${FUNCNAME[0]}_double_quoted"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=(
    "Dave's server (prod)|dave.example|-|-"
    "Other|other.example|-|-"
)
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn_edit $'a\nAdded\nadded.example\n\n-\nn\nq\n'
    assert_success
    run_rdpconn_edit $'a\nSecond\nsecond.example\n\n-\nn\nq\n'
    assert_success

    run_rdpconn_edit $'l\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Dave's server (prod) (dave.example)"
    assert_contains "$OUTPUT_FILE" "Other (other.example)"
    assert_contains "$OUTPUT_FILE" "Added (added.example)"
    assert_contains "$OUTPUT_FILE" "Second (second.example)"

    local closers
    closers=$(grep -c '^)[[:space:]]*$' "$CONFIG_HOME/rdpconn.conf" || true)
    [[ $closers -eq 1 ]] || fail "Expected exactly one SERVERS closing paren, found $closers"

    setup_test "${FUNCNAME[0]}_single_quoted"
    cat >"$CONFIG_HOME/rdpconn.conf" <<'EOF'
UP_VPNS=("unused-up")
DOWN_VPNS=("unused-down")
SERVERS=(
    'O'\''Brien (home)|obrien.example|-|-'
    "Other|other.example|-|-"
)
KWALLET="kdewallet"
KWALLET_FOLDER="RDP"
RDP_CLIENTS_X11=("fake-freerdp3")
RDP_CLIENTS_WAYLAND=("sdl-freerdp3")
RDP_ARGS_X11=("/x11-default")
RDP_ARGS_WAYLAND=("/wayland-default")
EOF

    run_rdpconn_edit $'a\nAdded\nadded.example\n\n-\nn\nq\n'
    assert_success

    run_rdpconn_edit $'l\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "O'Brien (home) (obrien.example)"
    assert_contains "$OUTPUT_FILE" "Other (other.example)"
    assert_contains "$OUTPUT_FILE" "Added (added.example)"

    closers=$(grep -c '^)[[:space:]]*$' "$CONFIG_HOME/rdpconn.conf" || true)
    [[ $closers -eq 1 ]] || fail "Expected exactly one SERVERS closing paren, found $closers"
}

test_edit_escapes_special_characters_in_server_entries() {
    setup_test "${FUNCNAME[0]}"
    write_basic_config
    local marker="$CURRENT_TEST_TMP/pwned"
    local name="Bob \"main\" \$(touch $marker) \$server"

    run_rdpconn_edit "a
$name
quoted.example

-
n
q
"
    assert_success
    [[ ! -e $marker ]] || fail "Config value was executed when sourced"

    run_rdpconn_edit $'l\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" '2) Bob "main" $(touch '
    assert_contains "$OUTPUT_FILE" '(quoted.example) credential: missing'
}

test_edit_rejects_pipe_in_vpn_fields() {
    setup_test "${FUNCNAME[0]}_update"
    write_basic_config

    run_rdpconn_edit $'e\n1\n\n\nvpn-a|vpn-b\n\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Error: UP_VPNS cannot contain '|'"
    assert_contains "$CONFIG_HOME/rdpconn.conf" '"Test|server.example|-|-"'
    assert_not_contains "$CONFIG_HOME/rdpconn.conf" "vpn-a"

    setup_test "${FUNCNAME[0]}_add"
    write_basic_config

    run_rdpconn_edit $'a\nPiped\npiped.example\n\nvpn-a|vpn-b\nq\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Error: DOWN_VPNS cannot contain '|'"
    assert_not_contains "$CONFIG_HOME/rdpconn.conf" "piped.example"
}

test_install_respects_xdg_config_home() {
    setup_test "${FUNCNAME[0]}"
    local fake_home="$CURRENT_TEST_TMP/home"
    mkdir -p "$fake_home/.config"

    (
        cd "$REPO_ROOT"
        HOME="$fake_home" XDG_CONFIG_HOME="$fake_home/.config" bash install.sh >/dev/null
    ) || fail "install.sh failed"

    [[ -x "$fake_home/.local/bin/rdpconn" ]] || fail "Expected binary at \$HOME/.local/bin/rdpconn"
    [[ -f "$fake_home/.config/rdpconn.conf" ]] || fail "Expected config at \$XDG_CONFIG_HOME/rdpconn.conf"
    [[ ! -e "$fake_home/.config/.config" ]] || fail "Config was installed under a nested .config directory"
    [[ ! -e "$fake_home/.config/.local" ]] || fail "Binary was installed under XDG_CONFIG_HOME"
}

run_test() {
    local test_name=$1

    printf '%s ... ' "$test_name"
    if "$test_name"; then
        printf 'ok\n'
    else
        printf 'failed\n' >&2
        exit 1
    fi
}

run_test test_secure_launch_hides_password_and_uses_client_args
run_test test_display_mode_and_client_selection
run_test test_client_fallback_and_no_available_client_error
run_test test_menu_selection_uses_selected_server
run_test test_vpn_defaults_and_cleanup
run_test test_cleanup_asks_before_disconnecting_org_vpn
run_test test_vpn_names_with_colon_are_matched_active
run_test test_explicit_server_vpn_lists_are_trimmed
run_test test_rdp_env_and_share_are_passed
run_test test_credential_domain_is_passed
run_test test_edit_rejects_malformed_credentials
run_test test_validation_errors
run_test test_version_flag_reports_version_without_config
run_test test_credential_errors
run_test test_launch_rejections
run_test test_runtime_fallback_confirmed_uses_next_client
run_test test_runtime_fallback_declined_exits_with_status
run_test test_runtime_fallback_bare_enter_stops
run_test test_runtime_fallback_eof_stops
run_test test_runtime_fallback_exhausts_all_clients
run_test test_runtime_fallback_skips_missing_binary
run_test test_runtime_session_end_does_not_prompt_fallback
run_test test_runtime_client_failure_still_prompts_fallback
run_test test_prelaunch_error_does_not_prompt_fallback
run_test test_monitor_list_failure_offers_fallback
run_test test_monitor_list_failure_exhausted_reports_no_clients_left
run_test test_monitor_matcher_errors_do_not_prompt_fallback
run_test test_monitors_position_tokens_resolve
run_test test_monitors_name_tokens_resolve
run_test test_monitors_negative_position_tokens_resolve
run_test test_monitors_invalid_or_unmatched_tokens_abort
run_test test_monitors_duplicate_and_multiple_args_abort
run_test test_monitors_unparsable_lines_are_reported
run_test test_monitors_name_tokens_require_named_client
run_test test_monitors_ambiguous_name_tokens_abort
run_test test_bundled_fallback_config_validates
run_test test_edit_add_server_and_python_credential
run_test test_edit_list_marks_credentials_without_reading_values
run_test test_edit_update_server_keeps_blank_fields
run_test test_edit_delete_server_and_credential
run_test test_edit_set_credential_bash_fallback_warns
run_test test_edit_nested_server_choice_can_back_out
run_test test_edit_nested_server_choice_can_refresh_list
run_test test_edit_rejects_fallback_config
run_test test_launch_selector_e_enters_edit_mode
run_test test_launch_selector_edit_can_return_to_main_menu
run_test test_edit_mode_clears_on_entry
run_test test_edit_mode_clears_after_choice
run_test test_edit_invalid_nested_choice_does_not_exit
run_test test_edit_rejects_pipe_in_vpn_fields
run_test test_edit_escapes_special_characters_in_server_entries
run_test test_edit_preserves_servers_block_with_parenthesis_in_comment
run_test test_edit_preserves_servers_block_with_parenthesis_in_name
run_test test_edit_preserves_servers_entries_with_quote_and_parenthesis
run_test test_edit_preserves_symlinked_config
run_test test_edit_survives_clear_failure
run_test test_edit_reports_credential_removal_failure
run_test test_install_respects_xdg_config_home

printf 'rdpconn test suite passed\n'
