# Synology Drive Client — local daemon IPC

What `bin/syndctl` speaks to pause and resume syncing, and how it was found.
Everything below was observed on Synology Drive Client **4.0.3-17892** for
Linux (Arch, `synology-drive-client-bin`) on 2026-09-01. Nothing here is
documented by Synology; treat a client upgrade as a reason to re-run the
checks at the bottom.

## Processes and sockets

| Process | Role | Endpoint |
|---|---|---|
| `cloud-drive-daemon serve …/client.conf` | the sync engine | **listens** on `~/.SynologyDrive/daemon.sock` (`socket_path` in `client.conf`) |
| `cloud-drive-ui` | tray icon + settings window | listens on `~/.SynologyDrive/ui.sock`; the daemon *connects* to it to push notifications |
| `cloud-drive-connect` | QuickConnect/relay helper | `127.0.0.1:<punchd_port>` |

The UI talks to the daemon over `daemon.sock`. That is the only channel the
plugin uses for control.

## Wire format: PStream

The same serialisation Synology uses between client and NAS (see
[`m1guelpf/sproto`](https://github.com/m1guelpf/sproto), `src/pstream`),
minus the NAS-side header. On `daemon.sock` each request is **one bare
PStream object, no length prefix**, and the daemon closes the connection
after replying.

| Type | Encoding |
|---|---|
| null | `00 00` |
| integer | `01` `<size 1\|2\|4\|8>` big-endian value, minimum width |
| string | `10` `<u16 be length>` UTF-8 bytes |
| binary | `30` `<u32 be length>` bytes |
| array | `41` items… `40` |
| map | `42` (string-key value)… `40` |

Booleans are integers 0/1. Keys are plain strings (the NAS protocol strips a
leading `_`; not needed here).

Worked example — the request the client's own **Pause** button sends for
task 2, and the reply:

```
→ 42                                  map
    10 0006 "action"  10 0005 "pause"
    10 000f "session_id_list"  41 01 01 02 40
  40
← 42 10 0003 "ack" 10 0002 "ok" 40     {"ack": "ok"}
```

`bin/syndctl` implements this in `ps_encode` / `ps_decode` / `daemon_call`;
`tests/test_syndctl.py` pins the bytes.

## Reply semantics

- Every request is answered with a map containing `"ack": "ok"`, **before**
  it is parsed. Garbage, an empty object and unknown actions are all acked.
- An unknown action is logged by the daemon as
  `daemon-impl.cpp(2602): <<< Unknown IPC action: <name>` and otherwise
  ignored.
- A wrong *encoding* (anything whose first byte is not a PStream tag) is
  logged as `main.cpp(298): Failed to recieve message from channel.` and the
  connection is dropped without a reply.
- Some actions add fields to the ack (`get_event_count` → `event_count`).
  Pause/resume add nothing; confirmation comes from the daemon log.

## Known actions

Confirmed by sending them and reading the daemon's reaction:

| Request | Effect | Daemon log |
|---|---|---|
| `{"action":"pause","session_id_list":[N,…]}` | pause those sync tasks | `daemon-impl.cpp(2154): Pause session N by session id.` then `remove N worker process` |
| `{"action":"resume","session_id_list":[N,…]}` | resume them | `daemon-impl.cpp(2255): Resume session N by session id.` then `add N worker process` |
| `{"action":"pause","connection_id_list":[C]}` (sent by the client when the NAS entry is selected; not exercised by the plugin) | pause every task on that connection | `daemon-impl.cpp(2166): Pause session N by connection id.` per task |
| `{"action":"get_event_count","session_id":N}` | pending event count | — (reply `{"ack":"ok","event_count":K}`) |

Seen in the log as sent by the UI, not exercised by the plugin:
`add_session`, `reload_session`, `remove_session` — each logged with its full
request as `Action '<name>': … info={json}`. `reload_session` carries
`conflict_policy`, `rename_conflict`, `session_id`, `sync_mode`; the
launcher's `synology-drive pause` verb sends exactly this (with
`sync_mode: 1`) and is **not** a pause — which is why `syndctl` never uses
the launcher for control.

Names present in the binary next to the ones above, untested:
`reload_connection`, `unlink_connection`, `add_event`, `dump_event`,
`add_watch_session`, `remove_watch_session`, `get_file_id`, `lock_file`,
`abort_bkp_event`. Names that looked promising but are **not** IPC actions
(logged as unknown): `get_session_status`, `get_worker_status`,
`get_statistics`, `get_current_connection_status`, `get_server_info`,
`get_quota`, `pause_session`, `resume_session`.

Status vocabulary in the same string cluster — likely the payload the daemon
pushes to the UI over `ui.sock`, not yet captured: `uptodate`, `syncing`,
`disconnected`, `uploading`, `downloading`, `total_size`,
`unfinished_files`, `unfinished_locked_files`, `snapshot_event_count`,
`syncer_event_count`, `snapshot_status`, `session_list`, `connection_list`,
`worker_list`, `other_status_type`.

## Pause state is not persisted

Pausing changes nothing in `sys.sqlite`, the per-session `event-db.sqlite`
or any file under `~/.SynologyDrive` — it lives in the daemon's memory and
is visible only through the two log lines above. A daemon restart therefore
un-pauses. `syndctl get` derives `paused` / `paused_sessions` from those
lines (per session, reset when the daemon pid in the log prefix changes).
`WorkerManager: pause all worker` / `resume all worker` also appear on every
session reload and mean nothing on their own.

## The UI does not follow external changes

`cloud-drive-ui` keeps its own pause state and only updates it for actions
it initiated. After a `pause`/`resume` sent by anything else (this plugin)
its tray tooltip and window keep showing the previous state until the user
acts in the app. Observed 2026-09-01: app pauses by connection → plugin
resumes → daemon logs `Resume session N by session id` and syncs, tooltip
still says "Paused". The daemon is authoritative; read it, not the UI.

## Research tooling

```
syndctl ipc <action> [key=value …] [--json]   # values parsed as JSON when possible
syndctl ipc get_event_count session_id=1
syndctl ipc pause session_id_list='[2]'       # same as: syndctl pause 2
```

Watch the daemon while probing:

```
tail -F ~/.SynologyDrive/log/daemon.log | grep -vE 'rescan-handler|barrier.cpp'
```

## Re-checks after a client upgrade

1. `syndctl doctor` — the "Daemon IPC answers" line sends `get_event_count`.
2. `syndctl pause 2 && sleep 3 && syndctl resume 2` — both should print
   "…d task 2" (confirmed by log line), not "sent (daemon has not logged it yet)".
3. `python3 tests/test_syndctl.py` — log-line shapes and codec bytes.
