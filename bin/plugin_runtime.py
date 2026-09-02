"""Shared runtime helpers for dansmith888.synology-drive backend scripts.

Standard library only. Import from any script in this directory:

    import plugin_runtime as rt
    rt.install_teardown()                     # first line of main()
    rc, out, err = rt.run_bounded(["cmd"])    # every shell-out
    with rt.single_writer():                  # around exclusive device access
        ...

Everything here exists because the Omarchy marketplace review asks for it.
Do not loosen a bound without reading the note that explains why it is there.
"""

import atexit
import ctypes
import contextlib
import fcntl
import os
import re
import selectors
import signal
import stat
import subprocess
import sys
import time

PLUGIN_ID = "dansmith888.synology-drive"
TOOL = os.path.basename(sys.argv[0]) or PLUGIN_ID

# ---------------------------------------------------------------- bounds
MAX_OUTPUT = 64 * 1024      # bytes captured per stream, then stop and reap
KILL_GRACE = 2.0            # seconds between SIGTERM and SIGKILL
LOCK_TIMEOUT = 30.0
PR_SET_PDEATHSIG = 1

_ACTIVE = set()             # Popen objects whose process groups we own


# ------------------------------------------------------- child lifecycle
def _child_setup(parent_pid):
    """Run in the child between fork and exec.

    setsid makes the child a session leader, so its pid is its process-group
    id and killpg reaches anything it spawns in turn. PR_SET_PDEATHSIG covers
    the case where we are killed without the chance to reap: without it, a
    nested helper outlives the process that started it and can hold a device
    lock open. start_new_session=True gives the first half only, which is why
    it is not used here.
    """
    os.setsid()
    # Both protections are mandatory: without them the group cannot be
    # reaped safely, so failing to establish either means not running at all.
    try:
        if ctypes.CDLL("libc.so.6", use_errno=True).prctl(
                PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0) != 0:
            os._exit(1)
    except Exception:
        os._exit(1)
    # Parent-death race: if the parent died before prctl armed, nothing will
    # ever signal us, so leave now rather than linger as an orphan.
    if os.getppid() != parent_pid:
        os._exit(1)


