#!/usr/bin/env python3

import os
import re
import sys
from typing import Dict, List, Optional, Tuple


CHORD_RE = re.compile(
    r"\b(?P<root>[A-G](?:#|b)?)(?P<qual>maj7|maj|min7|m7|m|min|dim|aug|sus2|sus4|add9|6|7|9|11|13|m6|m9|maj9)?(?:/[A-G](?:#|b)?)?\b"
)


def detect_key(body: str) -> str:
    root_counts: Dict[str, int] = {}
    minor_counts: Dict[str, int] = {}

    for match in CHORD_RE.finditer(body):
        root = match.group("root")
        qual = match.group("qual") or ""
        is_minor = qual.startswith("m") and not qual.startswith("maj")

        root_counts[root] = root_counts.get(root, 0) + 1
        if is_minor:
            minor_counts[root] = minor_counts.get(root, 0) + 1

    if not root_counts:
        return ""

    best_root = max(root_counts.items(), key=lambda item: item[1])[0]
    minor_hits = minor_counts.get(best_root, 0)
    total_hits = root_counts[best_root]

    if total_hits > 0 and minor_hits / total_hits >= 0.5:
        return f"{best_root}m"
    return best_root


def parse_section_header(raw: str) -> Tuple[str, str, Optional[int]]:
    name = raw.strip()
    m = re.match(r"^(.*?)(?:\s+(\d+))?$", name)
    base_part = m.group(1).strip() if m else name
    num = int(m.group(2)) if m and m.group(2) else None
    base = base_part.lower().replace("-", " ").strip()
    if "pre" in base and "chorus" in base:
        return "Pre-Chorus", "PC", num
    if base.startswith("verse"):
        return "Verse", "V", num
    if base.startswith("chorus"):
        return "Chorus", "C", num
    if base.startswith("intro"):
        return "Intro", "Intro", num
    if base.startswith("outro"):
        return "Outro", "Outro", num
    if base.startswith("bridge") or base == "b":
        return "Bridge", "B", num
    if base.startswith("instrument") or base.startswith("instr"):
        return "Instrumental", "Instr", num
    if base.startswith("solo"):
        return "Solo", "Solo", num
    if base.startswith("tag"):
        return "Tag", "Tag", num
    if base.startswith("interlude"):
        return "Interlude", "Interlude", num
    if base.startswith("pre"):
        return "Pre-Chorus", "PC", num
    clean = base_part.title()
    return clean, clean.replace(" ", ""), num


def normalize_content(content_lines: List[str]) -> str:
    return "\n".join(content_lines).strip()


def clean_lines(content_lines: List[str]) -> List[str]:
    return [line.rstrip() for line in content_lines]


def starts_with_lines(candidate: List[str], prefix: List[str]) -> bool:
    if len(candidate) < len(prefix):
        return False
    return all(candidate[i] == prefix[i] for i in range(len(prefix)))


