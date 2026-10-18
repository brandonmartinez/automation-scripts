from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import re

from .ai import Client, PROMPTS, object_response
from .runtime import (
    ROOT, AutomationError, atomic_bytes, file_version, logger, publish_text,
    regular_file, require_unchanged,
)


def rebuild(tab: str, artist: str, title: str, filename: str) -> str:
    spec = importlib.util.spec_from_file_location(
        "guitar_tab_format", ROOT / "organization/organize-guitar-tabs-format.py"
    )
    if spec is None or spec.loader is None:
        raise AutomationError("Existing guitar-tab formatter could not be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.rebuild_formatted_tab(tab, artist, title, filename)


def request(text: str, *, validator: bool = False) -> dict:
    if validator:
        system = PROMPTS["guitar_validator"]
        user = "Validate and minimally fix the following formatted chart. Respond only with JSON as specified.\n\nChart:\n"
    else:
        system = PROMPTS["guitar_system"]
        user = "Format the following raw text into the target OnSong structure and respond only with the JSON object described above.\n\nRaw input:\n"
    return {
        "model": os.environ.get("OPENAI_MODEL") or "gpt-5.1", "temperature": 0.2,
        "response_format": {"type": "json_object"},
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user + text}],
    }


def parse_chart(response: str) -> tuple[str, str, str]:
    raw = response.replace("\r", "")
    try:
        value = json.loads(raw, strict=False)
        if isinstance(value, str):
            value = json.loads(value, strict=False)
    except ValueError as exc:
        raise AutomationError("Failed to parse OpenAI chart JSON; input retained") from exc
    if not isinstance(value, dict):
        raise AutomationError("OpenAI chart response must be an object")
    artist = value.get("artist") or value.get("Artist") or "Unknown Artist"
    title = value.get("song_title") or value.get("title") or "Unknown Song"
    tab = value.get("formatted_tab") or value.get("formatted") or value.get("content")
    if not all(isinstance(x, str) for x in (artist, title, tab)) or not tab:
        raise AutomationError("Failed to parse OpenAI response (tab missing or invalid fields)")
    if any("\n" in item or "\x00" in item for item in (artist, title)):
        raise AutomationError("Artist/title must be single-line strings")
    return artist, title, tab.replace("\\n", "\n").replace("\\t", "\t")


def sanitize_component(text: str) -> str:
    result = re.sub(r'[/:*?"<>|]', "-", text.replace("\r", ""))
    result = re.sub(r" +", " ", result).strip()
    if result in ("", ".", "..") or "\\" in result or any(ord(c) < 32 for c in result):
        raise AutomationError("AI returned an unsafe/empty artist or title")
    return result


def organize(input_file: str, *, debug: bool = False) -> int:
    source = regular_file(input_file)
    version = file_version(source)
    raw = source.read_text(encoding="utf-8").rstrip("\n")
    if not raw:
        raise AutomationError(f"Input file is empty: {source}")
    log = logger("organize-guitar-tabs")
    client = Client(log)
    response = client.chat(request(raw))
    atomic_bytes(
        Path.home() / "Library/Logs/automation-scripts/organization/organize-guitar-tabs-last-response.txt",
        (response + "\n").encode(),
    )
    artist, title, tab = parse_chart(response)
    tab = rebuild(tab, artist, title, source.name).rstrip("\n")
    validation = object_response(client.chat(request(tab, validator=True)))
    candidate = validation.get("formatted_tab") or validation.get("chart") or validation.get("tab")
    if candidate:
        if not isinstance(candidate, str):
            raise AutomationError("Validator returned a non-text chart")
        tab = candidate
    else:
        log.warning("Validator returned empty tab; keeping original")
    issues = validation.get("issues", [])
    if not isinstance(issues, list) or any(not isinstance(x, str) for x in issues):
        raise AutomationError("Validator issues must be an array of strings")
    for issue in issues:
        log.info("Validation issue: %s", issue)
    output = source.parent if debug else Path(
        os.environ.get("GUITAR_TAB_OUTPUT") or Path.home() / "Documents/Guitar Tabs"
    ).absolute()
    filename = f"{sanitize_component(artist)} - {sanitize_component(title)}"
    target = output / (filename + ("-debug.txt" if debug else ".txt"))
    require_unchanged(source, version)
    published = publish_text(target, tab.rstrip("\n") + "\n")
    from .queue import record_publication
    record_publication(published)
    if not debug and published != source:
        source.unlink()
    log.info("Wrote formatted tab to %s%s", published, " (original preserved)" if debug else "")
    return 0
