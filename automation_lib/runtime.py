from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime
import fcntl
import errno
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
from typing import Iterator


ROOT = Path(__file__).resolve().parents[1]


class AutomationError(Exception):
    pass


class AutomationInterrupted(Exception):
    pass


def now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def absolute(path: str | Path) -> Path:
    return Path(os.path.abspath(path))


def no_symlinks(path: Path) -> None:
    """Refuse indirection in effectful paths, including dangling symlinks."""
    for part in (path, *path.parents):
        if sys.platform == "darwin" and str(part) in ("/var", "/tmp", "/etc"):
            continue
        if part.is_symlink():
            raise AutomationError(f"Symlink boundary is not supported: {part}")


def regular_file(path: str | Path) -> Path:
    result = absolute(path)
    no_symlinks(result)
    if not result.is_file():
        raise AutomationError(f"Input file not found or not a regular file: {result}")
    return result


def directory(path: Path) -> Path:
    no_symlinks(path)
    path.mkdir(parents=True, exist_ok=True)
    return path


def tool(name: str) -> str:
    # The explicit path is also a closed executable boundary for offline tests.
    search = os.environ.get("AUTOMATION_TOOL_PATH", os.environ.get("PATH", ""))
    found = shutil.which(name, path=search)
    if not found:
        raise AutomationError(
            f"Missing required command: {name}. Install/configure it separately "
            "and make it available on PATH for Hazel/launchd."
        )
    return found


def optional_tool(name: str) -> str | None:
    return shutil.which(name, path=os.environ.get("AUTOMATION_TOOL_PATH", os.environ.get("PATH", "")))


def run(args: list[str | Path], *, check: bool = True, input: str | None = None,
        env: dict[str, str] | None = None, timeout: float | None = None,
        pass_fds: tuple[int, ...] = ()) -> subprocess.CompletedProcess[str]:
    command = [str(x) for x in args]
    command[0] = tool(command[0])
    # Only this child (not a process group or a discovered PID) is ours to signal.
    process = subprocess.Popen(
        command, stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        encoding="utf-8", errors="replace", env=env, pass_fds=pass_fds,
    )
    try:
        stdout, stderr = process.communicate(input, timeout=timeout)
    except BaseException:
        if process.poll() is None:
            process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
        raise
    result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    if check and result.returncode:
        # Never include argv: credentials and private document prompts may be there.
        detail = result.stderr.strip()[:2000]
        raise AutomationError(
            f"{Path(command[0]).name} failed (exit {result.returncode})"
            + (f": {detail}" if detail else "")
        )
    return result


@contextmanager
def interruptions() -> Iterator[None]:
    def interrupted(signum, _frame):
        # InterruptedError is swallowed/retried by Python's selector machinery.
        raise AutomationInterrupted(f"Interrupted by {signal.Signals(signum).name}")

    previous = {}
    try:
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGQUIT):
            previous[sig] = signal.signal(sig, interrupted)
        yield
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


@contextmanager
def lock(path: Path, *, blocking: bool = True) -> Iterator[int]:
    directory(path.parent)
    no_symlinks(path)
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise AutomationError(f"Lock is not a regular file: {path}")
        fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield fd
    finally:
        # Never unlink flock files: other workers may already be waiting on them.
        os.close(fd)


def atomic_bytes(path: Path, content: bytes, *, replace: bool = True, mode: int = 0o600) -> None:
    directory(path.parent)
    no_symlinks(path)
    fd, name = tempfile.mkstemp(prefix=".hazel-write-", dir=path.parent)
    temp = Path(name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), mode)
        if replace:
            os.replace(temp, path)
        else:
            os.link(temp, path)
        sync_directory(path.parent)
    finally:
        temp.unlink(missing_ok=True)


def atomic_json(path: Path, value: object) -> None:
    atomic_bytes(path, (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode())


def read_json(path: Path):
    no_symlinks(path)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as exc:
        raise AutomationError(f"Invalid JSON in {path}: {exc}") from exc


def sync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def fingerprint(path: Path) -> dict:
    info = path.stat()
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"path": str(path), "size": info.st_size, "mtimeNs": info.st_mtime_ns,
            "sha256": digest.hexdigest()}


