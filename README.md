This project is released under the Unlicense. See LICENSE for details.

# rdpconn

`rdpconn` disconnects configured personal VPNs, connects to your organisation VPNs, pulls credentials from KWallet, and launches your configured RDP client with your preferred options.

## Installation

From the repository root run:

```bash
./install.sh
```

This copies the script to `${XDG_CONFIG_HOME:-$HOME}/.local/bin/rdpconn` and installs the default configuration at `${XDG_CONFIG_HOME:-$HOME}/.config/rdpconn.conf`.

## Configuration

Edit `${XDG_CONFIG_HOME:-$HOME}/.config/rdpconn.conf`. The file shipped with the project contains example values; copy it to your config directory if it is missing.

Key settings:

- `UP_VPNS`: global array of VPN connection IDs to bring up.
- `DOWN_VPNS`: global array of VPN connection IDs to bring down.
- `SERVERS`: list of entries in `NAME|URL|UP_VPNS|DOWN_VPNS` format (lists are comma-separated). Use `*` to apply the global arrays and `-` for none. The menu shows `NAME (URL)`.
- `KWALLET`, `KWALLET_FOLDER`: wallet and folder that store an entry keyed by `${URL}` with `username:password`.
- `RDP_CLIENTS_X11`, `RDP_CLIENTS_WAYLAND`: ordered lists of FreeRDP frontends to try for each session type. `RDP_CLIENTS` is no longer supported.
- `RDP_ARGS_X11`, `RDP_ARGS_WAYLAND`: argument sets selected automatically based on `XDG_SESSION_TYPE` (`x11` vs `wayland`). Use these to pick different monitor sets per display system.
- `RDP_SHARE` (optional): local path to expose via `/drive:rdp-share`; omit to disable drive sharing.
- `RDP_ARGS_<CLIENT>` (optional): per-client overrides. The variable name is the client name uppercased, with non-alphanumerics replaced by `_`. When set, it replaces the display-specific args for that client.
- `RDP_ENV_<CLIENT>` (optional): per-client environment variables, e.g., `RDP_ENV_SDL_FREERDP3=("SDL_VIDEODRIVER=wayland")`.

After editing the config, run `rdpconn`. The script will apply the VPN changes, fetch credentials, and open the RDP session. Passwords are passed to supported FreeRDP clients through a private file descriptor instead of the process command line. When the RDP client exits, your previous VPN state is restored automatically.

If you are migrating an older config, rename `RDP_CLIENTS` to `RDP_CLIENTS_X11` and add a separate `RDP_CLIENTS_WAYLAND` list.

## Editing Servers and Credentials

Run:

```bash
rdpconn edit
```

The edit menu can add, edit, delete, and list server entries, plus set or remove matching KWallet credentials. Server edits update the `SERVERS` array in your user config at `${XDG_CONFIG_HOME:-$HOME/.config}/rdpconn.conf`; the fallback config shipped with the project is not edited.

Credential entries are stored in the configured `KWALLET` and `KWALLET_FOLDER`, keyed by the server URL. Values must use `username:password` format. Edit mode checks credential presence by key only and does not read stored secret values.

Credential writes use Python DBus by default so the secret is not passed as a command-line argument. If Python DBus is unavailable, edit mode falls back to `qdbus6` and prints a warning because that path may briefly expose the secret in process arguments.

## Wayland multi-monitor tips

- Multi-monitor only engages in fullscreen; include `/f` with `/multimon` and your `/monitors:<ids>` selection (avoid `/span`).
- On Wayland compositors, X11 clients run via XWayland; if multi-monitor is unstable, limit to a single monitor in `RDP_ARGS_WAYLAND`.
- Use display-specific args to pick different monitor sets per session type, e.g., `RDP_ARGS_X11=( "/multimon" "/monitors:0,1" "/f" ...)` and `RDP_ARGS_WAYLAND=( "/monitors:0" "/f" ...)`.
