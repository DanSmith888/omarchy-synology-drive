# Synology Drive — Omarchy plugin

Synology Drive Client sync status and controls in the bar

Read the `omarchy-plugin-dev` skill first; it holds the conventions. This
file holds only what is specific to this repo.

## Identity

- id / IPC target / `moduleName`: `dansmith888.synology-drive`
- repo: `https://github.com/DanSmith888/omarchy-synology-drive.git`
- installed copy: `~/.config/omarchy/plugins/dansmith888.synology-drive`
- kind: `bar-widget`, entry point `BarWidget.qml`

## Map

- `manifest.json` — the contract; bump `version` on release.
- `BarWidget.qml` — entry point. Owns the pill and the single IpcHandler; forwards open/close/opened to Panel.qml, which owns all state.
- `bin/syndstatus` — one JSON line for the QML; `{}` = nothing to show.
- `bin/syndctl` — CLI: `get/log/unsynced/settings [--json]`, `show`, `open`,
  `reveal`, `doctor`. Holds `PLUGIN_ID` / `REPO_URL` (keep in sync with the
  manifest). `parse_log()` is the heart: daemon.log tail → queue/current/
  paused/offline.
- `tests/test_syndctl.py` — offline parser tests from real log shapes;
  `python3 tests/test_syndctl.py`.
- `docs/SUBMISSION-DRAFT.md` — marketplace issue body (unsubmitted).

## Dev loop

```bash
omarchy plugin validate . && ~/.claude/skills/omarchy-plugin-dev/scripts/lint.sh
rsync -a --delete --exclude .git ./ ~/.config/omarchy/plugins/dansmith888.synology-drive/
omarchy-shell shell toggle dansmith888.synology-drive '{}'
qs log -p "$OMARCHY_PATH/shell" --tail 100
bin/syndctl doctor
```

## Rules

- Keep in sync on release: `manifest.version`, git tag `vX.Y.Z`,
  `moduleName` in every QML, `PLUGIN_ID`/`REPO_URL` in `bin/syndctl`,
  README commands.
- stdlib Python only in `bin/`; no root, no network; locks in
  `$XDG_RUNTIME_DIR`.
- Never edit `/usr/share/omarchy/**`.
- No `git push`, tag push, or marketplace submission unless Daniel says so.

## Gotchas

- **Do not add pause/resume via `synology-drive pause|resume`.** Tested
  2026-08-31 on client 4.0.3-17892: `pause` made the UI send
  `reload_session` with `sync_mode: 1` for every task (a persisted option in
  `sys.sqlite system_table` and per-session), did *not* pause, and `resume`
  was a no-op. Daniel's client still has `sync_mode=1` from that test until
  he resets it in the client window. A real control path needs either the
  daemon.sock protocol (protobuf; `get_status`/`pause_session` exist in the
  binary) or the tray's dbusmenu, which only exposes About/Exit until Qt
  populates it on click.
- The `status` verb does not print — it *opens* the client's main window.
- The daemon echoes its JSON notifications (`{"notify": "syncing_file", …}`)
  into `daemon.log` only when the tray UI is *not* connected ("is not
  sent"); with the UI running you get only the INFO narration the parser
  uses. Both shapes are in `tests/test_syndctl.py`.
- The client ships only the `xcb` Qt platform plugin: anything that runs
  `synology-drive …` needs `DISPLAY` (Hyprland exports `:0`) and
  `QT_QPA_PLATFORM=xcb`, which `syndctl` sets.
- `history_table.action`: 40 = downloaded, 24 = uploaded, 34/17 = excluded
  by filter (`not_synced_reason -8192`). Mapped from observed rows; the
  binaries hold no enum names for them.
- `grim` blocks forever while the display is DPMS-off; screenshots of the
  panel need the monitor awake.
- Ground truth for the tray state without any parsing:
  `busctl --user get-property org.kde.StatusNotifierItem-<pid>-1 /StatusNotifierItem org.kde.StatusNotifierItem ToolTip`
  → `"Synology Drive Client 4.0.3\nUp-to-date"`. Not used yet (needs the
  UI pid); a good cross-check for `doctor`.
- Shell IPC arity: `omarchy-shell shell toggle <id> '{}'` and
  `summon <id> '{}'`, but `hide <id>` takes only the id and there is no
  `show`; wrong arity prints the function signature and does nothing.
- `omarchy plugin remove <id>` needs `--yes` when stdin is not a TTY.
- Checklist pass 2026-09-01: click/Esc/summon/hide/toggle, reopen after
  close, border vs `omarchy.tailscale`, disable→enable→restart,
  remove→zero residue→reinstall — all verified by screenshot.
- Screenshot geometry: `grim -g` takes logical px; the display is 5120×2160
  at scale 1.25. The panel opens at roughly `3286,28 412x572`.