def file_version(path: Path) -> tuple[int, int, int, int]:
    info = path.stat()
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def require_unchanged(path: Path, version: tuple[int, int, int, int]) -> None:
    regular_file(path)
    if file_version(path) != version:
        raise AutomationError(f"Input changed during processing; retained without publication: {path}")


def candidate_path(path: Path, count: int) -> Path:
    suffix = f"-{count:03d}" if count else ""
    budget = 255 - len((suffix + path.suffix).encode())
    stem = path.stem
    while len(stem.encode()) > budget:
        stem = stem[:-1]
    return path.with_name(stem + suffix + path.suffix)


def available_path(path: Path, original: Path | None = None) -> Path:
    path = candidate_path(path, 0)
    no_symlinks(path)
    count = 0
    while True:
        candidate = candidate_path(path, count)
        if not candidate.exists():
            return candidate
        if original is not None and candidate.samefile(original):
            return candidate
        count += 1


def publish_copy(source: Path, target: Path, *, collision: bool = True,
                 link_source: bool = False) -> Path:
    """Publish complete bytes and metadata atomically; never overwrite a file."""
    regular_file(source)
    version = file_version(source)
    target = candidate_path(target, 0)
    directory(target.parent)
    no_symlinks(target)
    if target.exists() and target.samefile(source):
        return target
    if link_source:
        count = 0
        while True:
            candidate = candidate_path(target, count)
            no_symlinks(candidate)
            try:
                os.link(source, candidate)
                sync_directory(target.parent)
                return candidate
            except FileExistsError:
                if not collision:
                    raise
                count += 1
            except OSError as exc:
                if exc.errno != errno.EXDEV:
                    raise
                break
    fd, name = tempfile.mkstemp(prefix=".publish-", dir=target.parent)
    os.close(fd)
    temp = Path(name)
    try:
        shutil.copy2(source, temp)
        require_unchanged(source, version)
        with temp.open("rb") as handle:
            os.fsync(handle.fileno())
        count = 0
        while True:
            candidate = candidate_path(target, count)
            no_symlinks(candidate)
            try:
                os.link(temp, candidate)
                sync_directory(target.parent)
                return candidate
            except FileExistsError:
                if not collision:
                    raise
                count += 1
    finally:
        temp.unlink(missing_ok=True)


def publish_text(target: Path, text: str) -> Path:
    directory(target.parent)
    with tempfile.TemporaryDirectory(prefix="hazel-text-") as temporary:
        source = Path(temporary) / "output"
        source.write_text(text, encoding="utf-8")
        source.chmod(0o600)
        return publish_copy(source, target)


class LockedRotatingFileHandler(RotatingFileHandler):
    def emit(self, record):
        with lock(Path(f"{self.baseFilename}.lock")):
            no_symlinks(Path(self.baseFilename))
            # Other processes can have rotated the file since our last emit.
            if self.stream:
                self.stream.close()
            self.stream = None
            for index in range(1, self.backupCount + 1):
                no_symlinks(Path(f"{self.baseFilename}.{index}"))
            super().emit(record)


def logger(name: str, *, worker: bool = False, module: str = "organization") -> logging.Logger:
    log = logging.getLogger(name)
    for handler in log.handlers[:]:
        log.removeHandler(handler)
        handler.close()
    log.propagate = False
    log.setLevel(os.environ.get("LOG_LEVEL_NAME", "INFO"))
    base = Path.home() / "Library/Logs"
    path = base / f"{name}.log" if worker else base / f"automation-scripts/{module}/{name}.log"
    directory(path.parent)
    no_symlinks(path)
    fd = os.open(path, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    os.close(fd)
    handler = LockedRotatingFileHandler(
        path, maxBytes=int(os.environ.get("LOG_MAX_SIZE", "10485760")),
        backupCount=int(os.environ.get("LOG_MAX_BACKUPS", "5")), encoding="utf-8",
    )
    formatter = logging.Formatter("[%(asctime)s] %(levelname)s: %(message)s", "%H:%M:%S")
    handler.setFormatter(formatter)
    stream = logging.StreamHandler()
    stream.setFormatter(formatter)
    log.addHandler(handler)
    log.addHandler(stream)
    return log
