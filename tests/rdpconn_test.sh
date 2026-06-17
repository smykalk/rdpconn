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
RDP_STATUS=0
RDP_PID=""
SESSION_TYPE="x11"
ACTIVE_CONNECTIONS=""
KWALLET_SECRET="alice:super-secret"
KWALLET_FAIL=0
CLIENT_SLEEP=0

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

if [[ ${1:-} == "-t" && ${2:-} == "-f" && ${3:-} == "NAME" && ${4:-} == "connection" && ${5:-} == "show" && ${6:-} == "--active" ]]; then
    printf '%s\n' "show-active" >>"$log"
    active_csv=${RDP_TEST_ACTIVE_CONNECTIONS-}
    if [[ -n $active_csv ]]; then
        IFS=',' read -r -a active_connections <<<"$active_csv"
        printf '%s\n' "${active_connections[@]}"
    fi
    exit 0
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

printf '%s' "${RDP_TEST_KWALLET_SECRET-alice:super-secret}"
EOF

    cat >"$BIN_DIR/fake-freerdp3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

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

    chmod +x "$BIN_DIR/nmcli" "$BIN_DIR/kwallet-query" "$BIN_DIR/fake-freerdp3" "$BIN_DIR/xfreerdp3" "$BIN_DIR/sdl-freerdp3" "$BIN_DIR/unsupported-client"
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
    RDP_STATUS=0
    RDP_PID=""
    SESSION_TYPE="x11"
    ACTIVE_CONNECTIONS=""
    KWALLET_SECRET="alice:super-secret"
    KWALLET_FAIL=0
    CLIENT_SLEEP=0

    mkdir -p "$BIN_DIR" "$CONFIG_HOME"
    : >"$NMCLI_LOG"
    : >"$KWALLET_LOG"
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
            RDP_TEST_KWALLET_SECRET="$KWALLET_SECRET" \
            RDP_TEST_KWALLET_FAIL="$KWALLET_FAIL" \
            RDP_TEST_PID_FILE="$PID_FILE" \
            RDP_TEST_ARGV_FILE="$ARGV_FILE" \
            RDP_TEST_ENV_FILE="$ENV_FILE" \
            RDP_TEST_FD_PAYLOAD_FILE="$PAYLOAD_FILE" \
            RDP_TEST_CLIENT_SLEEP="$CLIENT_SLEEP" \
            "$REPO_ROOT/rdpconn.sh" >"$OUTPUT_FILE" 2>&1
    else
        env \
            PATH="$BIN_DIR:$PATH" \
            XDG_CONFIG_HOME="$CONFIG_HOME" \
            XDG_SESSION_TYPE="$SESSION_TYPE" \
            RDP_TEST_ACTIVE_CONNECTIONS="$ACTIVE_CONNECTIONS" \
            RDP_TEST_NMCLI_LOG="$NMCLI_LOG" \
            RDP_TEST_KWALLET_LOG="$KWALLET_LOG" \
            RDP_TEST_KWALLET_SECRET="$KWALLET_SECRET" \
            RDP_TEST_KWALLET_FAIL="$KWALLET_FAIL" \
            RDP_TEST_PID_FILE="$PID_FILE" \
            RDP_TEST_ARGV_FILE="$ARGV_FILE" \
            RDP_TEST_ENV_FILE="$ENV_FILE" \
            RDP_TEST_FD_PAYLOAD_FILE="$PAYLOAD_FILE" \
            RDP_TEST_CLIENT_SLEEP="$CLIENT_SLEEP" \
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
        RDP_TEST_KWALLET_SECRET="$KWALLET_SECRET" \
        RDP_TEST_KWALLET_FAIL="$KWALLET_FAIL" \
        RDP_TEST_PID_FILE="$PID_FILE" \
        RDP_TEST_ARGV_FILE="$ARGV_FILE" \
        RDP_TEST_ENV_FILE="$ENV_FILE" \
        RDP_TEST_FD_PAYLOAD_FILE="$PAYLOAD_FILE" \
        RDP_TEST_CLIENT_SLEEP="$CLIENT_SLEEP" \
        "$REPO_ROOT/rdpconn.sh" >"$OUTPUT_FILE" 2>&1 &
    RDP_PID=$!
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

    run_rdpconn
    assert_success
    assert_contains "$NMCLI_LOG" "down:personal-active"
    assert_contains "$NMCLI_LOG" "up:org-inactive"
    assert_contains "$NMCLI_LOG" "down:org-inactive"
    assert_contains "$NMCLI_LOG" "up:personal-active"
    assert_not_contains "$NMCLI_LOG" "down:personal-inactive"
    assert_not_contains "$NMCLI_LOG" "up:org-active"
    assert_not_contains "$NMCLI_LOG" "down:org-active"
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

    run_rdpconn
    assert_success
    assert_contains "$NMCLI_LOG" "up:org-one"
    assert_contains "$NMCLI_LOG" "up:org-two"
    assert_contains "$NMCLI_LOG" "down:personal-one"
    assert_not_contains "$NMCLI_LOG" "up:global-org"
    assert_not_contains "$NMCLI_LOG" "down:global-personal"
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
    assert_contains "$OUTPUT_FILE" "must be in 'username:password' format"

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

test_bundled_fallback_config_validates() {
    setup_test "${FUNCNAME[0]}"
    rm -f "$CONFIG_HOME/rdpconn.conf"

    run_rdpconn $'1\n'
    assert_success
    assert_contains "$OUTPUT_FILE" "Loaded config from '$REPO_ROOT/rdpconn.conf'"
    assert_contains "$OUTPUT_FILE" "Using RDP client 'xfreerdp3' on display mode 'x11'"
    assert_not_contains "$OUTPUT_FILE" "Missing configuration variables"
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
run_test test_explicit_server_vpn_lists_are_trimmed
run_test test_rdp_env_and_share_are_passed
run_test test_validation_errors
run_test test_credential_errors
run_test test_launch_rejections
run_test test_bundled_fallback_config_validates

printf 'rdpconn test suite passed\n'
