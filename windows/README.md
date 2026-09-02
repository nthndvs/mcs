# Model Compare Studio — Windows (cross-platform port)

A Tauri 2 + React/TypeScript desktop app that drives the same comparison
workflow as the macOS app, backed by a shared Python engine.

## Layout

- `engine/model_compare.py` — stdlib-only Python engine. Runs every provider
  in parallel, streams JSONL progress events on stdout, and writes the same
  results-file contract as the macOS app (`<provider>.txt`, `summary.txt`,
  `conversation-context.txt`, cancellation markers, …).
- `app/` — Tauri 2 shell with a React + TypeScript + Tailwind frontend.

## Development

Prerequisites: Node 20+, Rust (stable), Python 3.10+.

```bash
cd app
npm install
npm run tauri dev
```

In dev the backend spawns `engine/model_compare.py` with the system Python.
Override the engine path with `MODEL_COMPARE_ENGINE=/path/to/model_compare.py`.

API keys (Meta, DeepSeek, Z.AI, Tavily) are stored in the OS credential
vault (Windows Credential Manager / macOS Keychain) via the in-app
**API Keys** dialog, and are injected into the engine's environment only.

## Windows production build

The Windows CI workflow builds a PyInstaller one-file `model_compare.exe`
and merges `app/tauri.windows.conf.json` so the app bundles the exe —
end users do not need Python installed.

Locally on Windows:

```powershell
pip install pyinstaller
pyinstaller --onefile --name model_compare --distpath engine\dist engine\model_compare.py
cd app
npm ci
npx tauri build --config tauri.windows.conf.json
```

The unsigned NSIS/MSI installer will show a SmartScreen warning on first
launch (same class of warning as the unsigned macOS DMG) until the binary
is code-signed.

## Notes

- CLI providers (Codex, Claude, Grok, GLM, Kimi, Qwen, Google) are resolved
  from `PATH`, `<NAME>_BIN` overrides, and well-known install locations on
  both platforms (`%APPDATA%\npm`, `%LOCALAPPDATA%\Programs`, `~/.kimi-code/bin`, …).
- Meta and DeepSeek are direct-API providers with native web search and a
  Tavily-brief fallback.
- The macOS app and this port share provider/model catalogs and the
  Fast Mode preset.