def _group_alive(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except OSError:
        return False


def _start_time(pid):
    """The kernel's start-time ticks for `pid`, or None. Together with the
    pid this identifies one specific process incarnation: a reused pid gets
    a different start time."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as handle:
            data = handle.read(4096)
        return data.rsplit(b") ", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def remember_identity(proc):
    """Record the child leader's (pidfd, start time) right after spawn, so a
    later reap can prove the pgid still names our child before signalling."""
    try:
        proc._pr_pidfd = os.pidfd_open(proc.pid)
    except OSError:
        proc._pr_pidfd = None
    proc._pr_start = _start_time(proc.pid)


def reap(proc, grace=KILL_GRACE):
    """Signal the child's whole group and return only once the group is gone.

    The direct child exiting is not enough: descendants share its group and
    outlive it happily. Group signalling stays safe through every phase
    because of a kernel invariant: a pid is never reused while it is still
    some process's live process-group id. So:

    - leader unreaped (poll() is None): the pid itself is pinned; killpg is
      safe (start-time cross-check kept as belt and braces).
    - leader reaped but the group non-empty: the surviving members pin the
      pgid, so it still names our group; killpg the members.
    - group empty: nothing may be signalled; the id is free for reuse.

    The leader is reaped non-blockingly inside the drain loop: a zombie
    leader would otherwise pin the group forever.
    """
    pgid = proc.pid                 # setsid in the child makes pid == pgid
    for sig in (signal.SIGTERM, signal.SIGKILL):
        proc.poll()
        leader_alive = proc.returncode is None
        if not leader_alive and not _group_alive(pgid):
            break
        if leader_alive and getattr(proc, "_pr_start", None) is not None \
                and _start_time(proc.pid) != proc._pr_start:
            # Cannot happen for an unreaped child of ours; treat a mismatch
            # as corruption and take the race-free leader-only path.
            with contextlib.suppress(OSError):
                if getattr(proc, "_pr_pidfd", None) is not None:
                    signal.pidfd_send_signal(proc._pr_pidfd, sig)
        else:
            try:
                os.killpg(pgid, sig)
            except OSError:
                if leader_alive:
                    with contextlib.suppress(OSError):
                        proc.send_signal(sig)
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            proc.poll()             # reap the leader; a zombie pins the pgid
            if proc.returncode is not None and not _group_alive(pgid):
                break
            time.sleep(0.05)
        else:
            continue
        break
    fd = getattr(proc, "_pr_pidfd", None)
    if fd is not None:
        proc._pr_pidfd = None
        with contextlib.suppress(OSError):
            os.close(fd)
    _ACTIVE.discard(proc)


def reap_all(*_):
    for proc in list(_ACTIVE):
        reap(proc)


def _on_signal(signum, _frame):
    reap_all()
    os._exit(128 + signum)


def install_teardown():
    """Own our children on every exit path: normal, exception, or signal."""
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            signal.signal(sig, _on_signal)
        except (ValueError, OSError):
            pass
    atexit.register(reap_all)


# ------------------------------------------------------- trusted programs
# PATH is never consulted for a program we execute. A directory earlier in
# PATH can be replaced between the lookup and the exec, so resolution is
# restricted to root-owned system directories, and the exec is then bound to
# the descriptor that was inspected rather than to the name: re-pointing the
# name afterwards cannot change which inode runs.
TRUSTED_BIN_DIRS = ("/usr/bin", "/usr/local/bin")


def _root_owned(st):
    """Owned by root and not writable by group or world."""
    return st.st_uid == 0 and not (st.st_mode & (stat.S_IWGRP | stat.S_IWOTH))


def open_trusted_exec(name):
    """(fd, path) for `name` in a trusted system directory, else (None, None).

    Caller owns the descriptor. Symlinks are followed deliberately: /bin and
    /usr/sbin are symlinks to /usr/bin on Arch, so refusing them would reject
    every system binary. The check that matters is on the resolved target,
    which must be a root-owned regular executable in a root-owned directory,
    and therefore not replaceable without root.
    """
    if not name or "/" in name:
        return None, None
    for directory in TRUSTED_BIN_DIRS:
        path = os.path.join(directory, name)
        try:
            dst = os.stat(directory)
            if not stat.S_ISDIR(dst.st_mode) or not _root_owned(dst):
                continue
            fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
        except OSError:
            continue
        try:
            st = os.fstat(fd)
            if (stat.S_ISREG(st.st_mode) and _root_owned(st)
                    and st.st_mode & stat.S_IXUSR):
                return fd, path
        except OSError:
            pass
        with contextlib.suppress(OSError):
            os.close(fd)
    return None, None


def have_trusted(name):
    """True when `name` resolves to a trusted executable. Replaces which()."""
    fd, _ = open_trusted_exec(name)
    if fd is None:
        return False
    os.close(fd)
    return True


def spawn_trusted(cmd, env=None):
    """Fire-and-forget launch of a trusted program, detached from us.

    For UI launches whose output we never read. The child gets its own
    session so it survives us, which is the point, so it is deliberately not
    added to _ACTIVE and not reaped.
    """
    exe_fd, _ = open_trusted_exec(cmd[0])
    if exe_fd is None:
        raise OSError(f"{cmd[0]}: not found in a trusted system directory")
    try:
        subprocess.Popen(cmd, executable=f"/proc/self/fd/{exe_fd}",
                         pass_fds=(exe_fd,), env=env,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    finally:
        os.close(exe_fd)


# ------------------------------------------------------------ subprocess
def run_bounded(cmd, timeout=6, max_output=MAX_OUTPUT, env=None):
    """(rc, stdout, stderr), bounded in time, bytes and lifetime.

    subprocess.run's timeout is not enough: it reads to EOF first, so a child
    that keeps talking holds memory and the call open indefinitely. The
    deadline here is enforced while reading.
    """
    exe_fd, _ = open_trusted_exec(cmd[0])
    if exe_fd is None:
        return 1, "", f"{cmd[0]}: not found in a trusted system directory"
    try:
        parent = os.getpid()
        proc = subprocess.Popen(cmd, executable=f"/proc/self/fd/{exe_fd}",
                                pass_fds=(exe_fd,), env=env,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,
                                preexec_fn=lambda: _child_setup(parent))
    except OSError as exc:
        return 1, "", str(exc)
    finally:
        os.close(exe_fd)
    remember_identity(proc)
    _ACTIVE.add(proc)

    bufs = {proc.stdout: bytearray(), proc.stderr: bytearray()}
    sel = selectors.DefaultSelector()
    for stream in bufs:
        sel.register(stream, selectors.EVENT_READ)

    deadline = time.monotonic() + timeout
    overflowed = False
    try:
        while sel.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                reap(proc)
                return 1, "", "timed out"
            for key, _ in sel.select(timeout=min(0.25, remaining)):
                chunk = key.fileobj.read1(8192)
                if not chunk:
                    sel.unregister(key.fileobj)
                    continue
                buf = bufs[key.fileobj]
                take = chunk[:max(0, max_output - len(buf))]
                buf += take
                if len(take) < len(chunk):
                    # Any byte dropped means the producer said more than the
                    # bound: the capture is incomplete and must not be
                    # parsed as a valid response.
                    overflowed = True
            if overflowed:
                break
    finally:
        sel.close()

    if overflowed:
        reap(proc)
        for stream in (proc.stdout, proc.stderr):
            with contextlib.suppress(OSError):
                stream.close()
        return 1, "", "output overflow"
    try:
        proc.wait(timeout=max(0.0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        reap(proc)
        return 1, "", "timed out"
    for stream in (proc.stdout, proc.stderr):
        with contextlib.suppress(OSError):
            stream.close()
    # A leader may exit cleanly the instant after forking a background
    # child; the group must be swept before the Popen is forgotten.
    if _group_alive(proc.pid):
        reap(proc)
    _ACTIVE.discard(proc)

    def dec(b):
        return bytes(b).decode("utf-8", "replace")

    return (proc.returncode if proc.returncode is not None else 1,
            dec(bufs[proc.stdout]), dec(bufs[proc.stderr]))


# ---------------------------------------------------------- runtime state
_RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR")
_STATE_DIR = os.path.join(_RUNTIME_DIR, PLUGIN_ID) if _RUNTIME_DIR else None
LOCK_NAME = "lock"
_state_fd = None


def state_dir_fd():
    """A held, validated descriptor for our private runtime directory.

    Checking a path then opening through that path leaves a window in which
    the directory can be swapped. Validate the descriptor itself and keep it,
    so every later open resolves against the object we checked.
    """
    global _state_fd
    if _state_fd is not None:
        return _state_fd
    if not _STATE_DIR:
        raise SystemExit(f"{TOOL}: XDG_RUNTIME_DIR is not set; "
                         "refusing to use a shared temp dir")
    try:
        os.makedirs(_STATE_DIR, mode=0o700, exist_ok=True)
        fd = os.open(_STATE_DIR,
                     os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as exc:
        raise SystemExit(f"{TOOL}: cannot open {_STATE_DIR}: {exc}")
    try:
        st = os.fstat(fd)
        if not stat.S_ISDIR(st.st_mode):
            raise SystemExit(f"{TOOL}: {_STATE_DIR} is not a directory")
        if st.st_uid != os.getuid():
            raise SystemExit(f"{TOOL}: {_STATE_DIR} is not owned by this user")
        if st.st_mode & 0o077:
            os.fchmod(fd, 0o700)
    except Exception:
        os.close(fd)
        raise
    _state_fd = fd
    return fd


def open_state(name, flags=os.O_RDWR | os.O_CREAT, mode=0o600):
    """Open a state file relative to the validated directory descriptor.

    O_NOFOLLOW refuses a symlink at the final component; never O_TRUNC, since
    truncating whatever is at the path is the bug being defended against.
    """
    fd = os.open(name, flags | os.O_NOFOLLOW | os.O_CLOEXEC, mode,
                 dir_fd=state_dir_fd())
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError(f"{name} is not a regular file")
    except Exception:
        os.close(fd)
        raise
    return fd


@contextlib.contextmanager
def single_writer(timeout=LOCK_TIMEOUT, busy_message=None):
    """Exclusive lock so status, ctl and any research tool serialise.

    Route every exclusive-resource open through this, or two of your own
    processes will fight over the device.
    """
    handle = os.fdopen(open_state(LOCK_NAME), "r+")
    deadline = time.monotonic() + timeout
    try:
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise SystemExit(busy_message or
                                     f"{TOOL}: device busy "
                                     f"(waited {timeout:.0f}s)")
                time.sleep(0.25)
        yield handle
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(handle, fcntl.LOCK_UN)
        with contextlib.suppress(OSError):
            handle.close()


# ------------------------------------------------------------ text safety
_CONTROL = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|[\x00-\x08\x0b-\x1f\x7f]")
MAX_FIELD = 200


def clean(value, limit=MAX_FIELD):
    """Strip ANSI escapes and control characters, then cap the length.

    Names, paths and driver strings come from other programs. bluetoothctl
    really does hand over 'MOMENTUM 4\\x1b[0m', escape sequence included. Do
    this once at the payload boundary so a field added later cannot skip it,
    and still set textFormat: Text.PlainText on every QML sink.
    """
    if not isinstance(value, str):
        return value
    return _CONTROL.sub("", value)[:limit]


def clean_payload(obj, limit=MAX_FIELD):
    """Recursively clean every string in a dict/list about to be emitted."""
    if isinstance(obj, dict):
        return {k: clean_payload(v, limit) for k, v in obj.items()}
    if isinstance(obj, list):
        return [clean_payload(v, limit) for v in obj]
    return clean(obj, limit)
