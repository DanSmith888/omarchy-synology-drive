#!/usr/bin/env python3
"""Offline tests for bin/syndctl's daemon-log parser.

The fixtures are real line shapes from Synology Drive Client 4.0.3 (build
17892) with the file names changed. Run:  python3 tests/test_syndctl.py
"""

import importlib.machinery
import importlib.util
import os
import sys
import unittest

sys.dont_write_bytecode = True   # never leave bin/__pycache__ behind

HERE = os.path.dirname(os.path.abspath(__file__))
CTL = os.path.join(HERE, "..", "bin", "syndctl")
loader = importlib.machinery.SourceFileLoader("syndctl", CTL)
spec = importlib.util.spec_from_loader("syndctl", loader)
syndctl = importlib.util.module_from_spec(spec)
loader.exec_module(syndctl)


def ev(cls, sess, source, ftype, path, size, sync_id=93795):
    return (f"Event<{cls}>[{sess}]{{source: {source}, type: {ftype}, "
            f"file_id: '970495534410282266', parent_id: '908210912668723485', "
            f"path: '{path}', sync_id: {sync_id}, max_id: {sync_id}, file_size: {size}, "
            f"file_mtime: 1750642702, file_hash: d0b9785233d4b7097af28c8062366352, "
            f"ea_size: 0, ea_hash: , exec_bit: 0, permanent_link: 19gsY7Po1EH6FVKn, "
            f"uid: 1026, gid: 100, mode: 1638, acl: 1 595 0 , share_priv_disabled = 0")


def line(ts, pid, level, src, no, msg):
    return f"{ts} ({pid:>5}:{35136:>5}) [{level}] {src}({no}): {msg}"


PID = 2935
T = "2026-08-31T10:45:"

DOWNLOAD_IN_FLIGHT = "\n".join([
    line(T + "32", PID, "INFO", "event-manager.cpp", 900,
         "PushEvent = [" + ev("FileAddEvent", 2, "server", "file", "/manual.pdf", 11629609) + "]"),
    line(T + "32", PID, "INFO", "event-manager.cpp", 900,
         "PushEvent = [" + ev("FileAddEvent", 2, "server", "file", "/photo.jpg", 465371) + "]"),
    line(T + "32", PID, "INFO", "event-manager.cpp", 291,
         "PullEvent: " + ev("FileAddEvent", 2, "server", "file", "/manual.pdf", 11629609)),
    line(T + "32", PID, "INFO", "download-remote-handler.cpp", 1096,
         "Worker (12293): Ready to prepare download from remote. (1 unsatisfied information)"),
    line(T + "32", PID, "INFO", "stream.cpp", 308,
         "sending /home/u/Downloads/.SynologyWorkingDirectory/Temp/SwjULBKk ... (0 / 11629609)"),
])

DOWNLOAD_DONE = DOWNLOAD_IN_FLIGHT + "\n" + "\n".join([
    line(T + "33", PID, "INFO", "error-handler.cpp", 79, "Worker (12293): Handle error: (0) Successful."),
    line(T + "33", PID, "INFO", "event-manager.cpp", 302,
         "DoneEvent: " + ev("FileAddEvent", 2, "server", "file", "/manual.pdf", 11629609)),
    line(T + "33", PID, "INFO", "event-manager.cpp", 291,
         "PullEvent: " + ev("FileAddEvent", 2, "server", "file", "/photo.jpg", 465371)),
    line(T + "33", PID, "INFO", "event-manager.cpp", 302,
         "DoneEvent: " + ev("FileAddEvent", 2, "server", "file", "/photo.jpg", 465371)),
    line(T + "33", PID, "INFO", "pullevent-handler.cpp", 200, "Set session 2's sync_id to 93795."),
    line(T + "33", PID, "INFO", "syncer-event-manager.cpp", 236,
         "Syncer event pool is now empty, no any event to process for session id 2"),
])

LOCAL_MODIFY = "\n".join([
    line(T + "10", PID, "INFO", "event-manager.cpp", 900,
         "PushEvent = [" + ev("FileModifyEvent", 1, "local", "file", "/notes/todo.md", 0, 0) + "]"),
    line(T + "10", PID, "INFO", "event-manager.cpp", 291,
         "PullEvent: " + ev("FileModifyEvent", 1, "local", "file", "/notes/todo.md", 0, 0)),
])

