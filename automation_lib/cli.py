from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sqlite3
import sys

from .runtime import AutomationError, AutomationInterrupted, interruptions, regular_file, run


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(1, f"{self.prog}: error: {message}\n")


def organize(family: str, args: list[str]) -> int:
    parser = Parser(prog=f"organize-{family}.sh")
    if family == "pdf-with-openai":
        parser.add_argument("--move", action="store_true")
        parser.add_argument("--dry-run", action="store_true", help="Analyze/plan without mutating source or archive")
        parser.add_argument("--state-file")
        parser.add_argument("input_file")
        options = parser.parse_args(args)
        from .paperwork import organize
        return organize(**vars(options))
    if family == "guitar-tabs":
        parser.add_argument("--debug", action="store_true", help="Write a -debug chart beside input, preserving input")
        parser.add_argument("input_file")
        options = parser.parse_args(args)
        from .guitar import organize
        return organize(**vars(options))
    if family == "video-imports":
        parser.add_argument("--interval", type=int, default=30, help="Seconds between frames (default: 30)")
        parser.add_argument("--max-frames", type=int, default=100, help="Frame cap (default: 100; 0 = unlimited)")
        parser.add_argument("--summaries-dir")
        parser.add_argument("input_file")
        options = parser.parse_args(args)
        from .video import organize
        return organize(**vars(options))
    raise AutomationError(f"Unknown Hazel family: {family}")


def dispatch(args: list[str]) -> int:
    from .queue import FAMILIES, Queue, QueuePaths, enqueue, work
    parser = Parser(prog="hazel-python.py")
    sub = parser.add_subparsers(dest="command", required=True)
    add = sub.add_parser("enqueue")
    add.add_argument("family", choices=FAMILIES)
    add.add_argument("source")
    worker = sub.add_parser("worker")
    worker.add_argument("family", choices=FAMILIES)
    status = sub.add_parser("status", help="Show durable jobs, errors and retained payload paths")
    status.add_argument("family", choices=FAMILIES)
    retry = sub.add_parser("retry", help="Explicitly requeue one failed job after inspecting partial output")
    retry.add_argument("family", choices=FAMILIES)
    retry.add_argument("job_id")
    legacy = sub.add_parser("import-legacy", help="Import stopped legacy queues without deleting archives")
    legacy.add_argument("family", choices=FAMILIES)
    sub.add_parser("ocr").add_argument("input_file")
    options = parser.parse_args(args)
    if options.command == "enqueue":
        return enqueue(options.family, options.source)
    if options.command == "worker":
        return work(options.family)
    if options.command == "ocr":
        source = regular_file(options.input_file)
        temporary = Path.home() / ".temp"
        from .runtime import directory, logger
        directory(temporary)
        log = logger("pdf-ocr-text", module="media")
        result = run(
            ["ocrmypdf", "-l", "eng", "--output-type", "pdf", "--redo-ocr", "--rotate-pages", source, source],
            env=os.environ | {"TMPDIR": str(temporary)}, check=False,
        )
        if result.returncode:
            log.error("OCR processing failed (exit %s): %s", result.returncode, result.stderr.strip())
            return result.returncode
        log.info("OCR processing completed for %s", source)
        return 0
    queue = Queue(QueuePaths(options.family, Path.home()))
    try:
        if options.command == "status":
            print(json.dumps(queue.rows(), ensure_ascii=False, indent=2))
        elif options.command == "retry":
            queue.retry(options.job_id)
            print(f"Job {options.job_id} is pending; run its worker")
        else:
            queue.import_legacy()
    finally:
        queue.close()
    return 0


def main(args: list[str] | None = None) -> int:
    args = sys.argv[1:] if args is None else args
    try:
        with interruptions():
            if args[:1] == ["organize"] and len(args) >= 2:
                return organize(args[1], args[2:])
            return dispatch(args)
    except (AutomationInterrupted, KeyboardInterrupt) as exc:
        print(f"ERROR: {exc or 'Interrupted'}; inputs/jobs retained. Inspect partial output before retry.", file=sys.stderr)
        return 130
    except (AutomationError, OSError, ValueError, sqlite3.Error) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
