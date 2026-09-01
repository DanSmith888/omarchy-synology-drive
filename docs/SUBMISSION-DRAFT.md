<!--
Marketplace submission for https://plugins.omarchy.org — unsubmitted draft.
Before submitting: push the repo and tag, strip this comment, then:

  gh issue create --repo HANCORE-linux/omarchy-plugin-marketplace \
    --title "[Plugin]: Synology Drive Control" --body-file docs/SUBMISSION-DRAFT.md

Categories: Appearance, Desktop, Developer Tools, Hardware, Productivity,
System, Widgets, Other. Tags (1-3): AI, Bar, Games, Hyprland, Launcher,
Media, Power management, Quickshell, Security, System, Workspaces.
-->

### Repository URL

https://github.com/DanSmith888/omarchy-synology-drive.git

### Category

System

### Tags

Bar, Quickshell, System

### Suggest a missing tag

_No response_

### Maintainer notes

A bar front-end for the official Synology Drive Client for Linux; it does no
syncing itself. **Depends on the AUR package `synology-drive` (or
`synology-drive-client-bin`)** being installed, linked to a NAS running
Synology Drive Server, and running — the README's "Before you start" walks
through it. Tested against 4.0.3-17892.

Standard-library Python only, no external binaries, no network, no root.
Reads the client's own SQLite databases (read-only) and daemon log under
`~/.SynologyDrive`; never writes client settings. Pause/resume are sent to
the daemon's local Unix socket in the client's own request format
(documented in PROTOCOL.md). Executes only `synology-drive show`,
`nautilus --select` and `xdg-open`. Writes nothing outside its own folder
and a lock file in `$XDG_RUNTIME_DIR`; `omarchy plugin remove` is a clean
uninstall.

Known limits are listed in the README: settings are read-only (change them
in the client), pause is not persisted by the client, the client's own
tray lags behind pauses made from the bar, and live counts are parsed from
the daemon log (pinned by tests).

### Submission checklist

- [x] The repository is public and includes install and removal instructions
- [x] The license and any external dependencies are documented
- [x] I own or have permission to publish the plugin and preview assets
- [x] The plugin does not overwrite user configuration without explicit consent
- [x] I understand approval is for listing only and is not a security review
