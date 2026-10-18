from __future__ import annotations

from datetime import date, datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile
import time

from .ai import Client, PROMPTS, compact, object_response
from .runtime import (
    AutomationError, absolute, atomic_json, available_path, directory, logger,
    file_version, no_symlinks, now, publish_copy, read_json, regular_file,
    require_unchanged, run,
)


ALIASES = dict.fromkeys(("fca us llc", "fca us", "stellantis", "chrysler"), "Jeep")


def clean_space(text: str) -> str:
    return re.sub(r" +", " ", re.sub(r"[\r\n\t]", " ", text)).strip(" ")


def sanitize_text(text: str, *, folder: bool = False) -> str:
    text = re.sub(r"[\x00-\x1f\x7f]", "", text)
    if folder:
        text = text.rsplit("/", 1)[-1].rsplit(" > ", 1)[-1]
    text = re.sub(r'[/\\:*?"<>|]', " ", text)
    return re.sub(r" +", " ", text).lstrip(" ._" if folder else " .").rstrip(" .")


def path_field(raw: str, category: str = "", *, department: bool = False) -> str:
    parts = [p.strip() for p in re.split(r"[/\\>]", raw) if p.strip()]
    if len(parts) > 1 and category and parts[0].lower() == category.lower():
        parts.pop(0)
    return (parts[-1] if department else parts[0]) if parts else ""


def sender_alias(value: str) -> str:
    return ALIASES.get(value.lower().strip().rstrip(".,"), value)


def concise(candidate: str, fallback: str, limit: int, *, ellipsis: bool = False) -> str:
    text = clean_space(candidate or fallback or "Document")
    if len(text) > limit:
        truncated = text[:limit]
        if text[limit] != " ":
            truncated = truncated.rsplit(" ", 1)[0] if " " in truncated else truncated
        text = truncated + ("..." if ellipsis else "")
    return text


def title_case(text: str) -> str:
    def word(value):
        stripped = re.sub(r"[^A-Za-z0-9]", "", value)
        if len(stripped) > 1 and stripped == stripped.upper():
            return value.upper()
        return value[:1].upper() + value[1:].lower()
    return " ".join("-".join(word(p) for p in token.split("-")) for token in clean_space(text).split(" "))


def strip_redundancy(descriptor: str, *values: str) -> str:
    tokens = []
    for value in values:
        if not value or value == "null":
            continue
        variants = [
            value, re.sub(r"[\W_]", "", value), re.sub(r"[^0-9]", "", value),
            re.sub(r"[\W_]+", "-", value).strip("-"),
            *re.split(r"[/ :_\-Tt]", value),
        ]
        for token in variants:
            token = clean_space(token)
            if len(token) >= 3 and token.lower() not in [t.lower() for t in tokens]:
                tokens.append(token)
    cleaned = descriptor
    for token in tokens:
        cleaned = re.sub(re.escape(token), " ", cleaned, flags=re.I)
    return clean_space(cleaned) or descriptor


def filename_dates(filename: str) -> list[dict]:
    result = []
    seen = set()
    patterns = [
        (r"\d{4}[-_/]\d{2}[-_/]\d{2}", "day", "separator-day"),
        (r"(?<!\d)\d{8}(?!\d)", "day", "compact-day"),
        (r"\d{4}[-_/]\d{2}(?![-_/\d])", "month", "separator-month"),
        (r"(?<!\d)\d{6}(?!\d)", "month", "compact-month"),
    ]
    matches = []
    for priority, (pattern, precision, kind) in enumerate(patterns):
        for match in re.finditer(pattern, filename):
            matches.append((match.start(), priority, match.group(), precision, kind))
    for _, _, raw, precision, kind in sorted(matches):
        normalized = re.sub(r"[_/]", "-", raw)
        if kind.startswith("compact"):
            normalized = f"{raw[:4]}-{raw[4:6]}" + (f"-{raw[6:8]}" if precision == "day" else "")
        key = (normalized, precision)
        if key not in seen:
            seen.add(key)
            result.append(dict(raw=raw, normalized=normalized, precision=precision, pattern=kind))
    return result


