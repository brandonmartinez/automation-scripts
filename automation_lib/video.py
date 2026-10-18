from __future__ import annotations

import base64
from dataclasses import asdict, dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile

from .ai import Client, PROMPTS, object_response
from .runtime import (
    AutomationError, absolute, atomic_bytes, atomic_json, candidate_path, directory, lock, logger,
    file_version, no_symlinks, now, optional_tool, publish_copy, read_json,
    regular_file, require_unchanged, run, tool,
)


@dataclass(frozen=True)
class Settings:
    interval: int = 30
    max_frames: int = 100
    width: int = 720
    height: int = 404
    quality: int = 30
    format: str = "webp"

    @property
    def extension(self) -> str:
        return "jpg" if self.format in ("jpg", "jpeg") else "webp"

    @property
    def mime(self) -> str:
        return "image/jpeg" if self.extension == "jpg" else "image/webp"

    def validate(self) -> None:
        if self.interval <= 0 or self.max_frames < 0 or min(self.width, self.height) <= 0:
            raise AutomationError("Interval/dimensions must be positive; max-frames must be nonnegative (0 = unlimited)")
        if not 1 <= self.quality <= 100:
            raise AutomationError("FRAME_QUALITY must be between 1 and 100")


def timecode(seconds: int) -> str:
    return f"{seconds // 3600:02d}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}"


def frame_request(source: Path, image: Path, index: int, settings: Settings) -> dict:
    tc = timecode((index - 1) * settings.interval)
    encoded = base64.b64encode(image.read_bytes()).decode("ascii")
    return {
        "model": os.environ.get("OPENAI_VISION_MODEL") or "gpt-4o",
        "messages": [
            {"role": "system", "content": "You describe video frames concisely and objectively. Focus on subjects, actions, setting, and visible text. Avoid speculation."},
            {"role": "user", "content": [
                {"type": "text", "text": f"Video file name: {source.stem}\nFrame time: {tc}\nDescribe what is visible in 1-2 concise sentences."},
                {"type": "image_url", "image_url": {"url": f"data:{settings.mime};base64,{encoded}"}},
            ]},
        ],
        "temperature": 0.2, "max_completion_tokens": 200,
    }


def summary_request(source: Path, scenes: list[dict], transcript: str) -> dict:
    timeline = "\n".join(f"[{s['timecode']}] {s['description']}" for s in scenes)
    section = "\n\nAudio transcript excerpt (may be partial, clean as needed):\n" + transcript if transcript else ""
    return {
        "model": os.environ.get("OPENAI_SUMMARY_MODEL") or "gpt-4.1",
        "messages": [
            {"role": "system", "content": PROMPTS["video_summary_system"]},
            {"role": "user", "content": PROMPTS["video_summary_user"] % (source.stem, timeline, section)},
        ],
        "temperature": 0.25, "max_completion_tokens": 500,
    }


