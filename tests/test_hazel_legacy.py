"""Offline characterization of the approved production baseline, not live tools."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASELINE = "d84f07f0e500489e926f846da2657c89ea37c2a7"


def baseline(path):
    return subprocess.run(
        ["git", "show", f"{BASELINE}:{path}"], cwd=ROOT,
        check=True, capture_output=True, text=True,
    ).stdout


def json_stream(text):
    result = []
    decoder = json.JSONDecoder()
    while text.strip():
        value, end = decoder.raw_decode(text.lstrip())
        result.append(value)
        text = text.lstrip()[end:]
    return result


class LegacyContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hazel-contract-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.repo = self.home / "src/automation-scripts"
        self.repo.mkdir(parents=True)
        self.zsh = shutil.which("zsh")
        self.env = {
            "HOME": str(self.home), "PATH": str(self.bin), "USER": "offline-test",
            "TMPDIR": str(self.root), "OPENAI_API_KEY": "offline-placeholder",
            "NO_COLOR": "1", "REVEAL_IN_FINDER": "false",
            "PYTHONDONTWRITEBYTECODE": "1", "TRACE_FILE": str(self.root / "trace.jsonl"),
        }
        for tool in ("jq", "mkdir", "rmdir", "rm", "cp", "mv", "date", "basename",
                     "dirname", "cat", "sed", "tr", "head", "tail", "mktemp",
                     "stat", "tee", "find", "wc", "cksum", "awk", "grep", "paste",
                     "perl", "base64", "sleep", "whoami", "touch"):
            executable = shutil.which(tool)
            if executable:
                (self.bin / tool).symlink_to(executable)
        (self.bin / "zsh").symlink_to(self.zsh)
        (self.bin / "python").symlink_to(sys.executable)
        self.fake("bat", "print(sys.stdin.read(), end='')")
        for tool in ("open", "osascript", "op", "security", "curl", "ffmpeg",
                     "ffprobe", "pdftotext", "ocrmypdf", "copilot", "nohup"):
            self.fake(tool, "sys.exit(91)")
        (self.bin / "sleep").unlink()
        self.fake("sleep", "import time\ntime.sleep(0.02)")

    def fake(self, name, body):
        path = self.bin / name
        path.write_text(
            f"#!{sys.executable}\nimport json, os, pathlib, sys\n"
            "with open(os.environ['TRACE_FILE'], 'a') as trace:\n"
            " trace.write(json.dumps([pathlib.Path(sys.argv[0]).name, *sys.argv[1:]])+'\\n')\n"
            + body + "\n"
        )
        path.chmod(0o755)
        return path

    def install(self, path):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        # Legacy scripts prepend real Homebrew paths; remove only that discovery
        # in the disposable copy so a missing stub can never invoke a live tool.
        text = baseline(path).replace(
            'PATH="/opt/homebrew/bin/:/usr/local/bin:$PATH"', 'PATH="$PATH"'
        ).replace('PATH="/opt/homebrew/bin/:$PATH"', 'PATH="$PATH"')
        target.write_text(text)
        target.chmod(0o755)
        return target

    def run_script(self, path, *args, env=None):
        return subprocess.run(
            [self.zsh, "-f", str(path), *map(str, args)], cwd=self.root,
            env=self.env | (env or {}), capture_output=True, text=True, timeout=30,
        )

    def test_wrapper_copies_and_line_queue_contract(self):
        for family, directory in (("pdf-with-openai", "Scans"), ("guitar-tabs", "Guitar Tabs")):
            with self.subTest(family=family):
                wrapper = self.install(f"hazel/hazel-organize-{family}-wrapper.sh")
                worker = wrapper.with_name(f"hazel-organize-{family}-worker.sh")
                worker.write_text("#!/usr/bin/env zsh\nexit 0\n")
                worker.chmod(0o755)
                source = self.root / "input space - \u00e9;$(x).txt"
                source.write_text("preserved source")
                result = self.run_script(wrapper, source)
                self.assertEqual(result.returncode, 0, result.stderr)
                copied = self.home / f"Documents/{directory}/_temp" / source.name
                self.assertEqual(copied.read_text(), source.read_text())
                queue = self.home / f".hazel-organize-{family}-queue"
                self.assertEqual(queue.read_text(), f"{copied}\n")
                self.assertTrue(source.exists())

    def test_workers_argv_and_failure_loss(self):
        for family, expected in (
            ("pdf-with-openai", ["--move"]), ("guitar-tabs", []), ("video-imports", [])
        ):
            with self.subTest(family=family):
                worker = self.install(f"hazel/hazel-organize-{family}-worker.sh")
                source = self.root / f"{family} space.txt"
                source.write_text("retained")
                log = self.home / "Library/Logs"
                log.mkdir(parents=True, exist_ok=True)
                organizer = self.repo / f"organization/organize-{family}.sh"
                organizer.parent.mkdir(exist_ok=True)
                organizer.write_text(
                    f"#!{sys.executable}\nimport json, os, sys\n"
                    "with open(os.environ['TRACE_FILE'],'a') as f:\n"
                    " f.write(json.dumps(['organizer', *sys.argv[1:]])+'\\n')\n"
                    "sys.exit(9)\n"
                )
                organizer.chmod(0o755)
                queue = self.home / f".hazel-organize-{family}-queue"
                queue.write_text(f"{source}\n")
                result = self.run_script(worker)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(queue.read_text(), "")
                calls = [json.loads(s) for s in (self.root / "trace.jsonl").read_text().splitlines()]
                self.assertEqual(calls[-1], ["organizer", *expected, str(source)])
                self.assertTrue(source.exists())

    def test_guitar_output_and_two_request_contract(self):
        for path in ("organization/organize-guitar-tabs.sh",
                     "organization/organize-guitar-tabs-format.py",
                     "ai/open-ai-functions.sh", "utilities/logging.sh"):
            self.install(path)
        raw = self.root / "raw.txt"
        raw.write_text("raw chart")
        chart = "Song\nArtist\nKey: G\nCapo: 0\nTempo:\nTime:\nFlow: V1\nTuning: Standard\nTransposedKey:\n\nVerse 1:\nG\nWords\n"
        self.env["CHART"] = chart
        self.fake("curl", """
