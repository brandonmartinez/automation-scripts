from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import subprocess
import sys
import uuid

from .runtime import (
    ROOT, AutomationError, absolute, atomic_json, directory, lock, logger,
    file_version, fingerprint, no_symlinks, now, publish_copy, regular_file,
    require_unchanged, sync_directory,
)


FAMILIES = ("pdf-with-openai", "guitar-tabs", "video-imports")


@dataclass(frozen=True)
class QueuePaths:
    family: str
    home: Path

    def __post_init__(self):
        if self.family not in FAMILIES:
            raise AutomationError(f"Unknown Hazel family: {self.family}")

    @property
    def legacy(self) -> Path:
        return self.home / f".hazel-organize-{self.family}-queue"

    @property
    def database(self) -> Path:
        return Path(f"{self.legacy}.sqlite3")

    @property
    def jobs(self) -> Path:
        return Path(f"{self.legacy}.jobs")

    def job_directory(self, job_id: str) -> Path:
        if not isinstance(job_id, str) or not re.fullmatch(r"[0-9a-f]{32}", job_id):
            raise AutomationError(f"Malformed job ID retained for inspection: {job_id!r}")
        return self.jobs / job_id

    def guard_legacy(self) -> None:
        for suffix in (".lock", ".oplock"):
            path = Path(f"{self.legacy}{suffix}")
            if path.exists() or path.is_symlink():
                raise AutomationError(
                    f"Legacy lock exists: {path}. Stop old workers, verify ownership "
                    "and inspect/remove that specific lock manually before migration. "
                    "No PID will be signalled or age-based lock removed."
                )