def markdown(summary: dict) -> str:
    fields = ("title", "description", "approximateDate", "approximateDateSource")
    if any(not isinstance(summary.get(key), str) or not summary[key].strip() for key in fields):
        raise AutomationError("Summary JSON missing title, description, approximateDate, or approximateDateSource")
    text = (
        f"# {summary['title']}\n\nAI-generated video summary; check for accuracy.\n\n"
        f"{summary['description']}\n\nApproximate date: {summary['approximateDate']}\n\n"
        f"Approximate date source: {summary['approximateDateSource']}\n"
    )
    text = re.sub(r"\r\n?", "\n", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"^# *", "# ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    # Legacy command substitution removed all terminal newline bytes.
    return re.sub(r"\n +", "\n", text).rstrip("\n")


def scenes_from_stream(path: Path) -> list[dict]:
    if not path.exists():
        return []
    no_symlinks(path)
    text = path.read_text(encoding="utf-8")
    decoder = json.JSONDecoder()
    results = []
    seen = set()
    try:
        while text.strip():
            scene, end = decoder.raw_decode(text.lstrip())
            text = text.lstrip()[end:]
            if (not isinstance(scene, dict) or type(scene.get("frame")) is not int
                    or scene["frame"] <= 0 or scene["frame"] in seen
                    or not isinstance(scene.get("description"), str) or not scene["description"].strip()
                    or not isinstance(scene.get("timecode"), str)
                    or type(scene.get("timeSeconds")) is not int):
                raise ValueError("Invalid/duplicate scene")
            seen.add(scene["frame"])
            results.append(scene)
    except (ValueError, TypeError) as exc:
        raise AutomationError(f"Malformed scene cache retained for inspection: {path}") from exc
    return sorted(results, key=lambda s: s["frame"])


def save_scenes(path: Path, scenes: list[dict]) -> None:
    atomic_bytes(path, "".join(json.dumps(s, ensure_ascii=False) + "\n" for s in scenes).encode())


def extract_frames(source: Path, work: Path, frames: Path, settings: Settings) -> None:
    with tempfile.TemporaryDirectory(prefix=".frames-", dir=work) as temporary:
        output = Path(temporary)
        args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(source)]
        if settings.max_frames:
            args += ["-t", str(settings.interval * settings.max_frames + 1)]
        filter = (f"fps=1/{settings.interval},scale='min({settings.width},iw)':"
                  f"'min({settings.height},ih)':force_original_aspect_ratio=decrease")
        args += ["-vf", filter, "-fps_mode", "vfr", "-q:v", str(settings.quality)]
        if settings.extension == "webp":
            args += ["-f", "image2", "-vcodec", "libwebp"]
        if settings.max_frames:
            args += ["-vframes", str(settings.max_frames)]
        args += [str(output / f"frame_%05d.{settings.extension}")]
        run(args)
        images = sorted(output.glob(f"frame_*.{settings.extension}"))
        if not images:
            raise AutomationError("No frames were extracted")
        for image in images:
            regular_file(image)
            target = frames / image.name
            if not target.exists():
                publish_copy(image, target, collision=False)


