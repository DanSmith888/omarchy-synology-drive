# Synology Drive Control

Synology Drive Client status in the [Omarchy](https://omarchy.org/) bar:
what is syncing, what failed, the sync log, pause and resume. No Qt tray icon.

The official Linux client syncs well but its XWayland tray icon is unusable
under Hyprland. This plugin leaves the client doing the syncing and replaces
the part you look at. It reads the client's own SQLite databases and daemon
log under `~/.SynologyDrive`, so there is nothing to configure, no
credentials, and no traffic to the NAS.

![Bar](docs/bar.png)
![Panel](docs/panel.png)

## Before you start

The plugin is a front-end and needs manual setup first: the official
Synology Drive Client must be installed, linked to your NAS, and running.
The plugin never installs anything itself.

1. Install the client from the AUR:

   ```bash
   yay -S synology-drive              # 4.2.x
   yay -S synology-drive-client-bin   # 4.0.3, the version this was tested with
   ```

   The NAS needs Synology Drive Server from Package Center.

2. Launch *Synology Drive Client* once and complete the wizard: NAS address
   (a Tailscale hostname works), user, password, then your first sync task.

3. The client writes its own autostart entry
   (`~/.config/autostart/synology-drive-autostart.desktop`). It runs under
   XWayland because it only ships the `xcb` Qt plugin; that is normal.

## Install

```bash
omarchy plugin add https://github.com/DanSmith888/omarchy-synology-drive.git --enable
```

Then hide the client's tray item: right-click it in the Omarchy tray, or add
`"hidden": ["cloud-drive-ui"]` to the `omarchy.tray` entry in
`~/.config/omarchy/shell.json`. The client keeps running.

### Check it

```bash
~/.config/omarchy/plugins/dansmith888.synology-drive/bin/syndctl doctor
```

## Update

```bash
omarchy plugin update dansmith888.synology-drive && omarchy restart shell
```

## Remove

```bash
omarchy plugin remove dansmith888.synology-drive
```

Nothing is left behind except a lock file in `$XDG_RUNTIME_DIR`.

## Using it

| Pill | Meaning |
|------|---------|
| 󰅠 | Up to date |
| 󰘿 3 | Syncing, 3 files pending (glyph alternates with the transfer direction) |
| 󰅟 Paused | Paused |
| 󰅤 Offline | NAS unreachable, client retrying |
| 󰧠 Error | Connection or task error, see the panel |
| 󰅤 | Client not running or not linked |

Left-click opens the panel. Right-click pauses or resumes everything.
Middle-click or hover refreshes.

```bash
omarchy-shell shell toggle dansmith888.synology-drive
omarchy-shell dansmith888.synology-drive pause     # or resume
```

The panel shows the link and overall state with a pause/resume button;
**Now**, the file in flight and the queue; **Sync folders**, each task with
its own pause button (click to open the folder); **Problems**, files the
client refused; **Log**, the sync history with download/upload filters
(click an entry to select the file in Files); **Settings**, the client's
options, read-only; and a button for the client's own window.

Keys: `p` pause/resume, `r` refresh, `o` open the client, `s` settings,
arrows scroll the log, `Esc` closes.

Settings (bar editor or `shell.json`): `hideWhenIdle` (off) hides the pill
while up to date; `logCount` (40) is the number of log entries kept.

## How it works

- Connection and sync tasks: `~/.SynologyDrive/data/db/sys.sqlite`.
- History and problems: `history.sqlite`, the client's own Logs table.
- Live state: a tail of `daemon.log`. The daemon logs `PushEvent`,
  `PullEvent` and `DoneEvent` per file, "event pool is now empty" when a
  task is idle, and "Pause session N" markers.
- Pause and resume: the same request the client's Pause button sends, over
  the daemon's local socket. See [PROTOCOL.md](PROTOCOL.md).
- Nothing is written: no client setting, nothing in the sync folders.

## Requirements

- Omarchy (Quattro or later)
- Synology Drive Client 4.x from the AUR, linked to a NAS running Synology
  Drive Server. Tested with 4.0.3-17892; 4.2.x is untested.
- Nautilus for "select in Files" (falls back to `xdg-open`)

## Command line

```
syndctl get [--json]              state, tasks, activity
syndctl log [-n N] [--json]       history, newest first
syndctl unsynced [--json]         files the client refused to sync
syndctl settings [--json]         the client's options, read-only
syndctl pause [<id>...]           pause all tasks, or the given ones
syndctl resume [<id>...]          resume
syndctl show                      raise the client's window
syndctl open [<id>]               open a sync folder
syndctl reveal <path>             select a file in the file manager
syndctl ipc <action> [k=v ...]    raw daemon request (PROTOCOL.md)
syndctl doctor                    check every link from client to bar
```

## Limitations

- Settings are read-only. Change tasks, filters, bandwidth, proxy and
  linking in the client's window.
- Pause is not persisted by the client; a restart or reboot resumes.
- The client's own tray and window do not notice pauses made from the bar
  until you next act in the client. The daemon is correct either way.
- Pending counts come from the daemon log plus its event count. No per-file
  progress or speed; the daemon logs start and end, not bytes.
- No quota or server-side view; the plugin never talks to the NAS.
- One client version verified. The log line shapes are pinned in
  `tests/test_syndctl.py`, so a format change fails a test instead of
  silently blanking the pill.
- Backup tasks and on-demand sync are not modelled.
- The launcher's `synology-drive pause` verb is not used: on 4.0.3 it
  rewrites a task option (`sync_mode`) and pauses nothing.
- Polling: 6 s idle, 4 s while syncing, 3 s with the panel open, plus on
  hover. Each poll is one short Python process (about 130 ms).

### Hyprland tips for the client's windows

The client is XWayland, so Qt places dialogs relative to where it thinks
the parent is. In `~/.config/hypr/hyprland.lua`:

```lua
-- Centre the main window and dialogs.
o.window({ class = "^cloud-drive-ui$", title = "^[A-Z]" }, { center = true })

-- Qt moves a dialog again after mapping; centre it once more.
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

If you keep the client's tray popup, match it by title, not by `float`,
or every dialog gets pinned under the tray icon:
`o.window({ class = "^cloud-drive-ui$", title = "^(cloud-drive-ui)?$", float = true }, { stay_focused = true, move = { "(monitor_w-window_w-20)", "(36)" } })`.

## What runs, and as whom

Omarchy plugins run inside the shell process, unsandboxed, as your user.
This one runs two standard-library Python scripts from its own `bin/`: no
packages, no binaries, no network, no root. It reads the client's databases
read-only and its log, sends pause/resume/event-count requests to the
daemon's local Unix socket, and writes nothing outside its folder except a
lock file in `$XDG_RUNTIME_DIR`. It executes only `synology-drive show`,
`nautilus --select` and `xdg-open`.

## Hacking on it

```bash
python3 tests/test_syndctl.py      # log-line shapes and PStream bytes, offline
omarchy plugin validate .
rsync -a --delete --exclude .git --exclude tests --exclude __pycache__ ./ ~/.config/omarchy/plugins/dansmith888.synology-drive/
omarchy restart shell              # needed when Panel.qml changes
bin/syndctl doctor
tail -F ~/.SynologyDrive/log/daemon.log | grep -vE 'rescan-handler|barrier.cpp'
```

Never symlink the repo into the plugins dir; the validator rejects symlinks.

## Related

- [m1guelpf/sproto](https://github.com/m1guelpf/sproto): Rust client for the
  client-to-NAS sync protocol; its PStream notes decoded the local socket.
- [zbjdonald/synology-drive-api](https://github.com/zbjdonald/synology-drive-api):
  the DSM REST API, for talking to the NAS rather than the client.

## Credits

I built this for my own setup: an Arch/Omarchy workstation syncing two
shares from a DiskStation over Tailscale. Synology Drive is a trademark of
Synology Inc.; this project is not affiliated with Synology.

## Licence

MIT, see [LICENSE](LICENSE).