# Real shape of the native Pause button (client 4.0.3, observed 2026-09-01):
# per-session markers, followed by barrier chatter that also fires on plain
# session reloads and therefore must not be read as pause/resume.
PAUSE = "\n".join([
    line(T + "40", PID, "INFO", "daemon-impl.cpp", 2154, "Pause session 1 by session id."),
    line(T + "40", PID, "INFO", "daemon-impl.cpp", 2154, "Pause session 2 by session id."),
    line(T + "40", PID, "INFO", "worker_mgr.cpp", 84, "WorkerManager: pause all worker"),
    line(T + "40", PID, "INFO", "daemon-impl.cpp", 1352, "remove 1 worker process"),
    line(T + "40", PID, "INFO", "worker_mgr.cpp", 109, "WorkerManager: resume all worker"),
])
RESUME = "\n".join([
    line(T + "50", PID, "INFO", "daemon-impl.cpp", 2255, "Resume session 1 by session id."),
    line(T + "50", PID, "INFO", "daemon-impl.cpp", 2255, "Resume session 2 by session id."),
    line(T + "50", PID, "INFO", "worker_mgr.cpp", 84, "WorkerManager: pause all worker"),
    line(T + "50", PID, "INFO", "daemon-impl.cpp", 1374, "add 1 worker process"),
    line(T + "50", PID, "INFO", "worker_mgr.cpp", 109, "WorkerManager: resume all worker"),
])
RELOAD_ONLY = "\n".join([
    line(T + "45", PID, "INFO", "daemon-impl.cpp", 2046, "Action 'reload_session': Reloading session #2, info={\"action\": \"reload_session\"}"),
    line(T + "45", PID, "INFO", "worker_mgr.cpp", 84, "WorkerManager: pause all worker"),
    line(T + "45", PID, "INFO", "daemon-impl.cpp", 1352, "remove 2 worker process"),
    line(T + "45", PID, "INFO", "worker_mgr.cpp", 109, "WorkerManager: resume all worker"),
])

OFFLINE = "\n".join([
    line(T + "55", PID, "INFO", "protocol-client.cpp", 135,
         "Failed to establish a new channel (-2), trying to find a new connection."),
    line(T + "55", PID, "ERROR", "init-handler.cpp", 182,
         "Failed to send/recv query user request. (code: -2)"),
])
BACK_ONLINE = line(T + "59", PID, "INFO", "syncer-event-manager.cpp", 236,
                   "Syncer event pool is now empty, no any event to process for session id 1")

RESCAN_NOISE = "\n".join(
    line(T + "00", PID, "INFO", "rescan-handler.cpp", 46, f"Syncer (2311): scanning /x/{i}")
    for i in range(50))


class ParseLog(unittest.TestCase):
    def test_download_in_flight(self):
        s = syndctl.parse_log(DOWNLOAD_IN_FLIGHT)
        self.assertEqual(len(s["queue"]), 2)
        self.assertIsNotNone(s["current"])
        self.assertEqual(s["current"]["name"], "manual.pdf")
        self.assertEqual(s["current"]["direction"], "download")
        self.assertEqual(s["current"]["size"], 11629609)
        self.assertEqual(s["current"]["kind"], "added")
        self.assertTrue(s["current"]["started"])
        queued = [q for q in s["queue"] if not q.get("started")]
        self.assertEqual([q["name"] for q in queued], ["photo.jpg"])
        self.assertFalse(s["paused"])
        self.assertFalse(s["offline"])

    def test_download_done_is_idle(self):
        s = syndctl.parse_log(DOWNLOAD_DONE)
        self.assertEqual(s["queue"], [])
        self.assertIsNone(s["current"])
        self.assertIn(2, s["idle_at"])
        self.assertIsNotNone(s["last_activity"])

    def test_local_modify_is_upload(self):
        s = syndctl.parse_log(LOCAL_MODIFY)
        self.assertEqual(s["current"]["direction"], "upload")
        self.assertEqual(s["current"]["kind"], "modified")
        self.assertEqual(s["current"]["session"], 1)

    def test_pause_and_resume_markers(self):
        p = syndctl.parse_log(PAUSE)
        self.assertTrue(p["paused"])
        self.assertEqual(p["paused_sessions"], [1, 2])
        self.assertFalse(syndctl.parse_log(PAUSE + "\n" + RESUME)["paused"])

    def test_reload_is_not_a_pause(self):
        self.assertFalse(syndctl.parse_log(RELOAD_ONLY)["paused"])

    def test_pause_by_connection_id(self):
        # The client sends this shape when the NAS entry, not a task, is selected.
        text = "\n".join([
            line(T + "40", PID, "INFO", "daemon-impl.cpp", 2166, "Pause session 1 by connection id."),
            line(T + "40", PID, "INFO", "daemon-impl.cpp", 2166, "Pause session 2 by connection id."),
        ])
        p = syndctl.parse_log(text)
        self.assertTrue(p["paused"])
        self.assertEqual(p["paused_sessions"], [1, 2])
        text += "\n" + line(T + "50", PID, "INFO", "daemon-impl.cpp", 2255, "Resume session 1 by session id.")
        p = syndctl.parse_log(text)
        self.assertEqual(p["paused_sessions"], [2])

    def test_pause_one_session_only(self):
        one = line(T + "40", PID, "INFO", "daemon-impl.cpp", 2154, "Pause session 2 by session id.")
        p = syndctl.parse_log(one)
        self.assertTrue(p["paused"])
        self.assertEqual(p["paused_sessions"], [2])

    def test_offline_until_next_success(self):
        self.assertTrue(syndctl.parse_log(DOWNLOAD_DONE + "\n" + OFFLINE)["offline"])
        self.assertFalse(syndctl.parse_log(DOWNLOAD_DONE + "\n" + OFFLINE + "\n" + BACK_ONLINE)["offline"])

    def test_error_line_kept(self):
        s = syndctl.parse_log(OFFLINE)
        self.assertIn("query user request", s["last_error"]["text"])

    def test_daemon_restart_drops_queue(self):
        restarted = DOWNLOAD_IN_FLIGHT + "\n" + line(
            "2026-08-31T11:00:00", PID + 1, "INFO", "init-handler.cpp", 44,
            "Initialize session 2 with sync_id: 93795")
        s = syndctl.parse_log(restarted)
        self.assertEqual(s["queue"], [])
        self.assertIsNone(s["current"])

    def test_rescan_noise_ignored_and_partial_first_line(self):
        text = "artial line without a prefix\n" + RESCAN_NOISE + "\n" + DOWNLOAD_IN_FLIGHT
        s = syndctl.parse_log(text)
        self.assertEqual(len(s["queue"]), 2)

    def test_empty(self):
        s = syndctl.parse_log("")
        self.assertEqual(s["queue"], [])
        self.assertFalse(s["paused"])
        self.assertFalse(s["offline"])


