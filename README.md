# Model Compare Studio

A ground-up SwiftUI rewrite of [Model Compare](../model-compare) with a modern,
system-native interface. It sends one prompt to every signed-in model CLI at
once, shows each answer side by side as soon as it lands, and can synthesize
the results with a model of your choice.

**The comparison engine is unchanged.** `ask-all.zsh` in this folder is a
verbatim copy of the previous launcher; every provider flag, result-folder
layout, and safety behavior is identical. Only the desktop app was rewritten.

## What's new over the previous app

- **True SwiftUI interface** that follows the system appearance (light/dark),
  accent color, and typography instead of a fixed hand-drawn dark theme.
- **Settings sidebar** — providers, synthesis, keys, and saved chats are
  organized into collapsible sections instead of one dense scroll page.
- **Adaptive response grid** — answer cards flow into as many columns as the
  window fits; each card scrolls internally, so a long answer never distorts
  the layout. No more manual divider wrangling.
- **Per-model elapsed time and word counts** on each response card, plus a
  live run timer.
- **Copy buttons** on every response and the synthesis.
- **Choose-your-sections PDF export** — pick which responses go into the PDF;
  the synthesis always leads the report, and the PDF is real, selectable text
  (rendered through the print system, not rasterized images).
- **Artifacts** — turn Safe mode off and ask the models to create something
  ("save your analysis as report.pdf"); each model writes into its own
  subfolder of the shared workspace (`Workspace/<provider>/`), and the files
  appear in the sidebar's Artifacts list labeled by model, one click to open.
  Terminal runs keep their artifacts beside that run's results instead
  (`results/<timestamp>/artifacts/<provider>/`).
- **Saved chats as a first-class list** — click to resume, right-click to
  reveal in Finder or move to Trash. The 30 newest conversations are kept.
- **Collapsible activity log** that stays out of the way until you want it.
- **Focused reader** overlay for any response or the synthesis (Esc to return).
- **Proper app icon and Dock presence** — the bundle is a first-class
  LaunchServices app you can pin (Keep in Dock) and launch from Spotlight.
- **Single Keychain vault** — all four keys (Z.AI, Tavily, Meta, DeepSeek)
  live in one Keychain item, so macOS shows at most one permission prompt
  instead of one per key. The previous app's items are migrated automatically
  on first launch and kept in sync on writes.

Everything from the previous app is preserved: nine providers (Codex, Claude,
Grok, GLM via Claude, Kimi, Qwen, Google Antigravity, plus Meta and DeepSeek
direct APIs), per-provider Include/model/effort with editable model fields,
attachments, Safe mode, online research with Z.AI/Tavily keys, synthesis with
its own model/effort, follow-ups with full conversation context, per-provider
"stop waiting", install/sign-in helpers, macOS Keychain storage, saved chats,
and PDF report export.

Existing per-provider preferences and saved chats carry over: the app reads
the same `UserDefaults` namespace and the same
`~/Library/Application Support/Model Compare/` folder. Keys are migrated from
the previous app's Keychain items into a single vault item on first launch —
click **Always Allow** if macOS asks, and you'll never be prompted again until
the app is rebuilt (ad-hoc signing changes the code identity on each build).

## Use it

Double-click **Model Compare Studio.app** in this folder, or launch once from
Terminal:

```zsh
open "tools/model-compare-studio/Model Compare Studio.app"
```

Type a question, tick the providers to include, and press **Run Comparison**
(⌘Return). Each card updates as its model finishes; the synthesis pane follows,
then offers a follow-up composer that sends the whole conversation back to
every model.

### Terminal usage

The launcher still works standalone from this folder:

```zsh
./ask-all.zsh "Compare the pros and cons of event sourcing for a small trading system."
./ask-all.zsh --summary-model claude "Compare these approaches and recommend one."
```

Results from terminal runs land in `./results` unless
`MODEL_COMPARE_RESULTS_DIR` is set (the app sets it to its Application Support
folder). See `./ask-all.zsh --help` for every flag.

## Rebuild

From this folder on an Apple Silicon Mac:

```zsh
./build-app.zsh   # compile Sources/ and assemble the .app (ad-hoc signed)
./build-dmg.zsh   # also package dist/Model-Compare-Studio-<version>.dmg
```

Requires only the Xcode Command Line Tools (`xcrun swiftc`); there is no Xcode
project to keep in sync.

## Releasing

Releases build on GitHub Actions. Tag a version and push:

```zsh
git tag v1.0.2 && git push origin main v1.0.2
```

The `Release DMG` workflow stamps the app version from the tag, builds the
DMG on a macOS runner, and publishes a GitHub Release with the DMG and its
SHA-256 attached. (Push the branch and tag in one command or the tag event
may not fire; you can also trigger the workflow manually from the Actions
tab with a tag input.)

## Layout

```
Model Compare Studio.app/   distributable app bundle (binary + Resources)
Sources/                    SwiftUI app, one concern per file
  ModelCompareStudioApp.swift   app entry, menus, window
  AppState.swift                run/stop/conversation logic, all observable state
  Provider.swift                provider catalog, response/status models
  LauncherService.swift         paths, CLI detection, Terminal sign-in
  KeychainService.swift         macOS Keychain wrapper
  SettingsStore.swift           UserDefaults persistence
  MarkdownRenderer.swift        dependency-free Markdown → attributed text
  PDFReportService.swift        shareable PDF export
  Views/                        sidebar, composer, response grid, synthesis,
                                activity log, focused reader, shared controls
ask-all.zsh                 comparison engine (verbatim from the previous app)
build-app.zsh / build-dmg.zsh packaging
```

## Notes

- Keys live in macOS Keychain, never in this repository, shell history, or
  result files; they are passed only to the short-lived launcher process.
- GLM runs through the installed Claude Code CLI with a Z.AI key; Meta and
  DeepSeek are direct pay-as-you-go APIs and begin excluded until you add keys.
- Safe mode (on by default) prevents the CLIs from changing files or running
  commands; online research (also on by default) lets supported providers use
  web search and asks every model to cite its sources.
