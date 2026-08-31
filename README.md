# Synology Drive

Synology Drive Client status in the [Omarchy](https://omarchy.org/) bar —
what's syncing, what failed, the sync log — without the Qt tray icon.

The official Synology Drive Client for Linux syncs well and looks dreadful
under Hyprland: an XWayland Qt5 tray icon whose popups die on hover. This
plugin leaves the client doing the syncing and replaces only the part you
look at. It reads the state the client already keeps on disk (its SQLite
databases and daemon log under `~/.SynologyDrive`), so there is nothing to
configure, no credentials, and no traffic to the NAS.

![Bar](docs/bar.png)
![Panel](docs/panel.png)

## Install

No setup, no root. The Synology Drive Client must be installed and linked
(`synology-drive-client-bin` or `synology-drive` from the AUR).

```bash
omarchy plugin add https://github.com/DanSmith888/omarchy-synology-drive.git --enable
```

### Hide the old tray icon

Once the pill is up, hide the client's own tray item. Right-click it in the
Omarchy tray and choose hide, or add it to the tray's hidden list in
`~/.config/omarchy/shell.json`:

```json
{ "id": "omarchy.tray", "hidden": ["cloud-drive-ui"] }
```

The client keeps running; only its icon goes.

### Check it

```bash
~/.config/omarchy/plugins/dansmith888.synology-drive/bin/syndctl doctor
```

Verifies every link from the client to the bar and tells you how to fix
whatever is broken. Put `bin/` on your `PATH` if you want `syndctl` as a
command.

## Update

```bash
omarchy plugin update dansmith888.synology-drive && omarchy restart shell
```

## Remove

```bash
omarchy plugin remove dansmith888.synology-drive
```

That removes everything. The plugin never touches anything outside its own
folder and a lock file in `$XDG_RUNTIME_DIR`.

## Using it

**The pill** is a cloud glyph that only says something when there is
something to know:

| Pill | Meaning |
|------|---------|
| 󰅠 | Up to date |
| 󰘿 3 | Syncing — 3 files pending; the glyph alternates with ↓/↑ for the current file |
| 󰅟 Paused | Paused in the client |
| 󰅤 Offline | The NAS can't be reached; the client is retrying |
| 󰧠 Error | A connection or task error — see the panel |
| 󰅤 | Client not running / not linked |

**Left-click** opens the panel. **Right-click** raises the Synology Drive
window. **Middle-click** forces a refresh. To open the panel from a hotkey:

```bash
omarchy-shell shell toggle dansmith888.synology-drive
```

**The panel** shows, top to bottom:

- who you are linked as and the overall state;
- **Now** — the file being transferred, its direction and size, and what is
  queued behind it (only while something is moving);
- **Sync folders** — each task with its local path and state; click to open
  the folder;
- **Problems** — files the client refused to sync, with the reason (only when
  there are any; temporaries excluded by the client's own filter are not
  problems and are not listed);
- **Log** — the client's sync history, newest first, scrolling. Filter to
  downloads or uploads. Click an entry to select that file in Files; entries
  whose file is gone are dimmed;
- **Settings** (folded) — the client's options as it has them, read-only:
  startup, notifications, overlay, per-task direction and filter rules;
- **Open Synology Drive** for everything else.

Keys while open: `r` refresh, `o` open the client, `s` fold/unfold settings,
arrows scroll the log, `Esc` closes.

### Settings

In the Omarchy bar editor (or `shell.json`):

- `hideWhenIdle` (off) — hide the pill entirely while everything is up to date.
- `logCount` (40) — how many log entries the panel keeps.

## What it does

- **State** comes from `~/.SynologyDrive/data/db/sys.sqlite` (connection,
  sync tasks) and a tail of `~/.SynologyDrive/log/daemon.log` (what is
  queued, what is moving, pause/offline markers). The daemon narrates every
  transfer as `PushEvent` / `PullEvent` / `DoneEvent` and announces an idle
  folder with "event pool is now empty", which is exactly what the tray
  icon reacts to.
- **History and problems** come from `history.sqlite`, the same table the
  client's Logs page shows.
- **Control** is limited to raising the client's window and opening folders
  or files. See below for why.

## Requirements

- Omarchy (Quattro or later)
- Synology Drive Client 4.x for Linux (tested with 4.0.3-17892), linked to
  a NAS
- Nautilus for "show in Files" (falls back to `xdg-open` on the folder)

## Command line

```
syndctl get [--json]              connection, sync folders, activity, state
syndctl log [-n N] [--json]       sync history, newest first
syndctl unsynced [--json]         files the client refused to sync
syndctl settings [--json]         the client's options, read-only
syndctl show                      raise the client's own window
syndctl open [<session-id>]       open a sync folder in the file manager
syndctl reveal <path>             select a file in the file manager
syndctl doctor                    check every link from the client to the bar
```

## Good to know

- **There is no pause button, on purpose.** The client's launcher accepts
  `synology-drive pause` / `resume`, and they are not what they look like:
  on 4.0.3 `pause` sent a `reload_session` with `sync_mode: 1` to the daemon
  (a persisted per-task option), did not pause anything, and `resume` did
  nothing at all. Until there is a documented way to pause from outside, use
  the Pause button in the client window (right-click the pill).
- "Pending" counts come from the daemon log, not a live query, so they are
  accurate to the poll interval (4 s while syncing) and can miss files that
  were queued before the current log file started. The daemon rotates its
  log at 5 MB; the plugin reads the newest rotated file too when the live
  one is young.
- The plugin polls: every 15 s idle, 4 s while syncing, 3 s while the panel
  is open. Each poll is one short Python process (~130 ms).
- If the client is not running the pill shows a struck-through cloud and
  the footer button starts it.

## What runs, and as whom

Omarchy plugins run inside the shell process, unsandboxed, as your user.
This one runs two Python scripts from its own `bin/` — standard library
only, no extra packages, no binaries, no network, nothing that needs root.
It opens the client's databases read-only, reads its log, and writes
nothing outside its folder except a lock file in `$XDG_RUNTIME_DIR`. The
only things it ever executes besides itself are `synology-drive show`,
`nautilus --select` and `xdg-open`.

## Licence

MIT — see [LICENSE](LICENSE).
