import concurrent.futures
from contextlib import contextmanager
import io
import json
import logging
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from automation_lib import ai, guitar, paperwork, queue, runtime, video
import test_hazel_legacy as legacy
from test_hazel_legacy import ROOT, json_stream


class OfflineTests(unittest.TestCase):
    setUp = legacy.LegacyContracts.setUp
    fake = legacy.LegacyContracts.fake
    install = legacy.LegacyContracts.install
    run_script = legacy.LegacyContracts.run_script
    pdf_setup = legacy.LegacyContracts.pdf_setup
    video_setup = legacy.LegacyContracts.video_setup

    def run_new(self, family, *args, env=None, kind="organize"):
        if kind == "organize":
            path = ROOT / f"organization/organize-{family}.sh"
        else:
            path = ROOT / f"hazel/hazel-organize-{family}-{kind}.sh"
        environment = {
            "AUTOMATION_TOOL_PATH": str(self.bin), "AUTOMATION_PYTHON": sys.executable,
            "HAZEL_NO_WORKER": "1",
        } | (env or {})
        return self.run_script(path, *args, env=environment)

    def cli(self, *args):
        return subprocess.run(
            [sys.executable, "-I", str(ROOT / "utilities/hazel-python.py"), *args],
            cwd=self.root, env=self.env | {"AUTOMATION_TOOL_PATH": str(self.bin)},
            capture_output=True, text=True, timeout=30,
        )

    @contextmanager
    def isolated(self):
        with patch.dict(os.environ, self.env | {"AUTOMATION_TOOL_PATH": str(self.bin)}, clear=True):
            yield

    def paths(self, family="guitar-tabs"):
        return queue.QueuePaths(family, self.home)

    def rows(self, family="guitar-tabs"):
        with self.isolated():
            q = queue.Queue(self.paths(family))
            try:
                return q.rows()
            finally:
                q.close()

    def chart_tools(self):
        chart = "Song\nArtist\nKey: G\nCapo: 0\nTempo:\nTime:\nFlow: V1\nTuning: Standard\nTransposedKey:\n\nVerse 1:\nG\nWords\n"
        self.env["CHART"] = chart
        self.fake("curl", """
args = sys.argv[1:]
payload = json.loads(pathlib.Path(args[args.index('-d')+1][1:]).read_text())
with open(pathlib.Path(os.environ['HOME'])/'payloads.jsonl','a') as f:
 f.write(json.dumps(payload)+'\\n')
content = {'artist': 'Artist', 'song_title': 'Song', 'formatted_tab': os.environ['CHART']}
if 'Validate' in payload['messages'][1]['content']:
 content = {'formatted_tab': os.environ['CHART'], 'issues': [], 'fixed': False}
print(json.dumps({'choices':[{'message':{'content':json.dumps(content)}}]}))
""")
        return chart

    def test_pdf_equivalence_and_readonly_preview(self):
        self.pdf_setup()
        source = self.root / "scan-20240301.pdf"
        source.write_bytes(b"offline PDF")
        state = self.root / "new.json"
        archive = self.root / "archive"
        result = self.run_new("pdf-with-openai", "--dry-run", "--state-file", state, source,
                              env={"PAPERWORK_DIR": str(archive)})
        self.assertEqual(result.returncode, 0, result.stderr)
        new = json.loads(state.read_text())
        payload = json.loads((self.home / "payloads.jsonl").read_text())
        (self.home / "payloads.jsonl").unlink()
        old_state = self.root / "old.json"
        result = self.run_script(
            self.repo / "organization/organize-pdf-with-openai.sh", "--dry-run",
            "--state-file", old_state, source, env={"PAPERWORK_DIR": str(archive)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        old = json.loads(old_state.read_text())
        for key in ("file", "context", "plan", "action"):
            lhs, rhs = new[key], old[key]
            if key == "plan":
                lhs, rhs = dict(lhs), dict(rhs)
                lhs.pop("rationale")
                rhs.pop("rationale")
            self.assertEqual(lhs, rhs, key)
        old_payload = json.loads((self.home / "payloads.jsonl").read_text())
        self.assertEqual(payload["messages"][0], old_payload["messages"][0])
        self.assertEqual(payload["response_format"], old_payload["response_format"])
        self.assertEqual(payload["model"], old_payload["model"])
        # New preview had not created the archive at all (legacy run above did).
        second_archive = self.root / "preview-only"
        result = self.run_new("pdf-with-openai", "--dry-run", source,
                              env={"PAPERWORK_DIR": str(second_archive)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(second_archive.exists())
        self.assertEqual(source.read_bytes(), b"offline PDF")

    def test_pdf_move_metadata_and_partial_failure(self):
        self.pdf_setup()
        source = self.root / "\u00e9 ;$(not-executed).pdf"
        source.write_bytes(b"original PDF")
        source.chmod(0o640)
        os.utime(source, ns=(1234567890000000000, 1234567890000000000))
        state = self.root / "plan.json"
        archive = self.root / "archive"
        result = self.run_new("pdf-with-openai", "--move", "--state-file", state, source,
                              env={"PAPERWORK_DIR": str(archive)})
        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads(state.read_text())
        published = Path(document["action"]["appliedPath"])
        self.assertEqual(published.read_bytes(), b"original PDF")
        self.assertEqual(published.stat().st_mode & 0o777, 0o640)
        self.assertEqual(published.stat().st_mtime_ns, 1234567890000000000)
        self.assertFalse(source.exists())
        calls = json_stream((self.root / "trace.jsonl").read_text())
        finder = next(c for c in calls if c[0] == "osascript")
        self.assertEqual(finder[-2:], [f"file://{published}", "A 'monthly' statement."])
        source.write_bytes(b"second")
        self.fake("osascript", "sys.exit(8)")
        result = self.run_new("pdf-with-openai", "--move", "--state-file", state, source,
                              env={"PAPERWORK_DIR": str(archive)})
        self.assertEqual(result.returncode, 1)
        partial = json.loads(state.read_text())
        self.assertFalse(partial["action"]["completed"])
        self.assertTrue(source.exists())
        self.assertTrue(Path(partial["action"]["appliedPath"]).exists())
        self.assertIn("-001.pdf", partial["action"]["appliedPath"])
        self.assertIn("error", partial["metadata"])

    def test_pdf_ocr_isolated_and_failure_retains_source(self):
        self.pdf_setup()
        source = self.root / "scan.pdf"
        source.write_bytes(b"before OCR")
        self.fake("pdftotext", """
print('OCR text' if pathlib.Path(sys.argv[-2]).read_bytes() == b'after OCR' else '')
""")
        self.fake("ocrmypdf", """
pathlib.Path(sys.argv[-1]).write_bytes(b'after OCR')
""")
        result = self.run_new("pdf-with-openai", "--dry-run", "--state-file", self.root / "state.json", source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(source.read_bytes(), b"before OCR")
        result = self.run_new("pdf-with-openai", "--move", "--state-file", self.root / "ocr-plan.json", source)
        self.assertEqual(result.returncode, 0, result.stderr)
        action = json.loads((self.root / "ocr-plan.json").read_text())["action"]
        self.assertEqual(Path(action["appliedPath"]).read_bytes(), b"after OCR")
        self.assertFalse(source.exists())
        source.write_bytes(b"before OCR")
        self.fake("ocrmypdf", "sys.exit(7)")
        result = self.run_new("pdf-with-openai", "--move", source)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(source.read_bytes(), b"before OCR")

    def test_pdf_self_collision_and_backfill_original_hint(self):
        self.pdf_setup()
        archive = self.root / "archive"
        source = archive / "Cars/Jeep/2024-02-29 - Jeep - Monthly Statement.pdf"
        source.parent.mkdir(parents=True)
        source.write_bytes(b"already filed")
        work = self.root / "work.pdf"
        work.write_bytes(source.read_bytes())
        state = self.root / "state.json"
        result = self.run_new("pdf-with-openai", "--dry-run", "--state-file", state, work,
                              env={"PAPERWORK_DIR": str(archive), "ORIGINAL_FILE_PATH": str(source)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(state.read_text())["action"]["proposedPath"], str(source))
        result = self.run_new("pdf-with-openai", "--move", "--state-file", state, source,
                              env={"PAPERWORK_DIR": str(archive)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(source.read_bytes(), b"already filed")
        self.assertEqual(list(source.parent.glob("*.pdf")), [source])

    def test_pdf_low_confidence_path_sanitization(self):
        response = self.pdf_setup()
        response["analysis"]["confidence"] = 0.69
        response["categorization"].update(sender="Cars > FCA US LLC", department="../Unit", category="Cars/Other")
        self.env["OFFLINE_RESPONSE"] = json.dumps(response)
        source = self.root / "input.pdf"
        source.write_bytes(b"pdf")
        state = self.root / "plan.json"
        result = self.run_new("pdf-with-openai", "--state-file", state, source)
        self.assertEqual(result.returncode, 0, result.stderr)
        action = json.loads(state.read_text())["action"]
        self.assertIn("/_Needs Review/Cars/", action["appliedPath"])
        self.assertTrue(action["finderComment"].startswith("[Needs Review"))
        self.assertNotIn("..", action["appliedPath"])

    def test_guitar_differential_requests_and_output(self):
        chart = self.chart_tools()
        raw = self.root / "raw.txt"
        raw.write_text("raw chart")
        result = self.run_new("guitar-tabs", "--debug", raw)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "Artist - Song-debug.txt").read_text(), chart)
        new_payloads = json_stream((self.home / "payloads.jsonl").read_text())
        (self.home / "payloads.jsonl").unlink()
        for path in ("organization/organize-guitar-tabs.sh", "organization/organize-guitar-tabs-format.py",
                     "ai/open-ai-functions.sh", "utilities/logging.sh"):
            self.install(path)
        result = self.run_script(self.repo / "organization/organize-guitar-tabs.sh", "--debug", raw)
        self.assertEqual(result.returncode, 0, result.stderr)
        old_payloads = json_stream((self.home / "payloads.jsonl").read_text())
        self.assertEqual(new_payloads, old_payloads)
        self.assertTrue(raw.exists())

    def test_guitar_collision_and_invalid_response_retention(self):
        chart = self.chart_tools()
        raw = self.root / "raw.txt"
        output = self.root / "output"
        output.mkdir()
        existing = output / "Artist - Song.txt"
        existing.write_text("existing chart")
        raw.write_text("raw")
        result = self.run_new("guitar-tabs", raw, env={"GUITAR_TAB_OUTPUT": str(output)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(existing.read_text(), "existing chart")
        self.assertEqual((output / "Artist - Song-001.txt").read_text(), chart)
        self.assertFalse(raw.exists())
        raw.write_text("retry raw")
        self.fake("curl", """print(json.dumps({'choices':[{'message':{'content':'not JSON'}}]}))""")
        result = self.run_new("guitar-tabs", raw, env={"GUITAR_TAB_OUTPUT": str(output)})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(raw.read_text(), "retry raw")

    def test_video_differential_requests_scenes_markdown_and_resume(self):
        self.video_setup()
        old_dir = self.root / "old"
        new_dir = self.root / "new"
        old_dir.mkdir()
        new_dir.mkdir()
        old_source = old_dir / "20240704 family.mov"
        new_source = new_dir / old_source.name
        old_source.write_bytes(b"video")
        new_source.write_bytes(b"video")
        result = self.run_script(self.repo / "organization/organize-video-imports.sh", old_source)
        self.assertEqual(result.returncode, 0, result.stderr)
        old_payloads = json_stream((self.home / "payloads.jsonl").read_text())
        (self.home / "payloads.jsonl").unlink()
        result = self.run_new("video-imports", new_source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(new_source.with_suffix(".md").read_bytes(), old_source.with_suffix(".md").read_bytes())
        new_payloads = json_stream((self.home / "payloads.jsonl").read_text())
        self.assertEqual(new_payloads, old_payloads)
        old_scenes = json_stream((old_dir / "_temp" / old_source.stem / "scenes.jsonl").read_text())
        new_scenes = json_stream((new_dir / "_temp" / new_source.stem / "scenes.jsonl").read_text())
        self.assertEqual(new_scenes, old_scenes)
        # Existing output is a no-inference, no-rewrite operation.
        before = new_source.with_suffix(".md").stat().st_mtime_ns
        self.fake("curl", "sys.exit(88)")
        result = self.run_new("video-imports", new_source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(new_source.with_suffix(".md").stat().st_mtime_ns, before)

    def test_video_audio_contract_and_transcript_resume(self):
        self.video_setup()
        self.fake("ffprobe", "print('60' if 'format=duration' in sys.argv else '0')")
        self.fake("ffmpeg", """
pattern = sys.argv[-1]
if '-vn' in sys.argv:
 pathlib.Path(pattern).write_bytes(b'offline audio')
else:
 for index in (1, 2, 3):
  pathlib.Path(pattern.replace('%05d', f'{index:05d}')).write_bytes(b'offline frame')
""")
        self.fake("curl", """
args = sys.argv[1:]
if '-F' in args:
 pathlib.Path(args[args.index('-o')+1]).write_text('Spoken date.\\r\\nMore text.\\n')
 print('200', end='')
else:
 payload = json.loads(pathlib.Path(args[args.index('-d')+1][1:]).read_text())
 content = 'Visible.'
 if payload['model'] != 'gpt-4o':
  content = json.dumps({'title':'Day','description':'Friends outdoors.','approximateDate':'unknown','approximateDateSource':'unknown'})
 print(json.dumps({'choices':[{'message':{'content':content}}]}))
""")
        source = self.root / "audio.mov"
        source.write_bytes(b"video")
        result = self.run_new("video-imports", source)
        self.assertEqual(result.returncode, 0, result.stderr)
        transcript = self.root / "_temp/audio/audio/audio_transcript.txt"
        self.assertEqual(transcript.read_bytes(), b"Spoken date.\nMore text.\n")
        source.with_suffix(".md").unlink()
        trace = self.root / "trace.jsonl"
        trace.write_text("")
        result = self.run_new("video-imports", source)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = json_stream(trace.read_text())
        self.assertFalse(any(c[0] == "ffmpeg" or (c[0] == "curl" and "-F" in c) for c in calls))
        self.assertEqual(sum(c[0] == "curl" for c in calls), 1)

    def test_video_partial_failure_and_cache_identity(self):
        self.video_setup()
        source = self.root / "video.mov"
        source.write_bytes(b"video")
        self.fake("ffprobe", "sys.exit(3)")
        result = self.run_new("video-imports", source)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(source.with_suffix(".md").exists())
        manifest = self.root / "_temp/video/workflow.json"
        self.assertEqual(json.loads(manifest.read_text())["status"], "failed")
        source.write_bytes(b"changed source")
        result = self.run_new("video-imports", source)
        self.assertEqual(result.returncode, 1)
        self.assertIn("identity", result.stderr)
        self.assertTrue(source.exists())

    def test_video_legacy_cache_is_retained_not_trusted(self):
        self.video_setup()
        source = self.root / "video.mov"
        source.write_bytes(b"video")
        cache = self.root / "_temp/video"
        cache.mkdir(parents=True)
        scenes = cache / "scenes.jsonl"
        scenes.write_text("legacy data")
        result = self.run_new("video-imports", source)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Unverified legacy", result.stderr)
        self.assertEqual(scenes.read_text(), "legacy data")

    def test_queue_copy_metadata_unique_and_newlines(self):
        source = self.root / "\u00e9 ;$(x)\npath.txt"
        source.write_bytes(b"payload")
        source.chmod(0o640)
        os.utime(source, ns=(1234567890000000000, 1234567890000000000))
        for _ in range(2):
            result = self.run_new("guitar-tabs", source, kind="wrapper")
            self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.rows()
        self.assertEqual(len(rows), 2)
        self.assertNotEqual(rows[0]["payload"], rows[1]["payload"])
        for row in rows:
            payload = Path(row["payload"])
            self.assertEqual(payload.read_bytes(), b"payload")
            self.assertEqual(payload.stat().st_mode & 0o777, 0o640)
            self.assertEqual(payload.stat().st_mtime_ns, source.stat().st_mtime_ns)
        self.assertEqual(source.read_bytes(), b"payload")
        self.assertEqual(self.paths().database.stat().st_mode & 0o777, 0o600)

    def test_queue_legacy_import_recover_batch_idempotent_and_invalid(self):
        source = self.root / "legacy.txt"
        source.write_text("raw")
        paths = self.paths()
        paths.legacy.write_text(f"{source}\nrelative-path\n{source}\n")
        batch = Path(f"{paths.legacy}.processing.123")
        batch.write_text(f"{self.root / 'missing'}\n")
        with self.isolated():
            q = queue.Queue(paths)
            self.addCleanup(q.close)
            q.import_legacy()
            q.import_legacy()
            rows = q.rows()
            self.assertEqual(len(rows), 4)
            self.assertEqual(sum(r["status"] == "failed" for r in rows), 1)
            self.assertEqual(sum(r["payload"] == str(source) for r in rows), 2)
            self.assertTrue(batch.exists())
            self.assertTrue(list(self.home.glob(paths.legacy.name + ".legacy-*")))

    def test_queue_stale_legacy_locks_are_never_removed(self):
        paths = self.paths()
        legacy_lock = Path(f"{paths.legacy}.lock")
        legacy_lock.mkdir()
        (legacy_lock / "pid").write_text("999999")
        os.utime(legacy_lock, (1, 1))
        result = self.run_new("guitar-tabs", kind="worker")
        self.assertEqual(result.returncode, 1)
        self.assertTrue((legacy_lock / "pid").exists())
        self.assertIn("Legacy lock exists", result.stderr)

    def test_queue_failures_interruption_status_and_explicit_retry(self):
        source = self.root / "raw.txt"
        source.write_text("raw")
        self.assertEqual(self.run_new("guitar-tabs", source, kind="wrapper").returncode, 0)
        result = self.run_new("guitar-tabs", kind="worker")
        self.assertEqual(result.returncode, 1)
        row = self.rows()[0]
        self.assertEqual(row["status"], "failed")
        self.assertEqual(row["attempts"], 1)
        self.assertTrue(Path(row["payload"]).exists())
        self.assertEqual(self.cli("retry", "guitar-tabs", row["id"]).returncode, 0)
        self.chart_tools()
        result = self.run_new("guitar-tabs", kind="worker")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rows()[0]["status"], "done")
        self.assertTrue(source.exists())
        with self.isolated():
            q = queue.Queue(self.paths())
            self.addCleanup(q.close)
            q.db.execute("UPDATE jobs SET status='running'")
        result = self.run_new("guitar-tabs", kind="worker")
        self.assertEqual(result.returncode, 1)
        row = self.rows()[0]
        self.assertEqual(row["status"], "failed")
        self.assertIn("interrupted", row["error"])
        result = self.cli("retry", "guitar-tabs", row["id"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("published output", result.stderr)

    def test_concurrent_enqueue_and_workers_no_lost_jobs(self):
        self.chart_tools()
        source = self.root / "raw.txt"
        source.write_text("raw chart")
        def enqueue_one(_):
            return self.run_new("guitar-tabs", source, kind="wrapper")
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(enqueue_one, range(8)))
        self.assertTrue(all(r.returncode == 0 for r in results), [r.stderr for r in results])
        def worker(_):
            return self.run_new("guitar-tabs", kind="worker")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(worker, n) for n in range(2)]
            # Enqueue while at least one worker may be processing.
            later = enqueue_one(8)
            results = [f.result() for f in futures]
        self.assertEqual(later.returncode, 0, later.stderr)
        self.assertTrue(all(r.returncode == 0 for r in results), [r.stderr for r in results])
        rows = self.rows()
        self.assertEqual(len(rows), 9)
        self.assertTrue(all(r["status"] == "done" and r["attempts"] == 1 for r in rows), rows)
        output = self.home / "Documents/Guitar Tabs"
        self.assertEqual(len(list(output.glob("*.txt"))), 9)

    def test_worker_sigterm_retains_job_and_only_stops_owned_child(self):
        source = self.root / "raw.txt"
        source.write_text("raw chart")
        self.fake("curl", """
import time
pathlib.Path(os.environ['HOME'],'curl-started').write_text(str(os.getpid()))
time.sleep(20)
""")
        self.run_new("guitar-tabs", source, kind="wrapper")
        process = subprocess.Popen(
            [self.zsh, "-f", str(ROOT / "hazel/hazel-organize-guitar-tabs-worker.sh")],
            env=self.env | {"AUTOMATION_TOOL_PATH": str(self.bin), "AUTOMATION_PYTHON": sys.executable},
            cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        def cleanup():
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=10)
        self.addCleanup(cleanup)
        deadline = time.monotonic() + 5
        started = self.home / "curl-started"
        while not started.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(started.exists())
        curl_pid = int(started.read_text())
        process.send_signal(signal.SIGTERM)
        _, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 130, stderr)
        row = self.rows()[0]
        self.assertEqual(row["status"], "failed")
        self.assertTrue(Path(row["payload"]).exists())
        # Child organizer received termination and in turn reaped its own curl.
        deadline = time.monotonic() + 3
        alive = True
        while alive and time.monotonic() < deadline:
            try:
                os.kill(curl_pid, 0)
            except ProcessLookupError:
                alive = False
            else:
                time.sleep(0.02)
        self.assertFalse(alive, "owned curl child was not reaped")

    def test_symlink_boundaries_and_missing_tools(self):
        real = self.root / "real.txt"
        real.write_text("raw")
        link = self.root / "link.txt"
        link.symlink_to(real)
        result = self.run_new("guitar-tabs", link)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Symlink", result.stderr)
        self.assertEqual(real.read_text(), "raw")
        (self.bin / "curl").unlink()
        result = self.run_new("guitar-tabs", real)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Missing required command: curl", result.stderr)
        self.assertTrue(real.exists())
        self.paths().database.symlink_to(real)
        result = self.run_new("guitar-tabs", real, kind="wrapper")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(real.read_text(), "raw")

    def test_stripped_wrapper_environment_and_interpreter_errors(self):
        source = self.root / "input.txt"
        source.write_text("raw")
        result = self.run_new(
            "guitar-tabs", source, kind="wrapper",
            env={"PATH": "/usr/bin:/bin", "AUTOMATION_PYTHON": sys.executable},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_new(
            "guitar-tabs", source, kind="wrapper",
            env={"PATH": "/usr/bin:/bin", "AUTOMATION_PYTHON": ""},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_new("guitar-tabs", "--help", env={"AUTOMATION_PYTHON": "/missing/python"})
        self.assertEqual(result.returncode, 127)
        self.assertIn("Python 3.11+", result.stderr)
        for family in queue.FAMILIES:
            result = self.run_new(family, "--help")
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.run_new(family, "--unknown")
            self.assertEqual(result.returncode, 1)

    def test_atomic_no_clobber_and_lock_release_after_process_death(self):
        source = self.root / "source"
        source.write_bytes(b"data")
        destination = self.root / "published"
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            paths = list(pool.map(lambda _: runtime.publish_copy(source, destination), range(8)))
        self.assertEqual(len(set(paths)), 8)
        self.assertTrue(all(p.read_bytes() == b"data" for p in paths))
        lockfile = self.root / "worker.lock"
        program = (
            "from pathlib import Path; import time; from automation_lib.runtime import lock; "
            f"handle=lock(Path({str(lockfile)!r})); handle.__enter__(); "
            f"Path({str(self.root / 'locked')!r}).touch(); time.sleep(20)"
        )
        process = subprocess.Popen([sys.executable, "-c", program], cwd=ROOT, env=self.env)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        deadline = time.monotonic() + 5
        while not (self.root / "locked").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue((self.root / "locked").exists())
        process.kill()
        process.wait(timeout=5)
        with runtime.lock(lockfile, blocking=False):
            self.assertTrue(lockfile.exists())

    def test_atomic_failure_preserves_previous_state_and_cleans_owned_temps(self):
        state = self.root / "state.json"
        runtime.atomic_json(state, {"last": "good"})
        with patch("automation_lib.runtime.os.replace", side_effect=OSError("offline failure")):
            with self.assertRaises(OSError):
                runtime.atomic_json(state, {"last": "bad"})
        self.assertEqual(json.loads(state.read_text()), {"last": "good"})
        self.assertEqual(list(self.root.glob(".hazel-write-*")), [])
        source = self.root / "source"
        source.write_bytes(b"retained")
        with patch("automation_lib.runtime.os.link", side_effect=OSError("offline failure")):
            with self.assertRaises(OSError):
                runtime.publish_copy(source, self.root / "destination")
        self.assertEqual(source.read_bytes(), b"retained")
        self.assertFalse((self.root / "destination").exists())
        self.assertEqual(list(self.root.glob(".publish-*")), [])

    def test_full_length_filenames_publish_and_checkpoint(self):
        source = self.root / "source"
        source.write_bytes(b"complete")
        target = self.root / ("\u00e9" * 180 + ".txt")
        first = runtime.publish_copy(source, target)
        second = runtime.publish_copy(source, target)
        self.assertNotEqual(first, second)
        for path in (first, second):
            self.assertLessEqual(len(path.name.encode()), 255)
            self.assertEqual(path.read_bytes(), b"complete")
        full_state = self.root / ("s" * 250 + ".json")
        runtime.atomic_json(full_state, {"complete": True})
        self.assertEqual(json.loads(full_state.read_text()), {"complete": True})
        self.video_setup()
        video_source = self.root / ("v" * 251 + ".mov")
        video_source.write_bytes(b"video")
        result = self.run_new("video-imports", video_source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(video_source.with_suffix(".md").is_file())

    def test_credentials_environment_op_and_keychain_contracts(self):
        self.env.pop("OPENAI_API_KEY")
        self.env["OP_KEY_NAME"] = "offline/item"
        self.fake("security", """
service = sys.argv[-1]
print('offline-service-token' if service == 'op-service-token-openai-api' else 'offline-fallback-key')
""")
        self.fake("op", """
assert os.environ['OP_SERVICE_ACCOUNT_TOKEN'] == 'offline-service-token'
print('offline-op-key')
""")
        log = logging.getLogger("offline-auth")
        with self.isolated():
            self.assertEqual(ai.Client(log).credentials(), "offline-op-key")
        calls = json_stream((self.root / "trace.jsonl").read_text())
        self.assertEqual(next(c for c in calls if c[0] == "op"), ["op", "read", "op://offline/item/credential"])
        self.fake("op", "sys.exit(7)")
        with self.isolated():
            self.assertEqual(ai.Client(log).credentials(), "offline-fallback-key")
        self.fake("security", "sys.exit(8)")
        with self.isolated():
            with self.assertRaisesRegex(runtime.AutomationError, "OPENAI_API_KEY is not set"):
                ai.Client(log).credentials()

    def test_copilot_pdf_uses_preserved_provider_and_no_openai_credentials(self):
        self.pdf_setup()
        self.env.pop("OPENAI_API_KEY")
        config = self.home / ".copilot/mcp-config.json"
        config.parent.mkdir()
        config.write_text(json.dumps({"mcpServers": {"server with space": {}, "second": {}}}))
        self.fake("copilot", """
print(json.dumps({'type':'assistant.message','data':{'content':'```json\\n'+os.environ['OFFLINE_RESPONSE']+'\\n```'}}))
""")
        source = self.root / "input.pdf"
        source.write_bytes(b"pdf")
        result = self.run_new(
            "pdf-with-openai", "--dry-run", "--state-file", self.root / "state.json", source,
            env={"AI_PROVIDER": "copilot", "COPILOT_MODEL": "gpt-5.4", "AI_DEBUG_DUMP": str(self.root / "request.json")},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = json_stream((self.root / "trace.jsonl").read_text())
        self.assertFalse(any(c[0] in ("curl", "op", "security") for c in calls))
        call = next(c for c in calls if c[0] == "copilot")
        self.assertIn("server with space", call)
        self.assertIn("--disable-builtin-mcps", call)
        self.assertIn("--no-custom-instructions", call)
        self.assertFalse(Path(call[call.index("-C") + 1]).exists())
        self.assertEqual(json.loads((self.root / "request.json").read_text())["response_format"],
                         ai.PROMPTS["pdf_response_format"])

    def test_worker_launch_failure_keeps_accepted_job(self):
        source = self.root / "input.txt"
        source.write_text("raw")
        with self.isolated(), patch("automation_lib.queue.subprocess.Popen", side_effect=OSError("offline launch failure")):
            for _ in range(2):
                with self.assertRaisesRegex(runtime.AutomationError, "retained"), patch("sys.stdout", new=io.StringIO()):
                    queue.enqueue("guitar-tabs", str(source))
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "pending")
        self.assertEqual(Path(rows[0]["payload"]).read_text(), "raw")
        self.chart_tools()
        self.assertEqual(self.run_new("guitar-tabs", kind="worker").returncode, 0)
        with self.isolated(), patch("automation_lib.queue.subprocess.Popen"), patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(queue.enqueue("guitar-tabs", str(source)), 0)
            self.assertEqual(len(self.rows()), 1)
            self.assertEqual(queue.enqueue("guitar-tabs", str(source)), 0)
        self.assertEqual(len(self.rows()), 2)  # Only unacknowledged handoffs are reused.
        self.assertEqual(len(list((self.home / "Documents/Guitar Tabs").glob("*.txt"))), 1)

    def test_failed_handoff_does_not_reuse_changed_input(self):
        source = self.root / "input.txt"
        source.write_text("original")
        with self.isolated(), patch("automation_lib.queue.subprocess.Popen", side_effect=OSError("offline launch failure")):
            for content in ("original", "replacement content"):
                source.write_text(content)
                with self.assertRaises(runtime.AutomationError), patch("sys.stdout", new=io.StringIO()):
                    queue.enqueue("guitar-tabs", str(source))
        rows = self.rows()
        self.assertEqual(len(rows), 2)
        self.assertEqual({Path(row["payload"]).read_text() for row in rows}, {"original", "replacement content"})

    def test_interrupted_handoff_reuses_accepted_job(self):
        source = self.root / "input.txt"
        source.write_text("raw")
        with self.isolated(), patch("automation_lib.queue.subprocess.Popen", side_effect=runtime.AutomationInterrupted("test")):
            for _ in range(2):
                with self.assertRaises(runtime.AutomationInterrupted), patch("sys.stdout", new=io.StringIO()):
                    queue.enqueue("guitar-tabs", str(source))
        self.assertEqual(len(self.rows()), 1)

    def test_concurrent_hazel_retries_reuse_one_failed_handoff(self):
        source = self.root / "input.txt"
        source.write_text("raw")

        def enqueue():
            with self.assertRaises(runtime.AutomationError):
                queue.enqueue("guitar-tabs", str(source))

        with self.isolated(), patch("automation_lib.queue.subprocess.Popen", side_effect=OSError("offline launch failure")):
            with patch("sys.stdout", new=io.StringIO()), concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                for future in [pool.submit(enqueue) for _ in range(4)]:
                    future.result(timeout=10)
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual(len(list((self.home / "Documents/Guitar Tabs/_temp").iterdir())), 1)

    def test_saved_hazel_rule_order_through_direct_executable_paths(self):
        environment = {
            "PATH": "/usr/bin:/bin", "AUTOMATION_PYTHON": "",
            "AUTOMATION_TOOL_PATH": str(self.bin), "HAZEL_NO_WORKER": "1",
        }

        def invoke(relative, *args):
            path = ROOT / relative
            self.assertTrue(os.access(path, os.X_OK), relative)
            result = subprocess.run(
                [str(path), *map(str, args)], cwd=self.root, env=self.env | environment,
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return result

        def move(source, folder):
            folder.mkdir(parents=True, exist_ok=True)
            return source.rename(folder / source.name)

        self.pdf_setup()
        self.fake("ocrmypdf", "pathlib.Path(sys.argv[-1]).write_bytes(b'ocr PDF')")
        scans = self.home / "Documents/Scans"
        (scans / "OCR").mkdir(parents=True)
        scan = scans / "OCR/scan \u00e9 ;$(not-executed).pdf"
        scan.write_bytes(b"scan")
        invoke("media/pdf-ocr-text.sh", scan)
        scan = move(scan, scans / "AI")
        invoke("hazel/hazel-organize-pdf-with-openai-wrapper.sh", scan)
        moved_scan = move(scan, scans / "Done")
        invoke("hazel/hazel-organize-pdf-with-openai-worker.sh")
        self.assertFalse(scan.exists())
        self.assertEqual(moved_scan.read_bytes(), b"ocr PDF")

        self.chart_tools()
        tabs = self.home / "Documents/Guitar Tabs"
        (tabs / "_import").mkdir(parents=True)
        chart = tabs / "_import/raw \u00e9 ;$(not-executed).txt"
        chart.write_text("raw chart")
        invoke("hazel/hazel-organize-guitar-tabs-wrapper.sh", chart)
        moved_chart = move(chart, tabs / "_trash")
        invoke("hazel/hazel-organize-guitar-tabs-worker.sh")
        self.assertFalse(chart.exists())
        self.assertEqual(moved_chart.read_text(), "raw chart")

        self.video_setup()
        video_locations = (
            self.home / "Documents/Sort/Videos",
            self.root / "Volumes/Videos/Import/Organize",
        )
        for folder in video_locations:
            (folder / "Import").mkdir(parents=True)
            source = folder / "Import/video \u00e9 ;$(not-executed).mov"
            source.write_bytes(b"video")
            moved_video = move(source, folder / "Done")
            invoke("hazel/hazel-organize-video-imports-wrapper.sh", moved_video)
            invoke("hazel/hazel-organize-video-imports-worker.sh")
            self.assertTrue(moved_video.with_suffix(".md").is_file())
            self.assertEqual(moved_video.read_bytes(), b"video")
        for family in queue.FAMILIES:
            rows = self.rows(family)
            self.assertEqual(len(rows), 2 if family == "video-imports" else 1)
            self.assertTrue(all(row["status"] == "done" for row in rows))
            for row in rows:
                receipt = self.paths(family).jobs / row["id"] / "publication.json"
                output = Path(json.loads(receipt.read_text())["appliedPath"])
                self.assertTrue(output.is_file())
                if family == "pdf-with-openai":
                    self.assertEqual(output.read_bytes(), b"ocr PDF")

    def test_each_family_enqueue_worker_and_receipt_contract(self):
        for family in queue.FAMILIES:
            with self.subTest(family=family):
                if family == "pdf-with-openai":
                    self.pdf_setup()
                    source = self.root / "scan.pdf"
                elif family == "guitar-tabs":
                    self.chart_tools()
                    source = self.root / "raw.txt"
                else:
                    self.video_setup()
                    source = self.root / "video.mov"
                source.write_bytes(b"owned source")
                result = self.run_new(family, source, kind="wrapper")
                self.assertEqual(result.returncode, 0, result.stderr)
                result = self.run_new(family, kind="worker")
                self.assertEqual(result.returncode, 0, result.stderr)
                row = self.rows(family)[0]
                self.assertEqual(row["status"], "done")
                self.assertEqual(row["attempts"], 1)
                self.assertTrue(source.exists())  # Hazel still owns its original.
                self.assertEqual(Path(row["payload"]).exists(), family == "video-imports")
                receipt = self.paths(family).jobs / row["id"] / "publication.json"
                published = json.loads(receipt.read_text())
                self.assertTrue(Path(published["appliedPath"]).exists())
                self.assertEqual(len(published["file"]["sha256"]), 64)
                if family == "pdf-with-openai":
                    state = json.loads((receipt.parent / "plan.json").read_text())
                    self.assertEqual(state["action"]["appliedPath"], published["appliedPath"])
                    self.assertTrue(state["action"]["completed"])

    def test_detached_worker_starts_and_drains_in_owned_home(self):
        self.chart_tools()
        source = self.root / "raw.txt"
        source.write_text("raw")
        real_popen = subprocess.Popen
        processes = []
        def launch(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            processes.append(process)
            return process
        with self.isolated(), patch("automation_lib.queue.subprocess.Popen", side_effect=launch):
            with patch("sys.stdout", new=io.StringIO()):
                self.assertEqual(queue.enqueue("guitar-tabs", str(source)), 0)
        self.assertEqual(len(processes), 1)
        process = processes[0]
        def cleanup():
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)
        self.addCleanup(cleanup)
        self.assertIsNone(process.poll())
        self.assertEqual(os.getsid(process.pid), process.pid)
        self.assertEqual(process.wait(timeout=15), 0)
        self.assertEqual(self.rows()[0]["status"], "done")
        self.assertTrue((self.home / "Documents/Guitar Tabs/Artist - Song.txt").exists())

    def test_worker_recovery_waits_for_orphaned_organizer_lease(self):
        self.chart_tools()
        source = self.root / "raw.txt"
        source.write_text("raw")
        # The owned fake transport finishes itself; no orphan is left after test.
        self.fake("curl", """
import time
pathlib.Path(os.environ['HOME'],'started').write_text('yes')
time.sleep(0.7)
content = {'artist':'Artist','song_title':'Song','formatted_tab':os.environ['CHART']}
print(json.dumps({'choices':[{'message':{'content':json.dumps(content)}}]}))
""")
        self.run_new("guitar-tabs", source, kind="wrapper")
        process = subprocess.Popen(
            [sys.executable, "-I", str(ROOT / "utilities/hazel-python.py"), "worker", "guitar-tabs"],
            cwd=self.root, env=self.env | {"AUTOMATION_TOOL_PATH": str(self.bin)},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.addCleanup(lambda: process.wait(timeout=5))
        deadline = time.monotonic() + 5
        while not (self.home / "started").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue((self.home / "started").exists())
        process.kill()
        process.wait(timeout=5)
        lock_path = Path(f"{self.paths().legacy}.python-worker.lock")
        with self.assertRaises(BlockingIOError):
            with runtime.lock(lock_path, blocking=False):
                pass
        # New worker blocks on the inherited kernel lease, then marks the
        # interrupted job failed (never races an organizer still publishing).
        result = self.run_new("guitar-tabs", kind="worker")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.rows()[0]["status"], "failed")

    def test_source_change_during_inference_is_not_deleted_or_published(self):
        self.chart_tools()
        source = self.root / "input.txt"
        source.write_text("before")
        self.env["MUTATE_SOURCE"] = str(source)
        self.fake("curl", """
pathlib.Path(os.environ['MUTATE_SOURCE']).write_text('changed by owner during inference')
content = {'artist':'Artist','song_title':'Song','formatted_tab':os.environ['CHART']}
print(json.dumps({'choices':[{'message':{'content':json.dumps(content)}}]}))
""")
        result = self.run_new("guitar-tabs", source)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Input changed", result.stderr)
        self.assertEqual(source.read_text(), "changed by owner during inference")
        self.assertFalse((self.home / "Documents/Guitar Tabs/Artist - Song.txt").exists())

    def test_missing_legacy_paths_and_malformed_batches_stay_visible(self):
        paths = self.paths()
        paths.legacy.write_text(f"{self.root / 'missing'}\n")
        result = self.run_new("guitar-tabs", kind="worker")
        self.assertEqual(result.returncode, 1)
        row = self.rows()[0]
        self.assertEqual(row["status"], "failed")
        self.assertIn("Input file not found", row["error"])
        paths.legacy.write_bytes(b"\xff\n")
        result = self.run_new("guitar-tabs", kind="worker")
        self.assertEqual(result.returncode, 1)
        self.assertIn("UTF-8", result.stderr)
        self.assertTrue(any(p.read_bytes() == b"\xff\n" for p in self.home.glob(paths.legacy.name + ".legacy-*")))

    def test_malformed_database_jobs_cannot_escape_job_root(self):
        source = self.root / "input.txt"
        source.write_text("retained")
        with self.isolated():
            q = queue.Queue(self.paths())
            self.addCleanup(q.close)
            first = q.add(source)
            second = q.add(source)
            q.db.execute("UPDATE jobs SET id='../escape' WHERE id=?", (first,))
            q.db.execute("UPDATE jobs SET payload='relative-path' WHERE id=?", (second,))
        result = self.run_new("guitar-tabs", kind="worker")
        self.assertEqual(result.returncode, 1)
        rows = self.rows()
        self.assertTrue(all(row["status"] == "failed" for row in rows))
        self.assertTrue(any("Malformed job ID" in row["error"] for row in rows))
        self.assertTrue(any("Malformed job payload" in row["error"] for row in rows))
        self.assertTrue(source.exists())
        self.assertFalse((self.home / "escape").exists())

    def test_relative_paths_and_standalone_ocr_exit_contract(self):
        self.chart_tools()
        source = self.root / "-raw.txt"
        source.write_text("raw")
        result = self.run_new("guitar-tabs", "--debug", "--", source.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(source.exists())
        self.fake("ocrmypdf", "sys.exit(17)")
        result = self.run_script(
            ROOT / "media/pdf-ocr-text.sh", source,
            env={"AUTOMATION_PYTHON": sys.executable, "AUTOMATION_TOOL_PATH": str(self.bin)},
        )
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertTrue((self.home / "Library/Logs/automation-scripts/media/pdf-ocr-text.log").exists())
        calls = json_stream((self.root / "trace.jsonl").read_text())
        call = next(c for c in calls if c[0] == "ocrmypdf")
        self.assertEqual(call[1:], ["-l", "eng", "--output-type", "pdf", "--redo-ocr", "--rotate-pages", str(source), str(source)])

    def test_video_frame_failure_retries_only_missing_frames(self):
        self.video_setup()
        source = self.root / "video.mov"
        source.write_bytes(b"video")
        self.fake("curl", """
args = sys.argv[1:]
payload = json.loads(pathlib.Path(args[args.index('-d')+1][1:]).read_text())
if '00:00:30' in json.dumps(payload):
 print(json.dumps({'error':{'message':'offline frame failure'}}))
else:
 print(json.dumps({'choices':[{'message':{'content':'Visible.'}}]}))
""")
        result = self.run_new("video-imports", source)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(source.with_suffix(".md").exists())
        scenes = self.root / "_temp/video/scenes.jsonl"
        self.assertEqual(len(json_stream(scenes.read_text())), 1)
        self.video_setup()
        result = self.run_new("video-imports", source)
        self.assertEqual(result.returncode, 0, result.stderr)
        payloads = json_stream((self.home / "payloads.jsonl").read_text())
        self.assertEqual(len(payloads), 3)  # two missing frames + summary
        self.assertEqual(len(json_stream(scenes.read_text())), 3)


class PureTests(unittest.TestCase):
    def test_python_311_grammar(self):
        import ast
        for path in (ROOT / "automation_lib").glob("*.py"):
            ast.parse(path.read_text(), filename=str(path), feature_version=(3, 11))

    def test_unicode_byte_bounded_collision_names(self):
        name = Path("/unused") / ("\u00e9" * 180 + ".pdf")
        for counter in (0, 1, 999, 1000):
            candidate = runtime.candidate_path(name, counter)
            self.assertLessEqual(len(candidate.name.encode()), 255)
            self.assertTrue(candidate.name.endswith(".pdf"))

    def test_threshold_and_malformed_confidence(self):
        for value, expected in ((0.7, False), (0.6999, True), (None, True),
                                ("garbled", True), (True, True), (2, True), (float("nan"), True)):
            self.assertEqual(paperwork.low_confidence(value, 0.7), expected)

    def test_date_candidates_and_leap_days(self):
        self.assertEqual(paperwork.scanned_timestamp("letter-02292024.pdf"), "2024-02-29T00-00-00")
        self.assertIsNone(paperwork.scanned_timestamp("letter-02292023.pdf"))
        candidates = paperwork.filename_dates("2024_02_29 202402 2024-02.pdf")
        self.assertEqual([c["precision"] for c in candidates], ["day", "month"])

    def test_request_model_compatibility(self):
        with patch.dict(os.environ, {"OPENAI_MODEL": "gpt-5.4", "OPENAI_REASONING_EFFORT": "low"}, clear=True):
            body = ai.normalized_request({"temperature": 0.2, "messages": []})
            self.assertEqual(body, {"model": "gpt-5.4", "messages": [], "reasoning_effort": "low"})
            body = ai.normalized_request({
                "model": "other-model", "messages": [{"content": "Document"}],
                "response_format": {"type": "json_schema", "json_schema": {"schema": {"type": "object"}}},
            })
            self.assertEqual(body["response_format"], {"type": "json_object"})
            self.assertIn('{"type":"object"}', body["messages"][0]["content"])

    def test_parser_does_not_fabricate_success(self):
        for raw in ('"not an object"', "null", "{}", '{"formatted_tab":""}', "{broken"):
            with self.assertRaises(runtime.AutomationError):
                guitar.parse_chart(raw)
        parsed = guitar.parse_chart('{"artist":"A","song_title":"S","formatted_tab":"raw\nline"}')
        self.assertEqual(parsed, ("A", "S", "raw\nline"))


if __name__ == "__main__":
    unittest.main()
