# SxPilot

A GTK4 / libadwaita application, written in Vala, for organizing remote
servers into groups and opening SSH and SFTP sessions in tabs. Several
connections can stay open at the same time.

## Features

- Groups of connections (create, rename, delete, collapse), plus an
  "Ungrouped" section
- SSH and SFTP sessions in tabs (VTE terminal running the system `ssh` /
  `sftp`), with reconnect, duplicate tab and "open SFTP for this server"
- Authentication with the SSH agent / default keys, a key file, or a password
- Passwords are stored in the Secret Service (GNOME Keyring, KWallet…),
  never in the config file
- Jump host (`-J`), SFTP initial directory and arbitrary extra `ssh` options
- Quick connect (`[user@]host[:port]`) without saving
- Search in the sidebar, confirmation before closing live sessions
- Light/dark terminal palette following the system style, configurable font
  and scrollback
- Server monitoring: status dot in the sidebar and a monitor tab with CPU,
  memory, load and disk usage (see below)

## Monitoring

Enable "Monitor Server" in a connection to keep a background SSH session
that samples the server every few seconds (Preferences → Update Interval).
"Show Monitor" in a connection's menu opens the live view, also for
connections that are not monitored in the background.

Nothing is installed on the server: SxPilot sends a small `sh` loop that
reads `/proc` and `df`, so only Linux servers are supported. The session
never prompts, so it needs the SSH agent, a key without passphrase or a
password saved in the keyring. Port forwardings from the connection's extra
options or `~/.ssh/config` are disabled for it. After an authentication or
host key error it doesn't retry by itself, to avoid triggering fail2ban;
when the server is unreachable it retries with increasing delays.

### Alerts

Preferences → Alerts sets these rules, which apply to every monitored server:

- server unreachable
- CPU, memory and disk usage above a percentage
- how many minutes a condition must last before it alerts (to ignore
  spikes)

Extensions can add their own rules. When an alert fires, SxPilot sends a
desktop notification. It sends another when the alert clears, and clicking
either opens the server's monitor. Active alerts also show as an orange dot
in the sidebar, a warning icon on the monitor tab and a list at the top of
it. You can turn alerts off per connection.

### Extensions

Extensions add service metrics to the monitor. SxPilot ships extensions for
Nginx, Apache, MySQL/MariaDB, PostgreSQL and Redis/Valkey. You enable them,
and set their parameters, in each connection. The connection dialog shows
the exact command each one runs on the server.

An extension is a JSON file. Files in `~/.local/share/sxpilot/extensions/`
replace bundled ones with the same `id`. In the Flatpak, that folder is
`~/.var/app/io.github.agustingv.sxpilot/data/sxpilot/extensions/`.
Preferences → Monitoring Extensions opens it and reloads the files.

```json
{
  "id": "nginx",
  "name": "Nginx",
  "description": "Connections and requests from the stub_status page",
  "hint": "Shown when the command fails: how to set up the server",
  "params": [
    { "key": "status_url", "label": "Status URL", "default": "http://127.0.0.1/nginx_status" }
  ],
  "command": "curl -fsS --max-time 5 ${status_url}",
  "parser": { "type": "regex", "patterns": { "active": "Active connections:\\s*(\\d+)" } },
  "metrics": [
    { "key": "active", "label": "Active connections", "chart": true }
  ]
}
```

- `detect` (optional) runs once when the monitoring session starts. If it
  exits with 0, the monitor tab suggests enabling the extension. You can
  enable the suggestion (after seeing the command) or dismiss it. The bundled
  extensions look for the service's process in `/proc/*/comm`.
- `command` runs with `sh -c` on the server on every sample, under
  `timeout 10` when available. `${key}` is replaced by the parameter's value,
  shell-quoted, so a value is always a single argument.
- `parser.type`:
  - `keyvalue` (`Key: value` lines, `separator` defaults to `:`)
  - `table` (whitespace-separated columns, `key_column` and `value_column`
    default to 0 and 1)
  - `regex` (`patterns` maps each key to a regex whose first group is the
    value)
  - `json` (nested keys joined with dots, e.g. `a.b.0`)