def extract_repeated_block(lines: List[str]) -> Tuple[List[str], int]:
    n = len(lines)
    if n == 0:
        return lines, 1
    for size in range(1, (n // 2) + 1):
        if n % size:
            continue
        block = lines[:size]
        count = n // size
        if all(lines[i * size : (i + 1) * size] == block for i in range(count)):
            return block, count
    return lines, 1


def rebuild_formatted_tab(tab: str, artist_fb: str, title_fb: str, file_base: str) -> str:
    lines = tab.split("\n")

    file_artist = ""
    file_title = ""
    if file_base:
        base_no_ext = file_base.rsplit(".", 1)[0]
        parts = base_no_ext.split(" - ", 1)
        if len(parts) == 2:
            file_artist, file_title = parts[0].strip(), parts[1].strip()
        else:
            file_title = base_no_ext.strip()

    hdr_title = lines[0].strip() if len(lines) > 0 else ""
    hdr_artist = lines[1].strip() if len(lines) > 1 else ""

    meta_names = ["Key", "Capo", "Tempo", "Time", "Flow", "Tuning", "TransposedKey"]
    meta: Dict[str, str] = {name: "" for name in meta_names}

    for offset, name in enumerate(meta_names, start=2):
        if offset < len(lines):
            m = re.match(rf"^{name}:\s*(.*)$", lines[offset])
            if m:
                meta[name] = m.group(1).strip()

    body_start = 2 + len(meta_names)
    if body_start < len(lines) and lines[body_start].strip() == "":
        body_start += 1
    body = "\n".join(lines[body_start:]).lstrip("\n")

    artist = hdr_artist or artist_fb or file_artist or "Unknown Artist"
    title = hdr_title or title_fb or file_title or "Unknown Song"

    if not meta["Capo"]:
        meta["Capo"] = "0"
    if not meta["Tuning"]:
        meta["Tuning"] = "Standard"

    if not meta["Key"]:
        meta["Key"] = detect_key(body)

    header_re = re.compile(r"^([A-Za-z][A-Za-z0-9 \-'\/]+):\s*$")

    lines_in_body = body.split("\n")
    sections: List[Dict] = []
    leading_lines: List[str] = []
    current_header: Optional[str] = None
    current_lines: List[str] = []
    headers_found = 0

    for line in lines_in_body:
        m = header_re.match(line.strip())
        if m:
            headers_found += 1
            if current_header is not None:
                sections.append({"header": current_header, "lines": current_lines})
            current_header = m.group(1).strip()
            current_lines = []
        else:
            if current_header is None:
                leading_lines.append(line)
            else:
                current_lines.append(line)

    if current_header is not None:
        sections.append({"header": current_header, "lines": current_lines})

    if headers_found > 0:
        type_stats: Dict[str, Dict[str, List]] = {}
        unique_order: List[Tuple[str, int]] = []
        occurrences: List[Dict] = []

        for entry in sections:
            type_name, prefix, _ = parse_section_header(entry["header"])
            content_clean_raw = clean_lines(entry["lines"])
            base_block, repeat_count = extract_repeated_block(content_clean_raw)
            content_clean = base_block
            content_key = "\n".join(content_clean).strip()
            stats = type_stats.setdefault(type_name, {"unique": [], "prefix": prefix, "count": 0})
            stats["count"] += repeat_count
            match_idx = None
            extension_created = False
            for idx, u in enumerate(stats["unique"], start=1):
                if u["key"] == content_key:
                    match_idx = idx
                    break
                if type_name == "Chorus" and starts_with_lines(content_clean, u["lines_clean"]):
                    extension_lines = content_clean[len(u["lines_clean"]):]
                    extension_key = "\n".join(extension_lines).strip()
                    if extension_key == "":
                        match_idx = idx
                        break
                    for jdx, uj in enumerate(stats["unique"], start=1):
                        if uj.get("extension_of") == idx and uj["key"] == extension_key:
                            match_idx = jdx
                            break
                    if match_idx is not None:
                        break
                    stats["unique"].append({
                        "key": extension_key,
                        "lines": extension_lines,
                        "lines_clean": extension_lines,
                        "extension_of": idx,
                    })
                    match_idx = len(stats["unique"])
                    extension_created = True
                    unique_id = (type_name, match_idx)
                    if unique_id not in unique_order:
                        unique_order.append(unique_id)
                    break
            if match_idx is None:
                stats["unique"].append({"key": content_key, "lines": content_clean, "lines_clean": content_clean})
                match_idx = len(stats["unique"])
                unique_id = (type_name, match_idx)
                if unique_id not in unique_order:
                    unique_order.append(unique_id)
            for _ in range(repeat_count):
                occurrences.append({
                    "type": type_name,
                    "prefix": prefix,
                    "unique_idx": match_idx,
                    "extension": extension_created,
                })

        numbering_types = {"Verse", "Pre-Chorus", "Chorus", "Bridge"}

        def needs_numbering(type_name: str) -> bool:
            stats = type_stats[type_name]
            return len(stats["unique"]) > 1 or (stats["count"] > 1 and type_name in numbering_types)

        display_map: Dict[Tuple[str, int], Dict[str, object]] = {}
        for type_name, stats in type_stats.items():
            prefix = stats["prefix"]
            number_required = needs_numbering(type_name)
            for idx, unique in enumerate(stats["unique"], start=1):
                number = idx if number_required else None
                if number is None and stats["count"] > 1 and type_name in numbering_types:
                    number = idx
                display_name = f"{type_name} {number}" if number else type_name
                token = f"{prefix}{number}" if number else prefix
                display_map[(type_name, idx)] = {
                    "display_name": display_name,
                    "token": token,
                    "lines": unique["lines"],
                    "extension_of": unique.get("extension_of"),
                }

        tokens_in_flow: List[str] = []
        for occ in occurrences:
            key = (occ["type"], occ["unique_idx"])
            mapping = display_map.get(key)
            if mapping:
                tokens_in_flow.append(mapping["token"])

        body_blocks: List[str] = []
        if leading_lines:
            leading = "\n".join(leading_lines).rstrip()
            if leading:
                body_blocks.append(leading)

        for unique_id in unique_order:
            mapping = display_map[unique_id]
            section_lines = mapping["lines"]
            header_line = f"{mapping['display_name']}:"
            block_parts = [header_line]
            if section_lines and (len(section_lines) == 0 or section_lines[0].strip() != ""):
                block_parts.append("")
            block_parts.append("\n".join(section_lines).rstrip())
            body_blocks.append("\n".join(part for part in block_parts if part != ""))

        body = "\n\n".join(blocks for blocks in body_blocks if blocks.strip() != "").rstrip() + "\n"
        if tokens_in_flow:
            meta["Flow"] = ", ".join(tokens_in_flow)
    elif not meta["Flow"]:
        section_tokens: List[str] = []
        for line in body.split("\n"):
            if not line.strip():
                continue
            m = re.match(r"^([A-Za-z ]+):\s*$", line.strip())
            if not m:
                continue
            name = m.group(1).strip()
            low = name.lower()
            token = None
            if low.startswith("intro"):
                token = "Intro"
            elif low.startswith("verse"):
                num = "".join(ch for ch in name if ch.isdigit()) or "1"
                token = f"V{num}"
            elif "pre" in low:
                num = "".join(ch for ch in name if ch.isdigit()) or "1"
                token = f"PC{num}"
            elif "chorus" in low:
                num = "".join(ch for ch in name if ch.isdigit()) or "1"
                token = f"C{num}"
            elif "bridge" in low or low == "b":
                token = "B"
            elif "solo" in low:
                token = "Solo"
            elif "outro" in low:
                token = "Outro"
            elif "tag" in low:
                token = "Tag"
            if token and token not in section_tokens:
                section_tokens.append(token)
        if section_tokens:
            meta["Flow"] = " ".join(section_tokens)

    header_lines = [
        title,
        artist,
        *(f"{name}: {meta[name]}" for name in meta_names),
        "",
        "",
    ]

    rebuilt = "\n".join(header_lines) + body
    return rebuilt


def main() -> int:
    tab = os.environ.get("TAB_CONTENT", "")
    artist_fb = os.environ.get("ARTIST_FB", "")
    title_fb = os.environ.get("TITLE_FB", "")
    file_base = os.environ.get("FILE_BASE", "")

    if not tab:
        print("TAB_CONTENT is required", file=sys.stderr)
        return 1

    rebuilt = rebuild_formatted_tab(tab, artist_fb, title_fb, file_base)
    print(rebuilt)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
