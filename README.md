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
