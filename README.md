This project is released under the Unlicense. See LICENSE for details.

# rdpconn

`rdpconn` disconnects any configured personal VPN, connects to your organisation VPN, pulls credentials from KWallet, and launches `xfreerdp3` with your preferred options.

## Installation

From the repository root run:

```bash
./install.sh
```

This copies the script to `${XDG_CONFIG_HOME:-$HOME}/.local/bin/rdpconn` and installs the default configuration at `${XDG_CONFIG_HOME:-$HOME}/.config/rdpconn.conf`.

## Configuration

Edit `${XDG_CONFIG_HOME:-$HOME}/.config/rdpconn.conf`. The file shipped with the project contains example values; copy it to your config directory if it is missing.

Key settings:

- `PERS_VPNS`: array of personal VPN connection IDs to disconnect before launching RDP.
- `ORG_VPN`: connection ID for the organisation VPN that must be up during the session.
- `SERVERS`: list of RDP hosts; a menu appears when multiple entries exist.
- `KWALLET`, `KWALLET_FOLDER`: wallet and folder that store `${SERVER}_username` / `${SERVER}_password` secrets.
- `RDP_ARGS`: base arguments passed to `xfreerdp3`.
- `RDP_SHARE` (optional): local path to expose via `/drive:rdp-share`; omit to disable drive sharing.

After editing the config, run `rdpconn`. The script will apply the VPN changes, fetch credentials, and open the RDP session. When `xfreerdp3` exits, your previous VPN state is restored automatically.
