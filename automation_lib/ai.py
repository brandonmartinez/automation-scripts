from __future__ import annotations

import getpass
import json
import logging
import os
from pathlib import Path
import re
import tempfile
import time

from .runtime import (
    AutomationError, atomic_bytes, optional_tool, read_json, run,
)


PROMPTS = read_json(Path(__file__).with_name("prompts.json"))


def compact(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def object_response(text: str) -> dict:
    """Decode the shell helper's JSON (including double-encoded objects)."""
    try:
        value = json.loads(text)
        if isinstance(value, str):
            value = json.loads(value)
    except (ValueError, TypeError) as exc:
        raise AutomationError("AI response was not a JSON object") from exc
    if not isinstance(value, dict):
        raise AutomationError("AI response was not a JSON object")
    if value.get("error"):
        raise AutomationError("AI provider returned an error object")
    return value


def normalized_request(payload: dict) -> dict:
    body = json.loads(json.dumps(payload))
    model = body.get("model") or os.environ.get("OPENAI_MODEL") or "gpt-5.4"
    body["model"] = model
    if model.startswith("gpt-5"):
        body.pop("temperature", None)
    response_format = body.get("response_format", {})
    if response_format.get("type") == "json_schema" and not re.match(
        r"^(gpt-4o|gpt-4\.1|gpt-5|o1|o3|o4)", model
    ):
        schema = response_format["json_schema"]["schema"]
        body["response_format"] = {"type": "json_object"}
        body["messages"][-1]["content"] += "\n\nReturn only JSON matching this schema:\n" + compact(schema)
    effort = os.environ.get("OPENAI_REASONING_EFFORT", "low")
    # The legacy :- default also maps an explicitly empty variable to low.
    effort = effort or "low"
    body["reasoning_effort"] = body.get("reasoning_effort") or effort
    return body


class Client:
    def __init__(self, log: logging.Logger):
        self.log = log
        self.base = (os.environ.get("OPENAI_API_BASE_URL") or "https://api.openai.com/v1").rstrip("/")
        self.key: str | None = None

    def credentials(self) -> str:
        if self.key:
            return self.key
        key = os.environ.get("OPENAI_API_KEY", "")
        if key:
            self.key = key
            return key
        user = os.environ.get("USER") or getpass.getuser()
        environment = os.environ.copy()
        if optional_tool("op"):
            if not environment.get("OP_SERVICE_ACCOUNT_TOKEN") and optional_tool("security") and user:
                result = run(["security", "find-generic-password", "-w", "-a", user,
                              "-s", "op-service-token-openai-api"], check=False)
                if result.returncode == 0 and result.stdout.strip():
                    environment["OP_SERVICE_ACCOUNT_TOKEN"] = result.stdout.rstrip("\n")
            result = run(
                ["op", "read", f"op://{os.environ.get('OP_KEY_NAME') or 'cli/openai-api'}/credential"],
                env=environment, check=False,
            )
            if result.returncode == 0 and result.stdout.strip():
                self.key = result.stdout.rstrip("\n")
                return self.key
            self.log.warning("op read failed; trying Keychain fallback for OPENAI_API_KEY")
        else:
            self.log.warning("op CLI not found; trying Keychain fallback for OPENAI_API_KEY")
        if optional_tool("security") and user:
            result = run(["security", "find-generic-password", "-w", "-a", user,
                          "-s", "openai-api-key"], check=False)
            if result.returncode == 0 and result.stdout.strip():
                self.key = result.stdout.rstrip("\n")
                return self.key
        raise AutomationError("OPENAI_API_KEY is not set; configure the existing 1Password/Keychain resolution or environment")

    def chat(self, payload: dict, *, provider: bool = False) -> str:
        if provider:
            dump = os.environ.get("AI_DEBUG_DUMP")
            if dump:
                atomic_bytes(Path(dump).absolute(), compact(payload).encode())
            selected = os.environ.get("AI_PROVIDER") or "openai"
            if selected == "copilot":
                return self.copilot(payload)
            if selected != "openai":
                raise AutomationError(f"Unknown AI_PROVIDER '{selected}' (expected 'openai' or 'copilot')")
        body = normalized_request(payload)
        key = self.credentials()
        with tempfile.TemporaryDirectory(prefix="hazel-ai-") as temporary:
            request = Path(temporary) / "request.json"
            request.write_text(compact(body), encoding="utf-8")
            request.chmod(0o600)
            for attempt in range(1, 4):
                response = run(
                    ["curl", "-sS", "--max-time", "60", "-X", "POST",
                     f"{self.base}/chat/completions", "-H", "Content-Type: application/json",
                     "-H", f"Authorization: Bearer {key}", "-d", f"@{request}"],
                    check=False,
                )
                if response.returncode == 0:
                    break
                self.log.warning("OpenAI transport failed (attempt %s/3)", attempt)
                if attempt < 3:
                    time.sleep(2 ** attempt)
            else:
                raise AutomationError("OpenAI transport failed after 3 attempts")
        try:
            envelope = json.loads(response.stdout)
            if envelope.get("error"):
                # Do not echo untrusted provider messages containing private input.
                raise AutomationError("OpenAI API returned an error; check endpoint, model, credentials and quota")
            content = envelope["choices"][0]["message"]["content"]
        except (ValueError, KeyError, TypeError, IndexError) as exc:
            raise AutomationError("Malformed OpenAI response envelope") from exc
        if not isinstance(content, str) or not content.strip():
            raise AutomationError("No content found in OpenAI response")
        # Preserve the shared shell helper's contract: plain text is JSON-quoted.
        try:
            return compact(json.loads(content))
        except ValueError:
            return compact(content)

    def transcribe(self, audio: Path, model: str) -> str:
        key = self.credentials()
        with tempfile.TemporaryDirectory(prefix="hazel-audio-") as temporary:
            response = Path(temporary) / "response"
            result = run(
                ["curl", "-sS", "-o", response, "-w", "%{http_code}", "-X", "POST",
                 f"{self.base}/audio/transcriptions", "-H", f"Authorization: Bearer {key}",
                 "-F", f'file=@"{audio}";type=audio/ogg', "-F", f"model={model}",
                 "-F", "response_format=text"], check=False,
            )
            if result.returncode:
                raise AutomationError(f"Audio transcription transport failed (exit {result.returncode})")
            if result.stdout != "200":
                raise AutomationError(f"Audio transcription failed (HTTP {result.stdout})")
            body = response.read_text(encoding="utf-8").rstrip("\n")
            if not body.strip():
                raise AutomationError("Audio transcription returned empty text")
            return body

    def copilot(self, payload: dict) -> str:
        messages = payload.get("messages", [])
        system = "\n\n".join(m["content"] for m in messages if m["role"] == "system")
        user = "\n\n".join(m["content"] for m in messages if m["role"] == "user")
        if not (system or user):
            raise AutomationError("Copilot backend: request body had no system or user message")
        schema = payload.get("response_format", {}).get("json_schema", {}).get("schema")
        if schema:
            prompt = (
                f"{system}\n\nYou MUST respond with a SINGLE JSON object and NOTHING else. "
                "Do not include markdown, do not use code fences, do not add any commentary "
                "or explanation before or after the JSON. The object MUST validate against "
                "this exact JSON Schema — include every required key, add no extra keys, "
                f"and respect the described formats:\n\n{compact(schema)}\n\n{user}"
            )
        else:
            prompt = f"{system}\n\n{user}"
        flags = [
            "--model", os.environ.get("COPILOT_MODEL") or "gpt-5.4",
            "--output-format", "json", "--no-color", "--log-level", "none",
            "--no-auto-update", "--no-custom-instructions", "--no-ask-user",
            "--allow-all-tools", "--disable-builtin-mcps",
        ]
        config = Path(os.environ.get("COPILOT_HOME") or Path.home() / ".copilot") / "mcp-config.json"
        if config.exists():
            data = read_json(config)
            for server in sorted(data.get("mcpServers", {})):
                flags += ["--disable-mcp-server", server]
        with tempfile.TemporaryDirectory(prefix="copilot-work-") as temporary:
            for attempt in range(1, 3):
                result = run(["copilot", "-p", prompt, "-C", temporary, *flags], check=False)
                content = ""
                if result.returncode == 0:
                    try:
                        for line in result.stdout.splitlines():
                            event = json.loads(line)
                            if event.get("type") == "assistant.message":
                                content = event.get("data", {}).get("content", "")
                    except (ValueError, TypeError, AttributeError):
                        self.log.warning("Malformed Copilot JSONL (attempt %s/2)", attempt)
                        continue
                if not isinstance(content, str):
                    content = ""
                content = re.sub(r"^\s*```\w*\s*|\s*```\s*$", "", content).strip()
                if content:
                    if not schema:
                        return content
                    try:
                        return compact(json.loads(content))
                    except ValueError:
                        pass
                self.log.warning("Copilot returned no valid content (attempt %s/2)", attempt)
        raise AutomationError("Copilot backend failed to obtain a valid response after 2 attempts")