class PStream(unittest.TestCase):
    """Wire format per PROTOCOL.md; the ack frame is the daemon's real reply."""

    def test_ack_frame_bytes(self):
        self.assertEqual(syndctl.ps_encode({"ack": "ok"}), b"B\x10\x00\x03ack\x10\x00\x02ok@")
        self.assertEqual(syndctl.ps_decode(b"B\x10\x00\x03ack\x10\x00\x02ok@"), ({"ack": "ok"}, 13))

    def test_integer_widths(self):
        for v, want in [(0, b"\x01\x01\x00"), (255, b"\x01\x01\xff"), (256, b"\x01\x02\x01\x00"),
                        (0x10000, b"\x01\x04\x00\x01\x00\x00"),
                        (0x1_0000_0000, b"\x01\x08\x00\x00\x00\x01\x00\x00\x00\x00")]:
            self.assertEqual(syndctl.ps_encode(v), want, v)
            self.assertEqual(syndctl.ps_decode(want)[0], v)

    def test_roundtrip_nested(self):
        obj = {"action": "pause", "session_id_list": [1, 2], "note": "héllo", "flag": True, "none": None}
        got, n = syndctl.ps_decode(syndctl.ps_encode(obj))
        self.assertEqual(got, {"action": "pause", "session_id_list": [1, 2], "note": "héllo", "flag": 1, "none": None})
        self.assertEqual(n, len(syndctl.ps_encode(obj)))

    def test_pause_request_shape(self):
        # What the client's own Pause button sends, as observed on 4.0.3.
        b = syndctl.ps_encode({"action": "pause", "session_id_list": [2]})
        self.assertEqual(b, b"B\x10\x00\x06action\x10\x00\x05pause"
                            b"\x10\x00\x0fsession_id_list\x41\x01\x01\x02\x40@")

    def test_unknown_tag_raises(self):
        with self.assertRaises(ValueError):
            syndctl.ps_decode(b"{")

    def test_depth_bomb_rejected(self):
        bomb = b"\x41" * (syndctl.MAX_PS_DEPTH + 2) + b"\x40" * (syndctl.MAX_PS_DEPTH + 2)
        with self.assertRaises(ValueError):
            syndctl.ps_decode(bomb)

    def test_wide_map_rejected(self):
        blob = bytearray(b"\x42")
        for i in range(syndctl.MAX_PS_ITEMS + 1):
            blob += syndctl.ps_encode(f"k{i}") + syndctl.ps_encode(1)
        blob += b"\x40"
        with self.assertRaises(ValueError):
            syndctl.ps_decode(bytes(blob))

    def test_confined_rejects_escapes(self):
        import os
        root = syndctl.DRIVE_ROOT
        fb = os.path.join(root, "daemon.sock")
        self.assertEqual(syndctl.confined("/etc/passwd", fb), fb)
        self.assertEqual(syndctl.confined(root + "/../outside", fb), fb)
        self.assertEqual(syndctl.confined(None, fb), fb)
        inside = os.path.join(root, "log", "daemon.log")
        self.assertEqual(syndctl.confined(inside, fb), os.path.realpath(inside))

    def test_field_cap(self):
        self.assertEqual(len(syndctl._s("x" * 10000)), syndctl._FIELD)
        self.assertIsNone(syndctl._s(None))


class Helpers(unittest.TestCase):
    def test_history_action_names(self):
        self.assertEqual(syndctl.HISTORY_ACTION[40], "downloaded")
        self.assertEqual(syndctl.HISTORY_ACTION[24], "uploaded")

    def test_event_kind(self):
        self.assertEqual(syndctl._event_kind("FileAddEvent", "file"), "added")
        self.assertEqual(syndctl._event_kind("FileRemoveEvent", "file"), "removed")
        self.assertEqual(syndctl._event_kind("FileRenameEvent", "file"), "renamed")
        self.assertEqual(syndctl._event_kind("WeirdEvent", "file"), "changed")


if __name__ == "__main__":
    unittest.main(verbosity=1)