class Queue:
    def __init__(self, paths: QueuePaths):
        self.paths = paths
        paths.guard_legacy()
        directory(paths.jobs)
        no_symlinks(paths.database)
        # Open privately before sqlite so umask never exposes a newly created DB.
        fd = os.open(paths.database, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        regular = stat.S_ISREG(os.fstat(fd).st_mode)
        os.close(fd)
        if not regular:
            raise AutomationError(f"Queue database is not a regular file: {paths.database}")
        self.db = sqlite3.connect(paths.database, timeout=30, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY NOT NULL, source TEXT NOT NULL, payload TEXT NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('pending','running','failed','done')),
                attempts INTEGER NOT NULL DEFAULT 0, created TEXT NOT NULL,
                updated TEXT NOT NULL, error TEXT
            );
            CREATE TABLE IF NOT EXISTS imports (
                path TEXT PRIMARY KEY, imported TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS submissions (
                source TEXT PRIMARY KEY, version TEXT NOT NULL, job_id TEXT NOT NULL
            );
        """)

    def close(self) -> None:
        self.db.close()

    def add(self, source: Path, *, track_launch: bool = False) -> str:
        source = regular_file(source)
        version = file_version(source)
        job_id = uuid.uuid4().hex
        job = directory(self.paths.job_directory(job_id))
        payload = source
        # A private per-job copy eliminates basename collisions and leaves Hazel
        # free to move its original. Copy metadata as well as bytes.
        if self.paths.family != "video-imports":
            inbox = "Scans" if self.paths.family == "pdf-with-openai" else "Guitar Tabs"
            staging = directory(self.paths.home / f"Documents/{inbox}/_temp" / job_id)
            payload = publish_copy(source, staging / source.name, collision=False)
        require_unchanged(source, version)
        timestamp = now()
        try:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                self.db.execute(
                    "INSERT INTO jobs(id,source,payload,status,created,updated) VALUES(?,?,?,'pending',?,?)",
                    (job_id, str(source), str(payload), timestamp, timestamp),
                )
                if track_launch:
                    self.db.execute(
                        "INSERT OR REPLACE INTO submissions(source,version,job_id) VALUES(?,?,?)",
                        (str(source), json.dumps(version), job_id),
                    )
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise
        except sqlite3.Error as exc:
            raise AutomationError(
                f"Queue publication failed; source and staged payload retained at {payload}; "
                f"job directory: {job}"
            ) from exc
        return job_id

    def admit(self, source: Path) -> str:
        source = regular_file(source)
        row = self.db.execute(
            "SELECT jobs.id FROM submissions JOIN jobs ON jobs.id=submissions.job_id "
            "WHERE submissions.source=? AND submissions.version=?",
            (str(source), json.dumps(file_version(source))),
        ).fetchone()
        if row:
            self.paths.job_directory(row["id"])
            return row["id"]
        return self.add(source, track_launch=True)

    def acknowledge_launch(self, job_id: str) -> None:
        self.db.execute("DELETE FROM submissions WHERE job_id=?", (job_id,))

    def import_legacy(self) -> None:
        paths = self.paths
        with lock(Path(f"{paths.legacy}.python-import.lock")):
            paths.guard_legacy()
            no_symlinks(paths.legacy)
            if paths.legacy.exists():
                if not paths.legacy.is_file():
                    raise AutomationError(f"Legacy queue is not a regular file: {paths.legacy}")
                if paths.legacy.stat().st_size:
                    archive = Path(f"{paths.legacy}.legacy-{uuid.uuid4().hex}")
                    os.rename(paths.legacy, archive)
                    sync_directory(paths.home)
            batches = sorted(paths.home.glob(f"{paths.legacy.name}.legacy-*"))
            batches += sorted(paths.home.glob(f"{paths.legacy.name}.processing.*"))
            for batch in batches:
                no_symlinks(batch)
                if self.db.execute("SELECT 1 FROM imports WHERE path=?", (str(batch),)).fetchone():
                    continue
                try:
                    text = batch.read_text(encoding="utf-8")
                except UnicodeError as exc:
                    raise AutomationError(f"Legacy batch is not UTF-8; retained for repair: {batch}") from exc
                self.db.execute("BEGIN IMMEDIATE")
                try:
                    for line in text.split("\n"):
                        line = line.removesuffix("\r")
                        if not line:
                            continue
                        # A legacy relative path has no recorded cwd. Do not guess.
                        valid = Path(line).is_absolute() and "\x00" not in line
                        job_id = uuid.uuid4().hex
                        directory(paths.job_directory(job_id))
                        stamp = now()
                        self.db.execute(
                            "INSERT INTO jobs(id,source,payload,status,created,updated,error) VALUES(?,?,?,?,?,?,?)",
                            (job_id, line, line, "pending" if valid else "failed", stamp, stamp,
                             None if valid else "Malformed legacy path: absolute UTF-8 path required; batch retained"),
                        )
                    self.db.execute("INSERT INTO imports VALUES(?,?)", (str(batch), now()))
                    self.db.execute("COMMIT")
                except BaseException:
                    self.db.execute("ROLLBACK")
                    raise

    def claim(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            row = self.db.execute(
                "SELECT rowid AS row_id,* FROM jobs WHERE status='pending' ORDER BY created,id LIMIT 1"
            ).fetchone()
            if row:
                self.db.execute(
                    "UPDATE jobs SET status='running', attempts=attempts+1, updated=?, error=NULL WHERE rowid=?",
                    (now(), row["row_id"]),
                )
            self.db.execute("COMMIT")
            return row
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def finish(self, row_id: int, error: str | None = None) -> None:
        self.db.execute(
            "UPDATE jobs SET status=?,error=?,updated=? WHERE rowid=?",
            ("failed" if error else "done", error, now(), row_id),
        )

    def retry(self, job_id: str) -> None:
        job = self.paths.job_directory(job_id)
        if not self.db.execute("SELECT 1 FROM jobs WHERE id=?", (job_id,)).fetchone():
            raise AutomationError(f"Unknown job: {job_id}")
        publication = job / "publication.json"
        if publication.exists():
            raise AutomationError(
                f"Job has a published output recorded in {publication}; reconcile partial "
                "completion first. Archive that specific receipt only after inspection before retry."
            )
        changed = self.db.execute(
            "UPDATE jobs SET status='pending',error=NULL,updated=? WHERE id=? AND status='failed'",
            (now(), job_id),
        ).rowcount
        if not changed:
            raise AutomationError(f"Job {job_id} does not exist or is not failed")

    def rows(self) -> list[dict]:
        return [dict(row) for row in self.db.execute("SELECT * FROM jobs ORDER BY created,id")]


def enqueue(family: str, source: str) -> int:
    paths = QueuePaths(family, Path.home())
    paths.guard_legacy()
    # Hazel retries nonzero actions. Serialize acceptance through handoff so a
    # failed/killed wrapper can reuse its durable job instead of copying it again.
    with lock(Path(f"{paths.legacy}.python-enqueue.lock")):
        queue = Queue(paths)
        try:
            manual = os.environ.get("HAZEL_NO_WORKER") == "1"
            job_id = queue.add(absolute(source)) if manual else queue.admit(absolute(source))
            print(f"Queued job {job_id}")
            if manual:
                return 0
            log = logger(f"hazel-organize-{family}-wrapper", worker=True)
            path = paths.home / f"Library/Logs/hazel-organize-{family}-wrapper.log"
            no_symlinks(path)
            try:
                with path.open("a", encoding="utf-8") as output:
                    subprocess.Popen(
                        [sys.executable, "-I", str(ROOT / "utilities/hazel-python.py"), "worker", family],
                        stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                        start_new_session=True, close_fds=True,
                    )
            except OSError as exc:
                log.error("Worker launch failed; job %s remains pending: %s", job_id, exc)
                raise AutomationError(
                    f"Worker launch failed; job {job_id} is retained. "
                    "Retry this wrapper with the unchanged input or run the worker manually."
                ) from exc
            log.info("Accepted job %s; worker started", job_id)
            queue.acknowledge_launch(job_id)
            return 0
        finally:
            queue.close()


def work(family: str) -> int:
    paths = QueuePaths(family, Path.home())
    paths.guard_legacy()
    log = logger(f"hazel-organize-{family}-worker", worker=True)
    # Blocking, kernel-owned locks prevent stale-PID bugs and the enqueue/exit
    # lost-wakeup race: every kicked worker eventually acquires and rechecks.
    with lock(Path(f"{paths.legacy}.python-worker.lock")) as lease:
        queue = Queue(paths)
        try:
            interrupted = queue.db.execute(
                "UPDATE jobs SET status='failed',error=?,updated=? WHERE status='running'",
                ("Previous worker interrupted; inspect partial output before explicit retry", now()),
            ).rowcount
            if interrupted:
                log.error("%s interrupted job(s) retained as failed; inspect queue status", interrupted)
            queue.import_legacy()
            failures = interrupted
            while row := queue.claim():
                job_id = row["id"]
                log.info("Processing job %s: %s", job_id, row["payload"])
                try:
                    job = paths.job_directory(job_id)
                    payload = row["payload"]
                    if not isinstance(payload, str) or "\x00" in payload or not Path(payload).is_absolute():
                        raise AutomationError("Malformed job payload: absolute path required; job retained")
                    source = regular_file(row["payload"])
                    args = [sys.executable, "-I", str(ROOT / "utilities/hazel-python.py"),
                            "organize", family]
                    if family == "pdf-with-openai":
                        args += ["--move", "--state-file", str(job / "plan.json")]
                    args += [str(source)]
                    # Owned child only; no interpreter/tool lookup through a shell.
                    from .runtime import run
                    environment = os.environ | {
                        "HAZEL_PUBLICATION_FILE": str(job / "publication.json"),
                    }
                    # Keep the kernel lease alive in the organizer if this worker
                    # is SIGKILLed. Recovery must not race an orphaned organizer.
                    result = run(args, check=False, env=environment, pass_fds=(lease,))
                    for output in (result.stdout, result.stderr):
                        if output:
                            log.info("%s", output.rstrip())
                    if result.returncode:
                        raise AutomationError(f"Organizer failed (exit {result.returncode}); inspect worker log")
                    queue.finish(row["row_id"])
                    log.info("Done job %s", job_id)
                except (AutomationError, OSError) as exc:
                    failures += 1
                    queue.finish(row["row_id"], str(exc))
                    log.error("Failed job %s: %s", job_id, exc)
                except BaseException as exc:
                    queue.finish(row["row_id"], f"Interrupted: {type(exc).__name__}; inspect partial output before retry")
                    raise
            return 1 if failures else 0
        finally:
            queue.close()


def record_publication(path: Path) -> None:
    receipt = os.environ.get("HAZEL_PUBLICATION_FILE")
    if receipt:
        atomic_json(absolute(receipt), {"appliedPath": str(path), "publishedAt": now(),
                                       "file": fingerprint(path)})
