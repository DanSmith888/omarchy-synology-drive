# Synology Drive Client: local daemon IPC

How `bin/syndctl` pauses and resumes syncing. Observed on Synology Drive
Client 4.0.3-17892 for Linux on 2026-09-01. None of this is documented by
Synology; re-run the checks at the bottom after a client upgrade.

## Processes and sockets

| Process | Role | Endpoint |
|---|---|---|
| `cloud-drive-daemon serve .../client.conf` | sync engine | listens on `~/.SynologyDrive/daemon.sock` |
| `cloud-drive-ui` | tray icon and settings window | listens on `ui.sock`; the daemon connects to it to push notifications |
| `cloud-drive-connect` | QuickConnect/relay helper | `127.0.0.1:<punchd_port>` |

The plugin uses `daemon.sock` only.

## Wire format: PStream

Synology's own serialisation, the same one used between client and NAS
(see [sproto](https://github.com/m1guelpf/sproto), `src/pstream`), without
the NAS header. Each request is one bare PStream object with no length
prefix. The daemon replies and closes the connection.

| Type | Encoding |
|---|---|
| null | `00 00` |
| integer | `01` size (1, 2, 4 or 8) then big-endian value |
| string | `10` u16 big-endian length, UTF-8 bytes |
| binary | `30` u32 big-endian length, bytes |
| array | `41` items `40` |
| map | `42` (string key, value)* `40` |

Booleans are integers 0 or 1.

The request the client's Pause button sends for task 2, and the reply:

```
-> 42  10 0006 "action" 10 0005 "pause"  10 000f "session_id_list" 41 01 01 02 40  40
<- 42  10 0003 "ack" 10 0002 "ok"  40
```

`ps_encode`, `ps_decode` and `daemon_call` in `bin/syndctl` implement this;
`tests/test_syndctl.py` pins the bytes.

## Reply semantics

- Every request gets `{"ack": "ok"}` before it is parsed, including garbage
  and unknown actions.
- Unknown actions are logged as
  `daemon-impl.cpp(2602): <<< Unknown IPC action: <name>` and ignored.
- A payload that does not start with a PStream tag is logged as
  `main.cpp(298): Failed to recieve message from channel.` and dropped.
- Some actions add fields to the ack (`get_event_count` adds
  `event_count`). Pause and resume add nothing; confirm from the log.

## Known actions

| Request | Effect | Daemon log |
|---|---|---|
| `{"action":"pause","session_id_list":[N]}` | pause tasks | `Pause session N by session id.` then `remove N worker process` |
| `{"action":"resume","session_id_list":[N]}` | resume tasks | `Resume session N by session id.` then `add N worker process` |
| `{"action":"pause","connection_id_list":[C]}` | pause every task on a connection (sent by the client when the NAS entry is selected) | `Pause session N by connection id.` per task |
| `{"action":"get_event_count","session_id":N}` | pending event count | none; reply carries `event_count` |

Sent by the UI, seen in the log, not used by the plugin: `add_session`,
`reload_session`, `remove_session`, each logged with its request as
`Action '<name>': ... info={json}`. The launcher's `synology-drive pause`
verb sends `reload_session` with `sync_mode: 1`, which is not a pause.

Present in the binary, untested: `reload_connection`, `unlink_connection`,
`add_event`, `dump_event`, `add_watch_session`, `remove_watch_session`,
`get_file_id`, `lock_file`, `abort_bkp_event`.

Not IPC actions (logged as unknown): `get_session_status`,
`get_worker_status`, `get_statistics`, `get_current_connection_status`,
`get_server_info`, `get_quota`, `pause_session`, `resume_session`.

Status words from the same string cluster, probably the daemon-to-UI
payload on `ui.sock`, not captured: `uptodate`, `syncing`, `disconnected`,
`uploading`, `downloading`, `total_size`, `unfinished_files`,
`session_list`, `worker_list`.

## Pause state

Pausing writes nothing to disk. It lives in the daemon's memory and shows
only in the log lines above, so a daemon restart un-pauses. `syndctl`
derives `paused_sessions` from those lines, per session, and resets when
the daemon pid in the log prefix changes. `WorkerManager: pause all worker`
and `resume all worker` also appear on every session reload and mean
nothing on their own.

`cloud-drive-ui` keeps its own pause state and only updates it for actions
it initiated. After a pause or resume from the plugin its tooltip and
window are stale until the user acts in the client. The daemon is
authoritative.

## Research tooling

```
syndctl ipc get_event_count session_id=1
syndctl ipc pause session_id_list='[2]'      # same as: syndctl pause 2
tail -F ~/.SynologyDrive/log/daemon.log | grep -vE 'rescan-handler|barrier.cpp'
```

## Re-checks after a client upgrade

1. `syndctl doctor`: the "Daemon IPC answers" line sends `get_event_count`.
2. `syndctl pause 2 && sleep 3 && syndctl resume 2`: both should report
   confirmed, not "daemon has not logged it yet".
3. `python3 tests/test_syndctl.py`.
