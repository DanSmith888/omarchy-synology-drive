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
- `bin/synologydrivestatus` — one JSON line for the QML; `{}` = nothing to show.
- `bin/synologydrivectl` — CLI: `get [--json]`, `doctor`, action verbs. Holds
  `PLUGIN_ID` / `REPO_URL` (keep in sync with the manifest).
- `docs/SUBMISSION-DRAFT.md` — marketplace issue body (unsubmitted).

## Dev loop

```bash
omarchy plugin validate . && ~/.claude/skills/omarchy-plugin-dev/scripts/lint.sh
rsync -a --delete --exclude .git ./ ~/.config/omarchy/plugins/dansmith888.synology-drive/
omarchy-shell shell toggle dansmith888.synology-drive '{}'
qs log -p "$OMARCHY_PATH/shell" --tail 100
bin/synologydrivectl doctor
```

## Rules

- Keep in sync on release: `manifest.version`, git tag `vX.Y.Z`,
  `moduleName` in every QML, `PLUGIN_ID`/`REPO_URL` in `bin/synologydrivectl`,
  README commands.
- stdlib Python only in `bin/`; no root, no network; locks in
  `$XDG_RUNTIME_DIR`.
- Never edit `/usr/share/omarchy/**`.
- No `git push`, tag push, or marketplace submission unless Daniel says so.

## Gotchas

- TODO: plugin-specific things the next session must know.