def scanned_timestamp(filename: str) -> str | None:
    new = re.search(r"scan-(\d{4})(\d{2})(\d{2})", filename)
    if new:
        return f"{new[1]}-{new[2]}-{new[3]}T00-00-00"
    old = re.search(r"\d{4}-\d{2}-\d{2}[-T]\d{2}-\d{2}-\d{2}", filename)
    if old:
        return old[0][:10] + "T" + old[0][11:]
    for pattern, order in ((r"(\d{4})-(\d{2})-(\d{2})", (1, 2, 3)),
                           (r"(\d{2})-(\d{2})-(\d{4})", (3, 1, 2))):
        match = re.search(pattern, filename)
        if match:
            try:
                value = date(*(int(match[i]) for i in order))
                return value.isoformat() + "T00-00-00"
            except ValueError:
                pass
    for raw in re.findall(r"(?<!\d)\d{8}(?!\d)", filename):
        for year, month, day in ((raw[:4], raw[4:6], raw[6:]), (raw[4:], raw[:2], raw[2:4])):
            try:
                value = date(int(year), int(month), int(day))
            except ValueError:
                continue
            if 1900 <= value.year <= 2100:
                return value.isoformat() + "T00-00-00"
    return None


def categorization(response: dict, archive: Path) -> dict:
    categorization = response.get("categorization")
    analysis = response.get("analysis")
    suggestions = response.get("folderSuggestions")
    if not all(isinstance(x, dict) for x in (categorization, analysis, suggestions)):
        raise AutomationError("Paperwork response missing categorization, analysis or folderSuggestions")

    def field(obj, key):
        value = obj.get(key)
        if value is None or value == "null":
            return ""
        if not isinstance(value, str):
            raise AutomationError(f"Paperwork field {key} must be a string or null")
        return value

    category = path_field(field(categorization, "category"))
    sender = sender_alias(path_field(sender_alias(field(categorization, "sender")), category))
    department = path_field(field(categorization, "department"), category, department=True)
    additional = field(categorization, "additionalContext")
    sent = re.sub(r"[/: ]", "-", field(categorization, "sentOn"))
    summary = clean_space(field(categorization, "shortSummary").replace('"', "'"))
    description = concise(field(categorization, "organizerDescription"), summary, 100, ellipsis=True)
    summary = summary or description or "Document summary pending manual input."
    file_description = concise(title_case(description), title_case(summary), 120)
    existing = field(analysis, "existingFolderMatch")
    if existing and existing != category:
        relative = existing.removeprefix(str(archive)).lstrip("/").removeprefix("./").rstrip("/")
        if "/" in relative:
            parts = relative.split("/", 2)
            category, sender = parts[0].strip(), parts[1].strip()
            department = parts[2].strip() if len(parts) == 3 else ""
        else:
            sender = existing
    elif field(suggestions, "suggestedSender"):
        sender = field(suggestions, "suggestedSender")
    category = field(suggestions, "suggestedCategory") or category
    department = field(suggestions, "suggestedDepartment") or department
    additional = field(suggestions, "suggestedAdditionalContext") or additional
    category = path_field(category)
    sender = sender_alias(path_field(sender, category))
    department = path_field(department, category, department=True)
    if not (sender and category and summary and description):
        raise AutomationError("One or more required paperwork fields are empty")
    return dict(sender=sender, department=department or None, category=category,
                sentOn=sent or None, additionalContext=additional or None,
                organizerDescription=description, fileNameDescription=file_description, summary=summary)


def low_confidence(value, threshold: float) -> bool:
    return (not isinstance(value, (float, int)) or isinstance(value, bool)
            or not math.isfinite(value) or not 0 <= value <= 1 or value < threshold)


