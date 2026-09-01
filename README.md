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

## Before you start

This plugin is a front-end. It needs the official **Synology Drive Client**
installed, linked to your NAS and running — it does no syncing of its own.

1. **Install the client from the AUR.** Either package works; both ship the
   same vendor binaries under `/opt/Synology/SynologyDrive`:

   ```bash
   yay -S synology-drive              # 4.2.x, the maintained one
   yay -S synology-drive-client-bin   # 4.0.3 — what this plugin was developed and tested against
   ```

   Synology Drive Server must be installed on the NAS (Package Center).

2. **Run it once and link it.** Launch *Synology Drive Client* from the app
   menu (or `synology-drive start`). The wizard asks for the NAS address,
   user and password — a Tailscale hostname is fine — then creates your
   first sync task (which shares to which local folders, two-way or
   one-way). Do this in the client; the plugin only reads the result.

3. **Autostart is the client's own.** First run writes
   `~/.config/autostart/synology-drive-autostart.desktop`, so it comes back
   at every login. The client only ships the `xcb` Qt platform plugin, so
   it runs under XWayland — that is normal and nothing to fix.

Once `synology-drive` is linked you never need its tray icon again; that is
the part this plugin replaces.

## Install

No setup, no root:

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

**Left-click** opens the panel. **Right-click** pauses or resumes all
syncing. **Middle-click** forces a refresh. From a hotkey:

```bash
omarchy-shell shell toggle dansmith888.synology-drive
omarchy-shell dansmith888.synology-drive pause     # or resume
```

**The panel** shows, top to bottom:

- who you are linked as, the overall state, and a pause/resume-all button;
- **Now** — the file being transferred, its direction and size, and what is
  queued behind it (only while something is moving);
- **Sync folders** — each task with its local path and state; click to open
  the folder, or use its pause/resume button;
- **Problems** — files the client refused to sync, with the reason (only when
  there are any; temporaries excluded by the client's own filter are not
  problems and are not listed);
- **Log** — the client's sync history, newest first, scrolling. Filter to
  downloads or uploads. Click an entry to select that file in Files; entries
  whose file is gone are dimmed;
- **Settings** (folded) — the client's options as it has them, read-only:
  startup, notifications, overlay, per-task direction and filter rules;
- **Open Synology Drive** for everything else.

Keys while open: `p` pause/resume all, `r` refresh, `o` open the client,
`s` fold/unfold settings, arrows scroll the log, `Esc` closes.

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
- **Pause / resume** talk to the sync daemon over its local socket
  (`~/.SynologyDrive/daemon.sock`) with the very request the client's own
  Pause button sends — `{"action": "pause", "session_id_list": [...]}` in
  Synology's PStream encoding — and confirm it from the daemon log. Per
  task or all at once. Everything about that channel is in
  [PROTOCOL.md](PROTOCOL.md).
- Nothing else is written: no client setting, nothing under the sync folders.

## Requirements

- Omarchy (Quattro or later) on Arch
- Synology Drive Client 4.x for Linux from the AUR — tested with
  `synology-drive-client-bin` 4.0.3-17892; 4.2.x should work but its log
  lines have not been checked (see Limitations)
- Synology Drive Server on the NAS, and the client linked to it
- Nautilus for "show in Files" (falls back to `xdg-open` on the folder)

## Command line

```
syndctl get [--json]              connection, sync folders, activity, state
syndctl log [-n N] [--json]       sync history, newest first
syndctl unsynced [--json]         files the client refused to sync
syndctl settings [--json]         the client's options, read-only
syndctl pause [<session-id>...]   pause syncing (all tasks, or the given ones)
syndctl resume [<session-id>...]  resume syncing
syndctl show                      raise the client's own window
syndctl open [<session-id>]       open a sync folder in the file manager
syndctl reveal <path>             select a file in the file manager
syndctl ipc <action> [k=v ...]    raw request to the daemon (see PROTOCOL.md)
syndctl doctor                    check every link from the client to the bar
```

## Limitations

Things the plugin deliberately does not do, and things it cannot know:

- **Settings are read-only.** Sync tasks, filters, selective sync,
  bandwidth, proxy, notifications and linking are changed in the client's
  own window ("Open Synology Drive"). The panel shows the current values so
  you rarely need to open it.
- **Pause is not persisted by the client.** It lives in the sync daemon's
  memory, so a client restart or reboot resumes syncing — same as the
  native button.
- **The native app's own status lags behind pauses made from the bar.** Its
  tray tooltip and window only reflect pauses it performed itself; the
  daemon (which the plugin reads) is right, and the app catches up on its
  next own action. Pauses made *in* the app — by task or by connection —
  show up in the plugin within one poll.
- **Pending counts and the "now" row come from the daemon's log**, cross-
  checked with the daemon's own event count. They are accurate to the poll
  interval (4 s while syncing) and cannot show per-file progress or speed:
  the daemon logs a transfer's start and end, not its bytes.
- **No quota, no server-side view.** The plugin never talks to the NAS. What
  is shared with you, versions, storage usage — that is the client or DSM.
