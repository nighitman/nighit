#!/usr/bin/env python3
"""Minimal user-space SSH server for the sandbox (no root / no sshd required).

Listens on 127.0.0.1:2222, accepts only the configured user with a public key,
and gives an interactive PTY shell (or executes a command). Expose it with a
TCP tunnel such as `bore local 2222 --to bore.pub`.

Usage:
    python3 ssh-server.py [--port 2222]
"""
from __future__ import annotations

import argparse
import asyncio
import fcntl
import os
import pty
import signal
import struct
import sys
import termios
from pathlib import Path

import asyncssh

CONFIG_DIR = Path(os.environ.get("KOMARI_CONFIG_DIR", Path.home() / ".config/komari"))
HOST_KEY = CONFIG_DIR / "ssh_host_ed25519_key"
AUTHORIZED_KEYS = CONFIG_DIR / "ssh_authorized_keys"
SSH_USER = os.environ.get("SSH_USER", "node")
HOME = Path.home()
BIND_HOST = os.environ.get("SSH_BIND_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("SSH_BIND_PORT", "2222"))


def log(message: str) -> None:
    import time
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}", flush=True)


def load_authorized() -> set[bytes]:
    if not AUTHORIZED_KEYS.exists():
        raise SystemExit(f"missing {AUTHORIZED_KEYS}")
    keys = [
        asyncssh.import_public_key(line)
        for line in AUTHORIZED_KEYS.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    return {key.get_fingerprint() for key in keys}


AUTHORIZED = load_authorized()


class SandboxSSHServer(asyncssh.SSHServer):
    def begin_auth(self, username: str) -> bool:
        return True

    def public_key_auth_supported(self) -> bool:
        return True

    def validate_public_key(self, username: str, key: asyncssh.SSHKey) -> bool:
        ok = username == SSH_USER and key.get_fingerprint() in load_authorized()
        log(f"auth user={username} key={key.get_fingerprint()} ok={ok}")
        return ok

    def connection_made(self, conn: asyncssh.SSHServerConnection) -> None:
        log(f"connection from {conn.get_extra_info('peername')}")

    def connection_lost(self, exc: Exception | None) -> None:
        log(f"connection closed: {exc!r}" if exc else "connection closed")


def set_winsize(fd: int, rows: int, cols: int) -> None:
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass


def build_env(process: asyncssh.SSHServerProcess) -> dict[str, str]:
    env = os.environ.copy()
    for key, value in (process.env or {}).items():
        if isinstance(key, bytes):
            key = key.decode("utf-8", "replace")
        if isinstance(value, bytes):
            value = value.decode("utf-8", "replace")
        env[str(key)] = str(value)
    env["TERM"] = process.term_type or env.get("TERM", "xterm-256color")
    env["SHELL"] = "/bin/bash"
    env["HOME"] = str(HOME)
    return env


async def run_pty(process: asyncssh.SSHServerProcess, command: str | None,
                  env: dict[str, str]) -> None:
    master, slave = pty.openpty()
    width, height = process.term_size[0] or 80, process.term_size[1] or 24
    set_winsize(slave, height, width)
    args = ["/bin/bash", "-lc", command] if command else ["/bin/bash", "-l"]

    pid = os.fork()
    if pid == 0:  # child
        try:
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            os.dup2(slave, 0)
            os.dup2(slave, 1)
            os.dup2(slave, 2)
            if slave > 2:
                os.close(slave)
            if master > 2:
                os.close(master)
            os.chdir(HOME)
            os.execvpe(args[0], args, env)
        except BaseException:
            os._exit(127)

    os.close(slave)
    process.set_redirect_pid(pid)

    def on_resize(new_width: int, new_height: int, *_rest: int) -> None:
        set_winsize(master, new_height or height, new_width or width)

    process.terminal_size_changed = on_resize

    loop = asyncio.get_running_loop()
    queue: asyncio.Queue[bytes | None] = asyncio.Queue()

    def on_readable() -> None:
        try:
            data = os.read(master, 65536)
        except OSError:
            data = b""
        if data:
            queue.put_nowait(data)
        else:
            loop.remove_reader(master)
            queue.put_nowait(None)

    loop.add_reader(master, on_readable)

    async def pump_out() -> None:
        while True:
            data = await queue.get()
            if data is None:
                return
            process.stdout.write(data)

    async def pump_in() -> None:
        while True:
            data = await process.stdin.read(65536)
            if not data:
                return
            os.write(master, data)

    out_task = asyncio.create_task(pump_out())
    in_task = asyncio.create_task(pump_in())
    child_task = loop.run_in_executor(None, os.waitpid, pid, 0)
    done, _pending = await asyncio.wait(
        {in_task, child_task}, return_when=asyncio.FIRST_COMPLETED
    )
    if child_task not in done:
        try:
            os.killpg(pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
    try:
        _pid, status = await child_task
    except Exception:
        status = 0
    in_task.cancel()
    out_task.cancel()
    loop.remove_reader(master)
    try:
        os.close(master)
    except OSError:
        pass
    process.exit(os.waitstatus_to_exitcode(status))


async def handle_process(process: asyncssh.SSHServerProcess) -> None:
    command = process.command
    if isinstance(command, bytes):
        command = command.decode("utf-8", "replace")
    env = build_env(process)
    use_pty = process.term_type is not None
    proc: asyncio.subprocess.Process | None = None
    master: int | None = None

    try:
        if use_pty:
            await run_pty(process, command, env)
            return
        else:
            args = ["/bin/bash", "-lc", command] if command else ["/bin/bash", "-l"]
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=str(HOME), env=env, preexec_fn=os.setsid,
            )
            process.set_redirect_pid(proc.pid)
            await process.redirect(stdin=proc.stdin, stdout=proc.stdout, stderr=proc.stderr)

        returncode = await proc.wait()
        process.exit(returncode)
    except (BrokenPipeError, ConnectionResetError):
        pass
    except Exception as exc:
        log(f"session error: {exc!r}")
        raise
    finally:
        if proc is not None and proc.returncode is None:
            try:
                os.killpg(proc.pid, signal.SIGHUP)
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(proc.wait(), timeout=3)
            except asyncio.TimeoutError:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        if master is not None:
            try:
                os.close(master)
            except OSError:
                pass


async def main() -> None:
    global BIND_PORT
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=BIND_PORT)
    args = parser.parse_args()
    BIND_PORT = args.port

    server = await asyncssh.create_server(
        SandboxSSHServer,
        BIND_HOST,
        BIND_PORT,
        server_host_keys=[str(HOST_KEY)],
        process_factory=handle_process,
        sftp_factory=True,
        allow_scp=True,
        encoding=None,
    )
    log(f"ssh server listening on {BIND_HOST}:{BIND_PORT} (user={SSH_USER})")

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()

    log("shutting down")
    server.close()
    await server.wait_closed()


if __name__ == "__main__":
    asyncio.run(main())
