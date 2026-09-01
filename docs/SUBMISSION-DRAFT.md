<!--
Marketplace submission for https://omarchyplugins.com — unsubmitted draft.
Before submitting: push the repo and tag, strip this comment, then:

  gh issue create --repo HANCORE-linux/omarchy-plugin-marketplace \
    --title "[Plugin]: Synology Drive" --body-file docs/SUBMISSION-DRAFT.md

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

Standard-library Python only, no external binaries, no network, no root.
Writes nothing outside its own folder and a lock file in `$XDG_RUNTIME_DIR`.
Reads the Synology Drive Client's own SQLite databases (read-only) and log
under `~/.SynologyDrive`; never writes client settings. Pause/resume are sent to the daemon's local
Unix socket in the client's own request format (documented in PROTOCOL.md).
Requires the official client to be installed and linked. Executes only
`synology-drive show`, `nautilus --select` and `xdg-open`.

### Submission checklist

- [x] The repository is public and includes install and removal instructions
- [x] The license and any external dependencies are documented
- [x] I own or have permission to publish the plugin and preview assets
- [x] The plugin does not overwrite user configuration without explicit consent
- [x] I understand approval is for listing only and is not a security review
