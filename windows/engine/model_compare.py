#!/usr/bin/env python3
"""Model Compare engine — cross-platform (macOS/Windows/Linux), stdlib-only.

Drives multiple LLM providers in parallel and writes results using the same
file contract as the macOS Model Compare Studio app, so frontends on any
platform can share one engine.

Result files (inside the run's results directory):
    <provider>.txt            answer text per provider
    summary.txt               synthesis answer
    conversation-context.txt  full context for follow-up turns
    README.md                 run manifest
    <key>.stderr              captured stderr on failure
    <key>.raw.json            raw API response (direct-API providers)
    .stop-waiting-<key>       cancellation marker (written by the frontend)
    .<key>.command-pid        pid of a running provider subprocess
    .kimi-quota-exhausted     marker when Kimi reports a usage limit

Events are emitted on stdout as JSON Lines so a parent process can stream
progress:
    {"event": "results_dir", "path": ...}
    {"event": "start", "provider": ...}
    {"event": "skip", "provider": ..., "reason": ...}
    {"event": "done", "provider": ..., "status": "ok|error|stopped", "elapsed": ...}
    {"event": "summary_start"} / {"event": "summary_done", ...}
    {"event": "log", "message": ...}
    {"event": "run_complete"}

API keys are read from the environment only (never from argv or files):
    META_API_KEY, DEEPSEEK_API_KEY, ZAI_API_KEY, TAVILY_API_KEY
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

PROVIDERS = ["codex", "claude", "grok", "glm", "kimi", "qwen", "google", "meta", "deepseek"]

DEFAULT_MODELS = {
    "meta": "muse-spark-1.3",
    "deepseek": "deepseek-v4-pro",
    "glm": "glm-5.3",
}

MAX_FILE_TEXT_BYTES = 256 * 1024
MAX_TOTAL_TEXT_BYTES = 750 * 1024

TEXT_EXTENSIONS = {
    ".txt", ".md", ".markdown", ".csv", ".tsv", ".json", ".jsonl", ".xml",
    ".yaml", ".yml", ".toml", ".ini", ".cfg", ".log", ".py", ".js", ".jsx",
    ".ts", ".tsx", ".html", ".htm", ".css", ".scss", ".zsh", ".sh", ".bash",
    ".swift", ".rs", ".go", ".java", ".c", ".h", ".cpp", ".hpp", ".cs",
    ".rb", ".php", ".sql", ".r", ".m", ".kt", ".scala", ".lua", ".pl",
    ".tex", ".diff", ".patch",
}

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".bmp", ".tiff"}

_print_lock = threading.Lock()


def emit(event: str, **fields) -> None:
    """Emit one JSONL progress event on stdout."""
    payload = {"event": event}
    payload.update(fields)
    with _print_lock:
        print(json.dumps(payload, ensure_ascii=False), flush=True)


# ---------------------------------------------------------------------------
# CLI discovery
# ---------------------------------------------------------------------------

def _candidate_paths(name: str):
    """Well-known install locations for a CLI binary, per platform."""
    home = Path.home()
    candidates = []
    if os.name == "nt":
        appdata = os.environ.get("APPDATA", "")
        localappdata = os.environ.get("LOCALAPPDATA", "")
        exts = [".exe", ".cmd", ".bat", ""]
        dirs = []
        if appdata:
            dirs.append(Path(appdata) / "npm")
        if localappdata:
            dirs.append(Path(localappdata) / "Programs")
        dirs += [
            home / ".kimi-code" / "bin",
            home / ".qwen" / "bin",
            home / ".grok" / "bin",
            home / ".local" / "bin",
        ]
        for d in dirs:
            for ext in exts:
                candidates.append(d / (name + ext))
    else:
        dirs = [
            home / ".kimi-code" / "bin",
            home / ".qwen" / "bin",
            home / ".grok" / "bin",
            home / ".local" / "bin",
            Path("/opt/homebrew/bin"),
            Path("/usr/local/bin"),
        ]
        for d in dirs:
            candidates.append(d / name)
        if name == "codex":
            candidates.append(
                Path("/Applications/ChatGPT.app/Contents/Resources/codex")
            )
    return candidates


def find_cli(name: str):
    """Locate a provider CLI. X_BIN env override -> PATH -> well-known dirs."""
    override = os.environ.get(f"{name.upper()}_BIN")
    if override and Path(override).exists():
        return override
    found = shutil.which(name)
    if found:
        return found
    for candidate in _candidate_paths(name):
        if candidate.exists():
            return str(candidate)
    return None


# ---------------------------------------------------------------------------
# HTTP helper
# ---------------------------------------------------------------------------

def _post_json(url: str, api_key: str, body: dict, timeout: int = 600):
    """POST JSON with a Bearer token. Returns (parsed_dict | None, error | None)."""
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
        try:
            return json.loads(raw), None
        except json.JSONDecodeError:
            return None, f"invalid JSON response: {raw[:300]}"
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            err_body = exc.read().decode("utf-8", errors="replace")
            parsed = json.loads(err_body)
            detail = parsed.get("error", {}).get("message") or err_body[:300]
        except Exception:
            detail = err_body[:300] if "err_body" in dir() else ""
        return None, f"HTTP {exc.code}: {detail}"
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return None, f"network error: {exc}"


# ---------------------------------------------------------------------------
# Tavily shared research brief (lazy, thread-safe, one-shot per run)
# ---------------------------------------------------------------------------

class TavilyBrief:
    def __init__(self, api_key, web_search: bool, query: str, results_dir: Path):
        self.api_key = api_key
        self.web_search = web_search
        self.query = query
        self.results_dir = results_dir
        self._lock = threading.Lock()
        self._brief = None

    def get(self):
        with self._lock:
            if self._brief is None:
                self._brief = self._fetch()
            return self._brief

    def _fetch(self):
        if not (self.web_search and self.api_key):
            return None
        body = {
            "query": self.query,
            "search_depth": "basic",
            "max_results": 5,
            "include_answer": True,
            "include_raw_content": False,
        }
        parsed, err = _post_json(
            "https://api.tavily.com/search", self.api_key, body, timeout=60
        )
        if err or not parsed:
            emit("log", message=f"Tavily brief unavailable: {err}")
            return None
        try:
            (self.results_dir / "tavily-research.raw.json").write_text(
                json.dumps(parsed, indent=2, ensure_ascii=False), encoding="utf-8"
            )
        except OSError:
            pass
        answer = parsed.get("answer") or ""
        results = parsed.get("results") or []
        lines = ["SHARED WEB RESEARCH BRIEF (Tavily)", ""]
        if answer:
            lines += ["Summary:", answer, ""]
        if results:
            lines.append("Sources:")
            for item in results:
                title = item.get("title") or "(untitled)"
                url = item.get("url") or ""
                snippet = (item.get("content") or "")[:400]
                lines.append(f"- {title} — {url}")
                if snippet:
                    lines.append(f"  {snippet}")
        brief = "\n".join(lines)
        try:
            (self.results_dir / "tavily-research.txt").write_text(brief, encoding="utf-8")
        except OSError:
            pass
        return brief


# ---------------------------------------------------------------------------
# Direct-API providers (Meta, DeepSeek)
# ---------------------------------------------------------------------------

API_ENDPOINTS = {
    "meta": {
        "responses": "https://api.meta.ai/v1/responses",
        "chat": "https://api.meta.ai/v1/chat/completions",
        "key_env": "META_API_KEY",
    },
    "deepseek": {
        "responses": "https://api.deepseek.com/responses",
        "chat": "https://api.deepseek.com/chat/completions",
        "key_env": "DEEPSEEK_API_KEY",
    },
}


def _extract_responses_text(parsed: dict):
    """Extract answer text plus a search audit trail from a Responses API payload."""
    text = parsed.get("output_text")
    citations = []
    queries = []
    if not text:
        parts = []
        for item in parsed.get("output") or []:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "message":
                for content in item.get("content") or []:
                    if isinstance(content, dict) and content.get("type") == "output_text":
                        parts.append(content.get("text") or "")
                        for ann in content.get("annotations") or []:
                            if isinstance(ann, dict) and ann.get("type") == "url_citation":
                                url = ann.get("url")
                                if url:
                                    citations.append(url)
            elif item.get("type") == "web_search_call":
                action = item.get("action") or {}
                query = action.get("query")
                if query:
                    queries.append(query)
        text = "\n\n".join(p for p in parts if p)
    else:
        for item in parsed.get("output") or []:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "message":
                for content in item.get("content") or []:
                    if isinstance(content, dict):
                        for ann in content.get("annotations") or []:
                            if isinstance(ann, dict) and ann.get("type") == "url_citation":
                                url = ann.get("url")
                                if url:
                                    citations.append(url)
            elif item.get("type") == "web_search_call":
                query = (item.get("action") or {}).get("query")
                if query:
                    queries.append(query)
    if citations:
        seen = []
        for url in citations:
            if url not in seen:
                seen.append(url)
        text += "\n\nSources searched:\n" + "\n".join(f"- {u}" for u in seen)
    elif queries:
        text += "\n\nWeb searches performed:\n" + "\n".join(f"- {q}" for q in queries)
    return text.strip() or None


def invoke_responses_api(key: str, model: str, effort, prompt: str, results_dir: Path):
    """Call the OpenAI-style Responses API with native web_search enabled.

    Returns (answer | None, error | None).
    """
    spec = API_ENDPOINTS[key]
    api_key = os.environ.get(spec["key_env"])
    if not api_key:
        return None, f"{spec['key_env']} is not set"
    body = {
        "model": model,
        "input": prompt,
        "stream": False,
        "tools": [{"type": "web_search"}],
    }
    if effort and effort != "default":
        # OpenAI-style `reasoning` object (Meta rejects `reasoning_effort` here).
        body["reasoning"] = {"effort": effort}
    parsed, err = _post_json(spec["responses"], api_key, body, timeout=600)
    if err or not parsed:
        return None, err or "empty response"
    try:
        (results_dir / f"{key}.raw.json").write_text(
            json.dumps(parsed, indent=2, ensure_ascii=False), encoding="utf-8"
        )
    except OSError:
        pass
    text = _extract_responses_text(parsed)
    if not text:
        return None, "no text in responses API payload"
    return text, None


def invoke_chat_api(key: str, model: str, effort, prompt: str, results_dir: Path):
    """Call the chat/completions endpoint. Returns (answer | None, error | None)."""
    spec = API_ENDPOINTS[key]
    api_key = os.environ.get(spec["key_env"])
    if not api_key:
        return None, f"{spec['key_env']} is not set"
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
    }
    if effort and effort != "default":
        body["reasoning_effort"] = effort
    parsed, err = _post_json(spec["chat"], api_key, body, timeout=600)
    if err or not parsed:
        return None, err or "empty response"
    try:
        choices = parsed.get("choices") or []
        text = choices[0].get("message", {}).get("content")
    except (IndexError, AttributeError):
        return None, "no choices in chat completion payload"
    if not text:
        return None, "empty completion content"
    return text.strip(), None


def invoke_direct_api(key: str, model: str, effort, prompt: str, web_search: bool,
                      tavily: TavilyBrief, results_dir: Path):
    """Native-search-first strategy for direct-API providers.

    1. Try the Responses API with native web_search (when enabled).
    2. On failure, fall back to chat/completions with the Tavily brief and an
       honesty line so the model does not claim it searched.
    """
    if web_search:
        answer, err = invoke_responses_api(key, model, effort, prompt, results_dir)
        if answer:
            return answer, None
        emit("log", message=f"{key}: native search failed ({err}); falling back to chat + Tavily")
        try:
            with open(results_dir / f"{key}.stderr", "a", encoding="utf-8") as fh:
                fh.write(f"[native responses API failed, used chat fallback] {err}\n")
        except OSError:
            pass
    augmented = prompt
    brief = tavily.get()
    if brief:
        augmented = (
            prompt
            + "\n\n"
            + brief
            + "\n\nYou have no web-search tools in this comparison; "
              "do not claim to have searched beyond these supplied sources."
        )
    return invoke_chat_api(key, model, effort, augmented, results_dir)


# ---------------------------------------------------------------------------
# Provider CLI command construction
# ---------------------------------------------------------------------------

GROK_DISALLOWED_TOOLS = (
    "run_terminal_cmd,search_replace,read_file,grep,list_dir,"
    "task,todo_write,search_tool,use_tool"
)


def build_provider_command(key: str, binary: str, model, effort, prompt: str,
                           allow_tools: bool, web_search: bool, image_paths,
                           tavily_key, zai_key, glm_mcp_config):
    """Build (argv, extra_env) for a CLI provider, matching the macOS contract."""
    argv = [binary]
    extra_env = {}

    if key == "codex":
        for img in image_paths or []:
            argv += ["--image", img]
        argv += ["exec", "--skip-git-repo-check"]
        if model:
            argv += ["--model", model]
        if effort and effort != "default":
            argv += ["-c", f'model_reasoning_effort="{effort}"']
        if web_search:
            argv += ["--search"]
        if not allow_tools:
            argv += ["--sandbox", "read-only", "--ask-for-approval", "never"]
        argv.append(prompt)

    elif key in ("claude", "glm"):
        if web_search:
            argv += ["--allowedTools", "WebSearch,WebFetch"]
        else:
            argv += ["--disallowedTools", "WebSearch,WebFetch"]
        if key == "claude":
            if model:
                argv += ["--model", model]
        if effort and effort != "default":
            argv += ["--effort", effort]
        argv += ["-p", prompt, "--output-format", "text"]
        if key == "glm":
            glm_model = model or DEFAULT_MODELS["glm"]
            extra_env = {
                "ANTHROPIC_AUTH_TOKEN": zai_key or "",
                "ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic",
                "API_TIMEOUT_MS": "3000000",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                "ANTHROPIC_DEFAULT_OPUS_MODEL": glm_model,
                "ANTHROPIC_DEFAULT_SONNET_MODEL": glm_model,
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": glm_model,
            }
            argv += ["--model", "sonnet"]
            if glm_mcp_config:
                argv += ["--mcp-config", glm_mcp_config, "--strict-mcp-config"]

    elif key == "grok":
        if model:
            argv += ["--model", model]
        if effort and effort != "default":
            argv += ["--reasoning-effort", effort]
        argv += ["--no-plan", "--always-approve", "--output-format", "json"]
        if not allow_tools:
            argv += ["--disallowed-tools", GROK_DISALLOWED_TOOLS]
        argv += ["-p", prompt]

    elif key == "kimi":
        if model:
            argv += ["--model", model]
        argv += ["-p", prompt, "--output-format", "text"]

    elif key == "qwen":
        argv += ["--auth-type", "openai"]
        argv += ["--approval-mode", "plan"] if not allow_tools else ["--yolo"]
        if model:
            argv += ["--model", model]
        argv += ["-p", prompt, "--output-format", "text"]

    elif key == "google":
        if allow_tools:
            argv += ["--mode", "accept-edits", "--dangerously-skip-permissions"]
        else:
            argv += ["--mode", "plan", "--sandbox"]
        if model:
            argv += ["--model", model]
        if effort and effort != "default":
            argv += ["--effort", effort]
        argv += ["-p", prompt, "--output-format", "text"]

    return argv, extra_env


# ---------------------------------------------------------------------------
# Runner: subprocess management, cancellation, output capture
# ---------------------------------------------------------------------------

class Runner:
    def __init__(self, results_dir: Path, workspace_root: Path):
        self.results_dir = results_dir
        self.workspace_root = workspace_root

    def cancellation_requested(self, key: str) -> bool:
        return (self.results_dir / f".stop-waiting-{key}").exists()

    def provider_workdir(self, key: str) -> Path:
        workdir = self.workspace_root / key
        workdir.mkdir(parents=True, exist_ok=True)
        return workdir

    def write_manual_skip(self, key: str) -> None:
        try:
            (self.results_dir / f"{key}.txt").write_text(
                "Skipped: stopped waiting by user.", encoding="utf-8"
            )
        except OSError:
            pass

    def run_command(self, key: str, argv, extra_env, parse_grok_json: bool = False):
        """Run a provider CLI with cancellation polling.

        Returns (answer | None, error | None). error may be the string
        "stopped" for user cancellation.
        """
        env = os.environ.copy()
        env.update(extra_env or {})
        use_shell = (
            os.name == "nt" and str(argv[0]).lower().endswith((".cmd", ".bat"))
        )
        try:
            proc = subprocess.Popen(
                argv,
                shell=use_shell,
                cwd=str(self.provider_workdir(key)),
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
        except OSError as exc:
            return None, f"failed to launch {argv[0]}: {exc}"

        try:
            (self.results_dir / f".{key}.command-pid").write_text(
                str(proc.pid), encoding="utf-8"
            )
        except OSError:
            pass

        # Poll for completion so we can honor the cancellation marker.
        while proc.poll() is None:
            if self.cancellation_requested(key):
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                self.write_manual_skip(key)
                return None, "stopped"
            time.sleep(0.2)

        stdout, stderr = proc.communicate()
        if stderr and stderr.strip():
            try:
                (self.results_dir / f"{key}.stderr").write_text(
                    stderr, encoding="utf-8"
                )
            except OSError:
                pass
        if self.cancellation_requested(key):
            self.write_manual_skip(key)
            return None, "stopped"
        if proc.returncode != 0:
            detail = (stderr or "").strip().splitlines()
            tail = detail[-1] if detail else ""
            return None, f"exit code {proc.returncode}: {tail}".strip().strip(":")
        text = (stdout or "").strip()
        if not text:
            return None, "empty output"
        if parse_grok_json:
            text = self._parse_grok_output(text)
            if not text:
                return None, "no text in grok JSON output"
        return text, None

    @staticmethod
    def _parse_grok_output(raw: str):
        """Grok prints JSON or JSONL; pull the first text-ish field found."""
        candidates = []
        try:
            candidates.append(json.loads(raw))
        except json.JSONDecodeError:
            for line in raw.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    candidates.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
        for obj in candidates:
            if not isinstance(obj, dict):
                continue
            for field in ("text", "content", "message", "response"):
                value = obj.get(field)
                if isinstance(value, str) and value.strip():
                    return value.strip()
                if isinstance(value, dict):
                    nested = value.get("text") or value.get("content")
                    if isinstance(nested, str) and nested.strip():
                        return nested.strip()
        return None


# ---------------------------------------------------------------------------
# Attachments and prompt assembly
# ---------------------------------------------------------------------------

def extract_attachment_text(path: Path):
    """Return (text | None, note | None) for a supported attachment."""
    suffix = path.suffix.lower()
    try:
        size = path.stat().st_size
    except OSError as exc:
        return None, f"unreadable: {exc}"
    if suffix == ".docx":
        try:
            import zipfile

            with zipfile.ZipFile(path) as zf:
                xml = zf.read("word/document.xml").decode("utf-8", errors="replace")
            text = re.sub(r"<w:p[ >]", "\n<w:p ", xml)
            text = re.sub(r"<[^>]+>", "", text)
            return text.strip(), None
        except Exception as exc:  # zipfile.BadZipFile, KeyError, ...
            return None, f"docx extraction failed: {exc}"
    if suffix == ".pdf":
        try:
            from pypdf import PdfReader  # optional dependency
        except ImportError:
            return None, "pypdf not installed; PDF text not extracted"
        try:
            reader = PdfReader(str(path))
            text = "\n\n".join(page.extract_text() or "" for page in reader.pages)
            return text.strip() or None, None
        except Exception as exc:
            return None, f"pdf extraction failed: {exc}"
    if size > MAX_FILE_TEXT_BYTES:
        return None, f"skipped: larger than {MAX_FILE_TEXT_BYTES // 1024} KB"
    try:
        return path.read_text(encoding="utf-8", errors="replace"), None
    except OSError as exc:
        return None, f"unreadable: {exc}"


def build_prompt(prompt: str, conversation_context, attachments,
                 allow_tools: bool, web_search: bool):
    """Assemble the full provider prompt. Returns (prompt_text, image_paths)."""
    sections = []
    if conversation_context:
        sections.append(
            "This is a follow-up question in an ongoing comparison session. "
            "Here is the conversation so far (your earlier answer is included "
            "under your provider name):\n\n" + conversation_context
        )
    if not allow_tools:
        sections.append(
            "IMPORTANT CONSTRAINT: You are running in a read-only sandbox. Do "
            "not create, modify, or delete files, and do not install anything. "
            "Answer with text only."
        )

    image_paths = []
    if attachments:
        embedded = []
        total = 0
        for raw in attachments:
            path = Path(raw)
            suffix = path.suffix.lower()
            if not path.exists():
                embedded.append(f"[Attachment missing: {raw}]")
                continue
            if suffix in IMAGE_EXTENSIONS:
                image_paths.append(str(path))
                embedded.append(f"[Image attached separately: {path.name}]")
                continue
            if suffix not in TEXT_EXTENSIONS and suffix not in (".docx", ".pdf"):
                embedded.append(f"[Attachment skipped (unsupported type): {path.name}]")
                continue
            text, note = extract_attachment_text(path)
            if text:
                remaining = MAX_TOTAL_TEXT_BYTES - total
                if remaining <= 0:
                    embedded.append(f"[Attachment skipped (budget used): {path.name}]")
                    continue
                encoded = text.encode("utf-8")
                if len(encoded) > remaining:
                    text = encoded[:remaining].decode("utf-8", errors="ignore")
                    text += "\n[...truncated]"
                total += len(text.encode("utf-8"))
                embedded.append(
                    f"===== ATTACHMENT: {path.name} =====\n{text}\n===== END ATTACHMENT ====="
                )
            else:
                embedded.append(f"[Attachment not included: {path.name} — {note}]")
        if embedded:
            sections.append("Attached files:\n\n" + "\n\n".join(embedded))

    if web_search:
        sections.append(
            "ONLINE RESEARCH: If you have web-search tools available, use them "
            "to research this question with current sources, and cite the "
            "sources you used. A shared research brief may be included below; "
            "treat it as a starting point only — perform your own additional "
            "research beyond it whenever your tools allow. If you have no "
            "web-search tools, say so explicitly instead of claiming you "
            "searched."
        )

    sections.append("USER REQUEST:\n" + prompt)
    return "\n\n".join(sections), image_paths


def build_summary_prompt(prompt: str, results_dir: Path, providers):
    sections = [
        "You are synthesizing answers from multiple AI models to the same user "
        "request. Produce a single best answer.",
        "Instructions: identify where the models agree and disagree, resolve "
        "disagreements with reasoning, and deliver the strongest combined "
        "answer. Do not mention this instruction block.",
        "USER REQUEST:\n" + prompt,
        "MODEL ANSWERS:",
    ]
    included = 0
    for key in providers:
        path = results_dir / f"{key}.txt"
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="replace").strip()
        if not text or text.startswith("Skipped:"):
            continue
        sections.append(f"===== {key.upper()} =====\n{text}")
        included += 1
    if included == 0:
        return None
    return "\n\n".join(sections)


# ---------------------------------------------------------------------------
# Provider execution
# ---------------------------------------------------------------------------

def run_provider(key: str, args, runner: Runner, prompt: str, image_paths,
                 tavily: TavilyBrief, glm_mcp_config):
    """Run one provider end to end, emitting start/skip/done events."""
    emit("start", provider=key)
    started = time.time()

    def finish(answer, error):
        elapsed = round(time.time() - started, 2)
        if error == "stopped":
            emit("done", provider=key, status="stopped", elapsed=elapsed)
            return
        if error:
            try:
                with open(runner.results_dir / f"{key}.stderr", "a",
                          encoding="utf-8") as fh:
                    fh.write(f"[{key}] {error}\n")
            except OSError:
                pass
            emit("done", provider=key, status="error", error=error, elapsed=elapsed)
            return
        try:
            (runner.results_dir / f"{key}.txt").write_text(answer, encoding="utf-8")
        except OSError as exc:
            emit("done", provider=key, status="error",
                 error=f"could not write result: {exc}", elapsed=elapsed)
            return
        emit("done", provider=key, status="ok", elapsed=elapsed)

    model = getattr(args, f"{key}_model", None) or DEFAULT_MODELS.get(key)
    effort = getattr(args, f"{key}_effort", None)

    if key in API_ENDPOINTS:
        spec = API_ENDPOINTS[key]
        if not os.environ.get(spec["key_env"]):
            emit("skip", provider=key, reason=f"{spec['key_env']} not set")
            return
        answer, error = invoke_direct_api(
            key, model, effort, prompt, args.web_search, tavily, runner.results_dir
        )
        finish(answer, error)
        return

    if key == "kimi" and not args.allow_tools:
        emit("skip", provider=key,
             reason="Kimi requires tool access; enable allow-tools to include it")
        return

    if key == "glm" and not os.environ.get("ZAI_API_KEY"):
        emit("skip", provider=key, reason="ZAI_API_KEY not set")
        return

    binary = find_cli("claude" if key == "glm" else ("agy" if key == "google" else key))
    if not binary:
        emit("skip", provider=key, reason=f"CLI not found for {key}")
        return

    argv, extra_env = build_provider_command(
        key, binary, model, effort, prompt, args.allow_tools, args.web_search,
        image_paths, os.environ.get("TAVILY_API_KEY"),
        os.environ.get("ZAI_API_KEY"), glm_mcp_config,
    )
    if key == "qwen":
        # Qwen reads Z.AI / Tavily keys from the environment directly.
        pass
    answer, error = runner.run_command(
        key, argv, extra_env, parse_grok_json=(key == "grok")
    )

    if key == "kimi" and error and re.search(r"usage limit|quota", error, re.I):
        try:
            (runner.results_dir / ".kimi-quota-exhausted").write_text(
                error, encoding="utf-8"
            )
        except OSError:
            pass
    finish(answer, error)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Model Compare engine")
    parser.add_argument("prompt")
    parser.add_argument("--allow-tools", action="store_true")
    parser.add_argument("--web-search", dest="web_search",
                        action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--context-file")
    parser.add_argument("--attachment", action="append", default=[])
    parser.add_argument("--provider", action="append", choices=PROVIDERS,
                        default=None, help="Providers to include (default: all)")
    parser.add_argument("--summary-model", default="")
    parser.add_argument("--summary-model-id", default="")
    parser.add_argument("--summary-effort", default="default")
    parser.add_argument("--results-dir", default="")
    parser.add_argument("--workspace-root", default="")
    for key in PROVIDERS:
        parser.add_argument(f"--{key}-model", default="")
        parser.add_argument(f"--{key}-effort", default="default")
    args = parser.parse_args(argv)

    base_results = (
        args.results_dir
        or os.environ.get("MODEL_COMPARE_RESULTS_DIR")
        or str(Path.cwd() / "results")
    )
    stamp = time.strftime("%Y%m%d-%H%M%S")
    results_dir = Path(base_results) / stamp
    results_dir.mkdir(parents=True, exist_ok=True)

    workspace_root = Path(
        args.workspace_root
        or os.environ.get("MODEL_COMPARE_WORKSPACE_ROOT")
        or (results_dir / "artifacts")
    )
    workspace_root.mkdir(parents=True, exist_ok=True)

    emit("results_dir", path=str(results_dir))

    conversation_context = None
    if args.context_file:
        try:
            conversation_context = Path(args.context_file).read_text(
                encoding="utf-8", errors="replace"
            )
        except OSError as exc:
            emit("log", message=f"could not read context file: {exc}")

    prompt, image_paths = build_prompt(
        args.prompt, conversation_context, args.attachment,
        args.allow_tools, args.web_search,
    )

    included = [k for k in PROVIDERS if not args.provider or k in args.provider]

    tavily = TavilyBrief(
        os.environ.get("TAVILY_API_KEY"), args.web_search, args.prompt, results_dir
    )

    # GLM talks to Tavily over MCP; write a key-bearing config to a temp file.
    glm_mcp_config = None
    tavily_key = os.environ.get("TAVILY_API_KEY")
    if "glm" in included and args.web_search and tavily_key:
        fd, glm_mcp_config = tempfile.mkstemp(prefix="glm-mcp-", suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(
                    {"mcpServers": {"tavily": {
                        "type": "http",
                        "url": f"https://mcp.tavily.com/mcp/?tavilyApiKey={tavily_key}",
                    }}},
                    fh,
                )
            os.chmod(glm_mcp_config, 0o600)
        except OSError:
            glm_mcp_config = None

    runner = Runner(results_dir, workspace_root)
    try:
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=max(1, len(included))
        ) as pool:
            futures = [
                pool.submit(run_provider, key, args, runner, prompt,
                            image_paths, tavily, glm_mcp_config)
                for key in included
            ]
            for future in concurrent.futures.as_completed(futures):
                future.result()

        # Synthesis
        if args.summary_model:
            emit("summary_start")
            summary_prompt = build_summary_prompt(
                args.prompt, results_dir, included
            )
            if summary_prompt is None:
                emit("summary_done", status="error",
                     error="no provider answers to synthesize")
            else:
                skey = args.summary_model
                smodel = args.summary_model_id or None
                seffort = args.summary_effort
                if skey in API_ENDPOINTS:
                    answer, error = invoke_direct_api(
                        skey, smodel or DEFAULT_MODELS.get(skey), seffort,
                        summary_prompt, args.web_search, tavily, results_dir,
                    )
                else:
                    binary = find_cli(
                        "claude" if skey == "glm" else ("agy" if skey == "google" else skey)
                    )
                    if not binary:
                        answer, error = None, f"CLI not found for {skey}"
                    else:
                        argv2, env2 = build_provider_command(
                            skey, binary, smodel, seffort, summary_prompt,
                            args.allow_tools, False, [], tavily_key,
                            os.environ.get("ZAI_API_KEY"), glm_mcp_config,
                        )
                        answer, error = runner.run_command(
                            "summary", argv2, env2,
                            parse_grok_json=(skey == "grok"),
                        )
                if error:
                    emit("summary_done", status="error", error=error)
                else:
                    (results_dir / "summary.txt").write_text(
                        answer, encoding="utf-8"
                    )
                    emit("summary_done", status="ok")

        # conversation-context.txt for follow-up turns
        context_parts = ["USER REQUEST:\n" + args.prompt, ""]
        for key in included:
            path = results_dir / f"{key}.txt"
            if path.exists():
                context_parts.append(
                    f"===== {key.upper()} =====\n"
                    + path.read_text(encoding="utf-8", errors="replace")
                )
        summary_path = results_dir / "summary.txt"
        if summary_path.exists():
            context_parts.append(
                "===== SYNTHESIS =====\n"
                + summary_path.read_text(encoding="utf-8", errors="replace")
            )
        (results_dir / "conversation-context.txt").write_text(
            "\n\n".join(context_parts), encoding="utf-8"
        )

        readme = [
            "# Model Compare Run",
            f"- Date: {time.strftime('%Y-%m-%d %H:%M:%S')}",
            f"- Providers: {', '.join(included)}",
            f"- Web search: {'on' if args.web_search else 'off'}",
            f"- Tool access: {'on' if args.allow_tools else 'off'}",
            "",
            "## Prompt",
            args.prompt,
        ]
        (results_dir / "README.md").write_text("\n".join(readme), encoding="utf-8")
    finally:
        if glm_mcp_config:
            try:
                os.unlink(glm_mcp_config)
            except OSError:
                pass

    emit("run_complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