args = sys.argv[1:]
payload = json.loads(pathlib.Path(args[args.index('-d')+1][1:]).read_text())
with open(pathlib.Path(os.environ['HOME'])/'payloads.jsonl','a') as f:
 f.write(json.dumps(payload)+'\\n')
if 'Validate' in payload['messages'][1]['content']:
 content = {'formatted_tab': os.environ['CHART'], 'issues': [], 'fixed': False}
else:
 content = {'artist': 'Artist', 'song_title': 'Song', 'formatted_tab': os.environ['CHART']}
print(json.dumps({'choices':[{'message':{'content':json.dumps(content)}}]}))
""")
        result = self.run_script(self.repo / "organization/organize-guitar-tabs.sh", "--debug", raw)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "Artist - Song-debug.txt").read_text(), chart)
        self.assertTrue(raw.exists())
        payloads = [json.loads(s) for s in (self.home / "payloads.jsonl").read_text().splitlines()]
        self.assertEqual(len(payloads), 2)
        # MODEL_NAME is captured before the helper defaults OPENAI_MODEL.
        self.assertTrue(all(p["model"] == "gpt-5.1" for p in payloads))
        self.assertTrue(all("temperature" not in p for p in payloads))
        self.assertTrue(all(p["reasoning_effort"] == "low" for p in payloads))

    def pdf_setup(self):
        for path in ("organization/organize-pdf-with-openai.sh",
                     "ai/open-ai-functions.sh", "ai/ai-provider.sh", "utilities/logging.sh"):
            self.install(path)
        response = {
            "analysis": {"documentType": "Statement", "primarySender": "FCA US LLC",
                         "existingFolderMatch": None, "confidence": 0.95},
            "categorization": {
                "sender": "FCA US LLC", "department": None, "additionalContext": None,
                "sentOn": "2024-02-29", "category": "Cars", "shortSummary": 'A "monthly" statement.',
                "organizerDescription": "Monthly Statement",
            },
            "folderSuggestions": {
                "suggestedCategory": None, "suggestedSender": None,
                "suggestedDepartment": None, "suggestedAdditionalContext": None,
                "reasoning": "Document evidence.",
            },
        }
        self.env["OFFLINE_RESPONSE"] = json.dumps(response)
        self.fake("pdftotext", "print('Invoice\\naccount\\t123')")
        self.fake("osascript", "pass")
        self.fake("curl", """
args = sys.argv[1:]
payload = json.loads(pathlib.Path(args[args.index('-d')+1][1:]).read_text())
with open(pathlib.Path(os.environ['HOME'])/'payloads.jsonl','a') as f:
 f.write(json.dumps(payload)+'\\n')