def folder_snapshot(archive: Path) -> dict:
    if not archive.exists():
        return {"categories": []}
    no_symlinks(archive)

    def folders(parent):
        return [p for p in sorted(parent.iterdir()) if not p.name.startswith(("_", "."))
                and not p.is_symlink() and p.is_dir()]

    def count(parent):
        total = 0
        for base, dirs, files in os.walk(parent, followlinks=False):
            dirs[:] = [d for d in dirs if not (Path(base) / d).is_symlink()]
            total += sum(1 for f in files if (Path(base) / f).is_file() and not (Path(base) / f).is_symlink())
        return total

    def entry(path):
        return {"name": path.name, "path": str(path), "itemCount": count(path)}

    categories = []
    for category in folders(archive):
        senders = []
        for sender in folders(category):
            senders.append(entry(sender) | {"departments": [entry(p) for p in folders(sender)]})
        categories.append(entry(category) | {"senders": senders})
    return {"categories": categories}


def snapshot(archive: Path, *, dry_run: bool, log) -> dict:
    cache = absolute(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "organize-pdf-with-openai"
    key = hashlib.sha256(str(archive).encode()).hexdigest()[:24]
    path = cache / f"folder-structure-python-{key}.json"
    try:
        ttl = int(os.environ.get("PAPERWORK_STRUCTURE_CACHE_TTL", "900"))
    except ValueError:
        ttl = 900
    no_symlinks(path)
    if not dry_run and path.exists() and ttl > 0 and time.time() - path.stat().st_mtime < ttl:
        value = read_json(path)
        if not isinstance(value, dict) or not isinstance(value.get("categories"), list):
            raise AutomationError(f"Malformed folder cache: {path}")
        return value
    value = folder_snapshot(archive)
    if not dry_run:
        atomic_json(path, value)
    return value


def extract_text(source: Path, log, temporary: Path) -> tuple[str, Path]:
    def text(path):
        raw = run(["pdftotext", "-nopgbrk", "-raw", path, "-"]).stdout.rstrip("\n")
        raw = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", re.sub(r"[\r\n\t]", " ", raw))
        return re.sub(" +", " ", raw)
    result = text(source)
    processed = source
    if not result.strip():
        log.warning("Initial text extraction empty; attempting OCR on a private copy")
        processed = publish_copy(source, temporary / source.name)
        run(["ocrmypdf", "-l", "eng", "--output-type", "pdf", "--redo-ocr", "--rotate-pages", processed, processed])
        result = text(processed)
    if not result.strip():
        raise AutomationError("Failed to extract text from PDF even after OCR")
    return result[:100000] + ("... [TRUNCATED]" if len(result) > 100000 else ""), processed


def filename(final: dict, primary: str) -> str:
    sender = sanitize_text(final["sender"])
    department = sanitize_text(final["department"] or "")
    descriptor = sanitize_text(final["fileNameDescription"])
    parts = [p for p in (sender, department, descriptor) if p]
    result = f"{primary} - {' - '.join(parts) or 'Document'}.pdf"
    if len(result.encode()) > 255:
        parts = [p for p in (sender, department) if p]
        result = f"{primary} - {' - '.join(parts)}.pdf"
    if len(result.encode()) > 255:
        result = f"{primary} - {sender}.pdf"
    # available_path further bounds bytes with collision suffixes, not characters.
    return result


def organize(input_file: str, *, move: bool = False, dry_run: bool = False,
             state_file: str | None = None) -> int:
    source = regular_file(input_file)
    version = file_version(source)
    archive = absolute(os.environ.get("PAPERWORK_DIR") or Path.home() / "Documents/Paperwork")
    no_symlinks(archive)
    log = logger("organize-pdf-with-openai")
    threshold = float(os.environ.get("OPENAI_CONFIDENCE_THRESHOLD", "0.7"))
    if not math.isfinite(threshold) or not 0 <= threshold <= 1:
        raise AutomationError("OPENAI_CONFIDENCE_THRESHOLD must be a number between 0 and 1")
    if state_file:
        state_path = absolute(state_file)
        no_symlinks(state_path)
        if state_path == source:
            raise AutomationError("--state-file must not replace the input PDF")
    else:
        fd, name = tempfile.mkstemp(prefix="pdf-agentic.", suffix=".json")
        os.close(fd)
        state_path = Path(name)
    mode = "move" if move else "copy"
    phases = [dict(name=p, startedAt=None, completedAt=None, notes=[]) for p in ("discovery", "analysis", "action")]
    state = {
        "metadata": dict(schemaVersion="pdf-agentic-v1", generatedAt=now(), dryRun=dry_run,
                         moveMode=mode, phases=phases),
        "file": dict(originalPath=str(source), filename=source.name,
                     extension=source.suffix.lstrip(".").lower() or None,
                     sizeBytes=source.stat().st_size, createdAt=None),
        "context": dict(scannedTimestamp=None, createdTimestamp=None, filenameDates=[],
                        folderStructure={"categories": []}, textSample="", textCharacters=0,
                        sentOn=None, additionalContext=None, organizerDescription=None, fileNameDescription=None),
        "plan": dict(analysis=None, categorization=None, destination=None, final=None,
                     rawResponse=None, confidence=None, rationale=[]),
        "action": dict(intendedOperation=mode, dryRun=dry_run, proposedPath=None,
                       appliedPath=None, finderComment=None, completed=False),
    }

    def save():
        atomic_json(state_path, state)

    def rationale(key, detail):
        state["plan"]["rationale"].append(dict(key=key, detail=detail, timestamp=now()))

    workspace = tempfile.TemporaryDirectory(prefix="hazel-pdf-")
    try:
        save()
        phases[0]["startedAt"] = now()
        info = source.stat()
        created = datetime.fromtimestamp(getattr(info, "st_birthtime", info.st_mtime)).date().isoformat()
        scan = scanned_timestamp(source.name)
        state["file"]["createdAt"] = created
        text, processed = extract_text(source, log, Path(workspace.name))
        structure = snapshot(archive, dry_run=dry_run, log=log)
        sample = text[:8000] + (" ... [STATE_TRUNCATED]" if len(text) > 8000 else "")
        state["context"].update(
            createdTimestamp=created, scannedTimestamp=scan, filenameDates=filename_dates(source.name),
            folderStructure=structure, textSample=sample, textCharacters=len(text),
        )
        phases[0]["completedAt"] = now()
        phases[1]["startedAt"] = now()
        # The original user prompt contains literal backslash-n separators.
        discovery = {key: state[key] for key in ("metadata", "file", "context")}
        payload = {
            "messages": [{"role": "system", "content": PROMPTS["pdf_system"]},
                         {"role": "user", "content": "Current workflow state JSON:\\n" + compact(discovery)
                          + "\\n\\nUpdate the plan according to the schema."}],
            "response_format": PROMPTS["pdf_response_format"],
        }
        response = object_response(Client(log).chat(payload, provider=True))
        print(json.dumps(response, ensure_ascii=False, indent=2))
        final = categorization(response, archive)
        confidence = response["analysis"].get("confidence")
        state["plan"].update(
            rawResponse=response, analysis=response["analysis"],
            categorization=response["categorization"] | {
                "organizerDescription": final["organizerDescription"],
                "fileNameDescription": final["fileNameDescription"],
            },
            destination={
                "category": response["folderSuggestions"].get("suggestedCategory"),
                "sender": response["folderSuggestions"].get("suggestedSender"),
                "department": response["folderSuggestions"].get("suggestedDepartment"),
                "additionalContext": response["folderSuggestions"].get("suggestedAdditionalContext"),
                "rationale": response["folderSuggestions"].get("reasoning"),
            },
            confidence=confidence, final=final,
        )
        state["context"].update({key: response["categorization"].get(key) for key in
                                 ("sentOn", "additionalContext", "organizerDescription")})
        state["context"]["organizerDescription"] = final["organizerDescription"]
        state["context"]["fileNameDescription"] = final["fileNameDescription"]
        rationale("summary", f"Short summary sourced from AI analysis of {response['analysis'].get('documentType', 'document')}: {final['summary']}")
        rationale("organizer-description", f"Concise organizer description constrained to 100 chars for filenames: {final['organizerDescription']}")
        rationale("file-name-description", f"File-friendly description used for naming: {final['fileNameDescription']}")
        phases[1]["completedAt"] = now()
        phases[2]["startedAt"] = now()
        primary = final["sentOn"] or created or (scan.split("T")[0] if scan else date.today().isoformat())
        primary = sanitize_text(primary)
        if not primary or primary in (".", ".."):
            raise AutomationError("Unsafe document date returned by AI")
        final["fileNameDescription"] = strip_redundancy(
            final["fileNameDescription"], final["sender"], primary, scan or "", final["sentOn"] or "",
        )
        category = sanitize_text(final["category"], folder=True) or "Uncategorized"
        comment = final["summary"]
        if low_confidence(confidence, threshold):
            review = os.environ.get("NEEDS_REVIEW_DIRNAME") or "_Needs Review"
            if review in (".", "..") or "/" in review or "\\" in review or not review.strip():
                raise AutomationError("NEEDS_REVIEW_DIRNAME must be a single folder name")
            destination = archive / review / category
            value = confidence if confidence is not None else "unknown"
            department = f" / {final['department']}" if final["department"] else ""
            comment = (f"[Needs Review — confidence {value}; best guess: "
                       f"{final['category']} / {final['sender']}{department}] {comment}")
            rationale("review-lane", f"Confidence {value} < {threshold}; needs manual review")
            log.warning("Routing to review lane: confidence %s (threshold %s)", value, threshold)
        else:
            destination = archive / category / (sanitize_text(final["sender"], folder=True) or "Unknown Sender")
            if final["department"]:
                department = sanitize_text(final["department"], folder=True)
                if department:
                    destination /= department
        no_symlinks(destination)
        original = absolute(os.environ["ORIGINAL_FILE_PATH"]) if os.environ.get("ORIGINAL_FILE_PATH") else source
        proposed = available_path(destination / filename(final, primary), original=original)
        if proposed == state_path:
            raise AutomationError("Destination and --state-file must be different")
        state["action"].update(proposedPath=str(proposed), finderComment=comment)
        save()
        if not dry_run:
            require_unchanged(source, version)
            published = publish_copy(processed, proposed, link_source=move)
            state["action"].update(proposedPath=str(published), appliedPath=str(published))
            save()
            from .queue import record_publication
            record_publication(published)
            run(["osascript", "-e", "on run {f, c}", "-e",
                 'tell app "Finder" to set comment of (POSIX file f as alias) to c',
                 "-e", "end", f"file://{published}", comment])
            if os.environ.get("REVEAL_IN_FINDER", "true") == "true":
                result = run(["open", "-R", published], check=False)
                if result.returncode:
                    log.warning("Failed to reveal PDF; opening destination directory instead")
                    run(["open", destination])
            state["action"]["completed"] = True
            save()
            if move and source != published:
                source.unlink()
        phases[2]["completedAt"] = now()
        save()
        log.info("Agentic plan saved to %s", state_path)
        if dry_run and not state_file:
            print(state_path.read_text(), end="")
        return 0
    except BaseException as exc:
        state["metadata"]["error"] = f"{type(exc).__name__}: {exc}"
        state["action"]["completed"] = False
        save()
        log.error("Paperwork processing incomplete; plan retained at %s", state_path)
        raise
    finally:
        workspace.cleanup()