def organize(input_file: str, *, interval: int = 30, max_frames: int = 100,
             summaries_dir: str | None = None) -> int:
    source = regular_file(input_file)
    version = file_version(source)
    log = logger("organize-video-imports")
    fmt = (os.environ.get("FRAME_FORMAT") or "webp").lower()
    if fmt not in ("jpg", "jpeg", "webp"):
        log.warning("Unsupported FRAME_FORMAT '%s'; defaulting to jpg", fmt)
        fmt = "jpg"
    settings = Settings(
        interval, max_frames, int(os.environ.get("FRAME_MAX_WIDTH", "720")),
        int(os.environ.get("FRAME_MAX_HEIGHT", "404")), int(os.environ.get("FRAME_QUALITY", "30")), fmt,
    )
    settings.validate()
    summaries = absolute(summaries_dir) if summaries_dir else source.parent
    summary_path = candidate_path(summaries / f"{source.stem}.md", 0)
    no_symlinks(summary_path)
    temp = directory(source.parent / "_temp")
    work = temp / source.stem
    no_symlinks(work)
    lock_key = hashlib.sha256(source.stem.encode()).hexdigest()[:24]
    with lock(temp / f".video-{lock_key}.python.lock"):
        info = source.stat()
        identity = dict(path=str(source), device=info.st_dev, inode=info.st_ino,
                        size=info.st_size, mtimeNs=info.st_mtime_ns)
        manifest = work / "workflow.json"
        context = dict(source=identity, settings=asdict(settings))
        if manifest.exists():
            old = read_json(manifest)
            if old.get("source") != identity or old.get("settings") != asdict(settings):
                raise AutomationError(f"Video/cache identity or options changed. Inspect and archive {work} before reprocessing; cache retained")
        if summary_path.exists() and summary_path.stat().st_size:
            log.info("Summary already exists at %s; skipping rewrite", summary_path)
            return 0
        if summary_path.exists():
            raise AutomationError(f"Existing summary is empty; inspect/archive it before processing: {summary_path}")
        if work.exists() and any(work.iterdir()) and not manifest.exists():
            raise AutomationError(
                f"Unverified legacy video cache: {work}. Inspect/archive that specific "
                "directory before the first Python run; no cached data has been removed."
            )
        for name in ("ffmpeg", "ffprobe", "curl"):
            tool(name)
        directory(work)
        frames = directory(work / "frames")
        audio_dir = directory(work / "audio")
        context.update(status="running", updatedAt=now())
        atomic_json(manifest, context)
        try:
            audio_stream = run(
                ["ffprobe", "-v", "error", "-select_streams", "a:0",
                 "-show_entries", "stream=index", "-of", "csv=p=0", source],
            ).stdout.strip()
            duration_raw = run(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                 "-of", "default=noprint_wrappers=1:nokey=1", source],
            ).stdout.strip()
            try:
                duration = float(duration_raw)
                if not math.isfinite(duration) or duration < 0:
                    raise ValueError
            except ValueError as exc:
                raise AutomationError("ffprobe returned an invalid video duration") from exc
            expected = int(duration) // interval + 1
            if max_frames:
                expected = min(expected, max_frames)
            images = sorted(frames.glob(f"frame_*.{settings.extension}"))
            if len(images) < expected:
                extract_frames(source, work, frames, settings)
                images = sorted(frames.glob(f"frame_*.{settings.extension}"))
            if expected > 1 and len(images) < 2:
                log.warning("Unexpectedly low frame count (%s/%s); check source duration or ffmpeg output", len(images), expected)
            if not images:
                raise AutomationError("No frames found for processing")
            for image in images:
                regular_file(image)
            scenes_path = work / "scenes.jsonl"
            scenes = scenes_from_stream(scenes_path)
            if any(s["frame"] > len(images) or s["timeSeconds"] != (s["frame"] - 1) * interval
                   or s["timecode"] != timecode((s["frame"] - 1) * interval) for s in scenes):
                raise AutomationError(f"Scene cache does not match frames: {scenes_path}")
            client = Client(log)
            done = {s["frame"] for s in scenes}
            for index, image in enumerate(images, 1):
                if index in done:
                    continue
                for attempt in range(1, 3):
                    try:
                        description = client.chat(frame_request(source, image, index, settings))
                        break
                    except AutomationError:
                        log.warning("Frame %s description failed (attempt %s/2)", index, attempt)
                        if attempt == 2:
                            raise
                seconds = (index - 1) * interval
                scenes.append(dict(frame=index, timecode=timecode(seconds), description=description, timeSeconds=seconds))
                scenes.sort(key=lambda s: s["frame"])
                save_scenes(scenes_path, scenes)
                log.info("Described frame %s/%s", index, len(images))
            transcript = ""
            transcript_path = audio_dir / "audio_transcript.txt"
            no_symlinks(transcript_path)
            if audio_stream:
                if not transcript_path.exists():
                    audio = audio_dir / "audio.ogg"
                    no_symlinks(audio)
                    if not audio.exists() or not audio.stat().st_size:
                        with tempfile.TemporaryDirectory(prefix=".audio-", dir=audio_dir) as temporary:
                            extracted = Path(temporary) / "audio.ogg"
                            run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", source,
                                 "-vn", "-ac", "1", "-ar", "16000", "-c:a", "libopus",
                                 "-b:a", "24k", extracted])
                            regular_file(extracted)
                            if not extracted.stat().st_size:
                                raise AutomationError("Extracted audio file is empty")
                            publish_copy(extracted, audio, collision=False)
                    body = client.transcribe(audio, os.environ.get("OPENAI_AUDIO_MODEL") or "whisper-1")
                    atomic_bytes(transcript_path, (body + "\n").encode())
                transcript = transcript_path.read_bytes()[:4000].decode("utf-8", errors="ignore").replace("\r", "").rstrip("\n")
            for attempt in range(1, 4):
                try:
                    response = client.chat(summary_request(source, scenes, transcript))
                    summary = object_response(response)
                    content = markdown(summary)
                    break
                except AutomationError:
                    log.warning("Video summary failed (attempt %s/3)", attempt)
                    if attempt == 3:
                        raise
            directory(summaries)
            require_unchanged(source, version)
            atomic_bytes(summary_path, content.encode(), replace=False)
            from .queue import record_publication
            record_publication(summary_path)
            context.update(status="done", summaryPath=str(summary_path), updatedAt=now())
            atomic_json(manifest, context)
            if optional_tool("open"):
                result = run(["open", "-R", summary_path], check=False)
                if result.returncode:
                    log.warning("Summary written, but Finder reveal failed")
            log.info("Summary: %s", summary_path)
            return 0
        except BaseException as exc:
            context.update(status="failed", error=f"{type(exc).__name__}: {exc}", updatedAt=now())
            atomic_json(manifest, context)
            raise