- Metric options:
  - `format`: `number` (default), `percent`, `bytes`, `kib`, `duration`
    (seconds) or `text`
  - `unit`: text shown after a number
  - `rate`: shows a counter's change per second
  - `chart`: draws its history
  - `alert`: e.g. `{"above": 0, "message": "Redis is rejecting
    connections"}` (or `below`). It is compared with the value shown, so with
    the per-second value when `rate` is set.

The commands run as the SSH user. Give services their credentials on the
server, e.g. in `~/.my.cnf` or `~/.pgpass`, never in the command.

## Translations

SxPilot is translated with gettext. The catalogs are in `po/`, and the app
currently ships a Spanish translation (`po/es.po`). After changing
user-visible strings:

```sh
python3 po/extension-strings.py     # only if a bundled extension changed
ninja -C build sxpilot-pot          # regenerate po/sxpilot.pot
ninja -C build sxpilot-update-po    # merge it into every po/*.po
```

To add a language, add its code to `po/LINGUAS` and create the file with
`msginit -i po/sxpilot.pot -l <code> -o po/<code>.po`.

## Building

Dependencies (Debian/Ubuntu package names):

```sh
sudo apt install valac meson ninja-build libgtk-4-dev libadwaita-1-dev \
    libvte-2.91-gtk4-dev libjson-glib-dev libsecret-1-dev openssh-client
```

Build and run without installing:

```sh
meson setup build
ninja -C build
meson devenv -C build ./src/sxpilot
```

Install:

```sh
meson setup build --prefix=/usr/local
ninja -C build install
```

### Flatpak

The manifest uses the GNOME 51 runtime and builds VTE as an extra module,
because the GNOME runtime doesn't include it:

```sh
flatpak install flathub org.gnome.Sdk//51 org.gnome.Platform//51
flatpak-builder --user --install --force-clean _flatpak io.github.agustingv.sxpilot.yml
flatpak run io.github.agustingv.sxpilot
```

The sandbox has network access, the host SSH agent socket and `~/.ssh`
(for keys, `config` and `known_hosts`). Inside the Flatpak, connections are
stored in `~/.var/app/io.github.agustingv.sxpilot/config/sxpilot/` instead of
`~/.config/sxpilot/`.

Run the validation tests (desktop file, metainfo, GSettings schema) with
`meson test -C build`.

## How password login works

When a connection uses password authentication and a password is saved,
SxPilot launches `ssh` with `SSH_ASKPASS` pointing to the bundled
`sxpilot-askpass` helper and `SSH_ASKPASS_REQUIRE=force`. The helper reads the
password directly from the keyring using the connection id, so the password
never appears in the command line or the environment. Other prompts (host key
confirmation, key passphrases, one-time codes) are shown in a small dialog.

Without a saved password, `ssh` simply asks in the terminal.

## Data

Connections and groups are stored in
`~/.config/sxpilot/connections.json` (mode 0600).

## Keyboard shortcuts

Plain `Ctrl+<key>` combinations are passed to the remote shell, so the
application shortcuts use `Ctrl+Shift`.

| Shortcut | Action |
| --- | --- |
| `Ctrl+Shift+O` | New connection |
| `Ctrl+Shift+G` | New group |
| `Ctrl+Shift+K` | Quick connect |
| `Ctrl+Shift+F` | Search connections |
| `Ctrl+Shift+T` | Duplicate current tab |
| `Ctrl+Shift+S` | Open SFTP session for the current server |
| `Ctrl+Shift+W` | Close tab |
| `Ctrl+Shift+C` / `Ctrl+Shift+V` | Copy / paste |
| `Ctrl+Shift+A` | Select all |
| `Ctrl++` / `Ctrl+-` / `Ctrl+0` | Zoom in / out / reset |
| `Ctrl+PgUp` / `Ctrl+PgDn` | Previous / next tab |
| `Ctrl+Shift+N` | New window |
| `Ctrl+,` | Preferences |
| `F9` | Toggle sidebar |
| `Ctrl+Shift+Q` | Quit |

## License

GPL-3.0-or-later
