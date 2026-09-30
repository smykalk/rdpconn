# rdpconn

`rdpconn` disconnects active personal VPNs, connects organisation VPNs, reads RDP credentials from KWallet, and launches a FreeRDP client. On exit it restores the VPN state it changed.

## Requirements

- Linux.
- Bash 4.4 or later (the script uses `${var@Q}`).
- NetworkManager with `nmcli`. VPN changes are implemented only through NetworkManager; a missing `nmcli` fails any server entry with a non-empty VPN list.
- KDE KWallet 6: the `kwalletd6` service and the `kwallet-query` CLI are required to read credentials. No other secret store is supported.
- A FreeRDP frontend in `PATH` whose name ends in `freerdp` or `freerdp<digits>`, for example `xfreerdp3` or `sdl-freerdp3`. Other clients abort at launch.
- `qdbus6` for credential management in `rdpconn edit`. `python3` with the `dbus` module is optional; when present it is preferred for writes because the secret is not passed as a process argument.

## Installation

From the repository root:

```bash
./install.sh
```

This copies `rdpconn.sh` to `~/.local/bin/rdpconn` and `rdpconn.conf` to `${XDG_CONFIG_HOME:-$HOME/.config}/rdpconn.conf`; an existing config is left untouched. `~/.local/bin` must be on `PATH`.

## Usage

```bash
rdpconn        # pick a server and start a session
rdpconn edit   # manage servers and credentials
rdpconn --version
```

With one server configured it is selected automatically. Otherwise a numbered menu is shown; `e` opens edit mode, and `m` there returns to server selection (`q` quits `rdpconn`).

`rdpconn --version` prints `RDPCONN_VERSION` from `rdpconn.sh`; bump the constant when tagging a release.

## Configuration

`${XDG_CONFIG_HOME:-$HOME/.config}/rdpconn.conf` is sourced as Bash. If it does not exist, `rdpconn.conf` next to the script is used (when running from the repository, the shipped fallback config). All variables below must be defined even when unused, except where marked optional.

- `SERVERS`: array of `NAME|URL|UP_VPNS|DOWN_VPNS` entries. `NAME` and `URL` must be non-empty and must not contain `|`. `UP_VPNS`/`DOWN_VPNS` are `*` (use the global array), `-` or empty (no VPNs), or a comma-separated list of NetworkManager connection names/UUIDs. The selection menu shows `NAME (URL)`.
- `UP_VPNS`, `DOWN_VPNS`: global arrays referenced by `*`.
- `KWALLET`, `KWALLET_FOLDER`: wallet and folder containing one entry per server, keyed by `URL`.
- `RDP_CLIENTS_X11`, `RDP_CLIENTS_WAYLAND`: ordered client lists. Only the list for the current session type is required, and it must be non-empty. `XDG_SESSION_TYPE=wayland` (case-insensitive) selects the Wayland list; anything else selects X11. Clients whose binary is missing from `PATH` are skipped. `RDP_CLIENTS` is rejected.
- `RDP_ARGS_X11`, `RDP_ARGS_WAYLAND`: client arguments per session type. Empty arrays are allowed, but both variables must exist.
- `RDP_ARGS_<CLIENT>` (optional): replaces the session-type arguments for one client. The variable name is the client name uppercased with every character outside `A-Z0-9` replaced by `_`: `sdl-freerdp3` → `RDP_ARGS_SDL_FREERDP3`.
- `RDP_ENV_<CLIENT>` (optional): array of `VAR=value` entries exported when the client is run or queried for monitors.
- `RDP_SHARE` (optional): directory shared as `/drive:rdp-share`, created if missing.

`rdpconn` always appends `/v:<URL> /u:<username> /p:<password> /d:` (empty domain). Arguments are passed through `/args-from:fd:`, so neither the password nor the other options appear in the process command line. An argument containing a newline aborts the launch. Options that `rdpconn` adds itself cannot be overridden.

### Monitor matchers

`/monitors:` accepts matchers instead of numeric IDs, in X11 and Wayland sessions alike:

- `name:<substring>`: case-insensitive substring of a monitor name; the client must report names (e.g. `sdl-freerdp3`).
- `+<x>+<y>` or `-<x>+<y>`: exact desktop position, e.g. `+1080+360` or `-1920+0`.