print(json.dumps({'choices':[{'message':{'content':os.environ['OFFLINE_RESPONSE']}}]}))
""")
        return response

    def test_pdf_plan_and_backfill_contract(self):
        self.pdf_setup()
        source = self.root / "scan-20240301.pdf"
        source.write_bytes(b"offline PDF")
        state = self.root / "state.json"
        archive = self.root / "archive"
        result = self.run_script(
            self.repo / "organization/organize-pdf-with-openai.sh",
            "--dry-run", "--state-file", state, source,
            env={"PAPERWORK_DIR": str(archive)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(state.read_text())
        self.assertEqual(plan["metadata"]["schemaVersion"], "pdf-agentic-v1")
        self.assertEqual(plan["context"]["scannedTimestamp"], "2024-03-01T00-00-00")
        self.assertEqual(plan["plan"]["final"]["sender"], "Jeep")
        self.assertEqual(plan["plan"]["final"]["summary"], "A 'monthly' statement.")
        self.assertEqual(plan["action"]["proposedPath"],
                         str(archive / "Cars/Jeep/2024-02-29 - Jeep - Monthly Statement.pdf"))
        self.assertFalse(plan["action"]["completed"])
        self.assertTrue(source.exists())
        # Legacy dry-run unexpectedly creates taxonomy folders; migration fixes it.
        self.assertTrue((archive / "Cars/Jeep").is_dir())
        payload = json.loads((self.home / "payloads.jsonl").read_text())
        self.assertEqual(payload["model"], "gpt-5.4")
        self.assertEqual(payload["response_format"]["json_schema"]["name"],
                         "ComprehensiveFileSystemCategorization")

    def video_setup(self):
        for path in ("organization/organize-video-imports.sh",
                     "ai/open-ai-functions.sh", "utilities/logging.sh"):
            self.install(path)
        self.fake("ffprobe", "print('60' if 'format=duration' in sys.argv else '')")
        self.fake("ffmpeg", """
pattern = sys.argv[-1]
for index in (1, 2, 3):
 pathlib.Path(pattern.replace('%05d', f'{index:05d}')).write_bytes(b'offline frame')
""")
        self.fake("curl", """
args = sys.argv[1:]
payload = json.loads(pathlib.Path(args[args.index('-d')+1][1:]).read_text())
with open(pathlib.Path(os.environ['HOME'])/'payloads.jsonl','a') as f:
 f.write(json.dumps(payload)+'\\n')
if payload['model'] == 'gpt-4o':
 content = 'A family outdoors.'
else:
 content = json.dumps({'title':'Family day', 'description':'A family enjoys the day outdoors.',
                       'approximateDate':'2024-07-04','approximateDateSource':'filename date'})
print(json.dumps({'choices':[{'message':{'content':content}}]}))
""")
        self.fake("open", "pass")

    def test_video_argv_scenes_and_markdown(self):
        self.video_setup()
        source = self.root / "20240704 family.mov"
        source.write_bytes(b"offline video")
        result = self.run_script(self.repo / "organization/organize-video-imports.sh", source)
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = source.with_suffix(".md")
        self.assertEqual(summary.read_bytes(), (
            b"# Family day\n\nAI-generated video summary; check for accuracy.\n\n"
            b"A family enjoys the day outdoors.\n\nApproximate date: 2024-07-04\n\n"
            b"Approximate date source: filename date"
        ))
        work = source.parent / "_temp" / source.stem
        scenes = json_stream((work / "scenes.jsonl").read_text())
        self.assertEqual([s["timeSeconds"] for s in scenes], [0, 30, 60])
        # The legacy helper JSON-encodes plain-text model responses.
        self.assertEqual(scenes[0]["description"], '"A family outdoors."')
        payloads = [json.loads(s) for s in (self.home / "payloads.jsonl").read_text().splitlines()]
        self.assertEqual([p["model"] for p in payloads], ["gpt-4o"] * 3 + ["gpt-4.1"])
        calls = [json.loads(s) for s in (self.root / "trace.jsonl").read_text().splitlines()]
        ffmpeg = next(c for c in calls if c[0] == "ffmpeg")
        self.assertEqual(ffmpeg[ffmpeg.index("-t") + 1], "3001")
        self.assertIn("fps=1/30,scale='min(720,iw)':'min(404,ih)':force_original_aspect_ratio=decrease",
                      ffmpeg)


if __name__ == "__main__":
    unittest.main()