- **One client version verified.** The daemon log format (`PushEvent`,
  `DoneEvent`, "pool is now empty", "Pause session N by … id") is what the
  live state is parsed from. It has been stable across Drive releases for
  years and `tests/test_syndctl.py` pins the exact shapes, so a change shows
  up as a failing test rather than a silently blank pill — but 4.2.x has not
  been run against it yet. Connection, tasks, history and settings come
  from SQLite and are unaffected.
- **Linux client only.** On-demand sync, the Windows/macOS file-provider
  modes and backup tasks are not modelled; a backup task will show up as a
  sync folder with its own status.
- **Don't use `synology-drive pause`/`resume` from the launcher.** On 4.0.3
  `pause` sends a `reload_session` that rewrites a per-task option
  (`sync_mode`) and pauses nothing; `resume` is a no-op. The plugin never
  calls them; it uses the daemon's own socket ([PROTOCOL.md](PROTOCOL.md)).
- The daemon acknowledges every request, valid or not; the plugin therefore
  treats the daemon's own log line as the confirmation and says "sent
  (daemon has not logged it yet)" when it does not appear within a few
  seconds.
- Polling: every 6 s idle, 4 s while syncing, 3 s with the panel open, and
  on hovering the pill. Each poll is one short Python process (~130 ms).

### Hyprland tips for the client's own windows

Not the plugin's business, but you will hit them the first time you open a
task's Sync Rules. The client is XWayland, so Qt places its dialogs
relative to where it *thinks* the parent window is, which is nowhere near
where Hyprland put it. In `~/.config/hypr/hyprland.lua`:

```lua
-- Centre the main window and every dialog (they all float).
o.window({ class = "^cloud-drive-ui$", title = "^[A-Z]" }, { center = true })

-- Qt re-positions a dialog after mapping; centre it again once it has.
hl.on("window.open", function(win)
  if win.class ~= "cloud-drive-ui" or not tostring(win.title):match("^%u") then return end
  local selector = "address:" .. (tostring(win.address):gsub("^address:", ""))
  hl.timer(function()
    local w = hl.get_window(selector)
    if not w or not w.mapped or not w.floating then return end
    hl.dispatch(hl.dsp.focus({ window = selector }))
    hl.dispatch(hl.dsp.window.center())
  end, { timeout = 200, type = "oneshot" })
end)
```

If you still want the client's tray popup for anything, keep it reachable
with `o.window({ class = "^cloud-drive-ui$", title = "^(cloud-drive-ui)?$", float = true }, { stay_focused = true, move = { "(monitor_w-window_w-20)", "(36)" } })`
— matched on the popup's title, not on `float`, or every dialog gets
pinned under the tray icon with the mouse "stuck".

## What runs, and as whom

Omarchy plugins run inside the shell process, unsandboxed, as your user.
This one runs two Python scripts from its own `bin/` — standard library
only, no extra packages, no binaries, no network, nothing that needs root.
It opens the client's databases read-only, reads its log, sends pause /
resume / event-count requests to the daemon's local Unix socket, and writes
nothing outside its folder except a lock file in `$XDG_RUNTIME_DIR`. The
only things it ever executes besides itself are `synology-drive show`,
`nautilus --select` and `xdg-open`.

## Hacking on it

```bash
git clone https://github.com/DanSmith888/omarchy-synology-drive.git ~/Work/omarchy-synology-drive
cd ~/Work/omarchy-synology-drive
python3 tests/test_syndctl.py                 # log-line shapes + PStream bytes, offline
omarchy plugin validate .
# Copy (never symlink — the validator rejects symlinks) into the plugins
# dir; the shell hot-reloads on save, restart it when Panel.qml changes.
rsync -a --delete --exclude .git --exclude tests --exclude __pycache__ ./ ~/.config/omarchy/plugins/dansmith888.synology-drive/
omarchy restart shell
bin/syndctl doctor
```

Poke the daemon safely while tailing its log:

```bash
tail -F ~/.SynologyDrive/log/daemon.log | grep -vE 'rescan-handler|barrier.cpp'
bin/syndctl ipc get_event_count session_id=1
```

## Protocol

[PROTOCOL.md](PROTOCOL.md) documents the client's local IPC as observed:
the sockets, Synology's PStream encoding, the known actions and log
markers, and what to re-check after a client upgrade.

## Related

- [m1guelpf/sproto](https://github.com/m1guelpf/sproto) — a Rust client for
  the client↔NAS sync protocol; its PStream notes made the local socket
  legible.
- [zbjdonald/synology-drive-api](https://github.com/zbjdonald/synology-drive-api)
  — the DSM-side REST API (list/upload/download/share), if you want to talk
  to the NAS rather than the client.

## Credits

Built for and with Daniel's setup — an Arch/Omarchy workstation syncing
two shares from a DiskStation over Tailscale. Synology Drive is a trademark
of Synology Inc.; this project is not affiliated with Synology.

## Licence

MIT — see [LICENSE](LICENSE).