`rdpconn` runs `<client> /list:monitor`, rewrites the argument to the client's current numeric IDs, and keeps monitor selections valid across replugs and compositor restarts. It aborts on unmatched or ambiguous matchers (printing the available monitors), duplicate monitor selections, or more than one `/monitors:` argument. Unparsable monitor-list lines are reported as warnings. `/multimon` only engages with `/f`; do not combine it with `/span`.

## Credentials

Each server `URL` maps to a KWallet entry whose value is `username:password`. The value is split at the first colon, and both parts must be non-empty; otherwise the credential counts as missing and the launch aborts.

Reads use `kwallet-query`. `rdpconn edit` writes prefer Python DBus (`python3` plus the `dbus` module) and fall back to `qdbus6`, which prints a warning because the secret may briefly appear in process arguments. Presence checks and removals always use `qdbus6`; without it, the edit-mode server list reports every credential as `missing`.

## Editing servers

`rdpconn edit` requires the user config to exist, so run `./install.sh` first. It can add, edit, delete, and list servers, and set or remove credentials.

- Add: blank VPN fields become `*`.
- Edit: empty input keeps the current value; duplicate URLs and `|` in any field are rejected.
- Delete: confirms first, then asks whether to remove the matching credential.
- Only the `SERVERS=(...)` block in the user config is rewritten; the rest of the file, including comments, is preserved. A symlinked config is followed and the target file is rewritten.

## Failure handling and VPN cleanup

- If no configured client is available in `PATH`, the launch fails.
- A client that exits non-zero or cannot produce a usable monitor list is a runtime failure: `rdpconn` prints the reason and asks `Try next client '<next>'? [y/N]`. Only an explicit `y` tries the next client; anything else, or closed stdin, exits with the failed client's status.
- Errors before launch, such as an unsupported client name, invalid arguments, unresolvable monitor matchers, or credential problems, abort without prompting.
- On exit, including on SIGINT/SIGTERM, `rdpconn` asks `Disconnect from org VPN '<name>'? [Y/n]` before disconnecting each organisation VPN it connected; `n` keeps it connected. Personal VPNs are reconnected only when every started org VPN was disconnected — if any is kept, they stay down. With closed stdin (no way to ask) it disconnects and reconnects as before. VPNs it did not change are left alone, and cleanup failures are warnings.

## Wayland notes

- Multi-monitor requires fullscreen (`/f`).
- X11 clients run through XWayland on Wayland; if multi-monitor is unstable, restrict `RDP_ARGS_WAYLAND` to a single monitor.

### SDL client shortcuts

`sdl-freerdp3` handles a few shortcuts itself, so they keep working with a fullscreen multi-monitor session. The modifier is Right Shift by default:

| Shortcut | Action |
| --- | --- |
| `RightShift+M` | Minimize all client windows |
| `RightShift+Enter` | Toggle fullscreen |
| `RightShift+R` | Toggle resizable state |
| `RightShift+G` | Toggle keyboard grab |
| `RightShift+D` | Disconnect the session |

`RightShift+G` toggles the keyboard grab: while it is on, the client inhibits compositor shortcuts and sends key combinations such as `Meta+D` or `Meta+Ctrl+Left/Right` to the remote. A session starts ungrabbed.

The modifier and keys can be changed in `${XDG_CONFIG_HOME:-$HOME/.config}/freerdp/sdl-freerdp.json` (create the file if it does not exist; `sdl-freerdp3 /help` lists all settings):

```json
{
    "SDL_KeyModMask": ["KMOD_CTRL", "KMOD_ALT"],
    "SDL_Minimize": "M",
    "SDL_Fullscreen": "RETURN"
}
```

`SDL_KeyModMask` is an array of SDL_Keymod names (`KMOD_CTRL`, `KMOD_ALT`, `KMOD_RSHIFT`, ...) and the key settings take SDL scancode names (`M`, `RETURN`, `R`, `G`, `D`). An invalid name disables all client shortcuts.

## Tests

```bash
./tests/rdpconn_test.sh
```

The suite stubs `nmcli`, `kwallet-query`, and the RDP clients, so it needs no VPN, wallet, or desktop session.

## License

Released under the Unlicense. See `LICENSE`.
