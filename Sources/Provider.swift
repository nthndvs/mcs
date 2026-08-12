import Foundation

/// The full provider catalog. IDs match the launcher's `--provider` values and
/// the `<id>.txt` result files, so the UI contract stays identical to the
/// previous app.
enum ProviderID: String, CaseIterable, Codable, Identifiable {
    case codex, claude, grok, glm, kimi, qwen, google, meta, deepseek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .glm: return "GLM"
        case .kimi: return "Kimi"
        case .qwen: return "Qwen"
        case .google: return "Google"
        case .meta: return "Meta"
        case .deepseek: return "DeepSeek"
        }
    }

    var resultFileName: String { "\(rawValue).txt" }

    /// Direct pay-as-you-go API providers (no local CLI).
    var isDirectAPI: Bool { self == .meta || self == .deepseek }

    /// Model presets shown in the picker. The field stays editable for
    /// account-specific model IDs, matching the previous app.
    var modelOptions: [String] {
        switch self {
        case .codex:
            return ["Default", "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.3-codex"]
        case .claude:
            // `opus` follows Claude Code's latest Opus alias, while the explicit
            // IDs make it possible to pin a comparison to a released generation.
            return ["Default", "opus", "sonnet", "haiku", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-8", "claude-opus-4-6", "claude-sonnet-4-6", "claude-sonnet-4-5"]
        case .grok:
            // Read from the installed Grok CLI's authenticated model catalog on
            // August 12, 2026. Older Grok 4.3 and the harness name are not model
            // IDs and resulted in unnecessary request failures.
            return ["Default", "grok-4.6", "grok-4.5"]
        case .glm:
            return ["Default", "glm-5.2", "glm-5-turbo", "glm-4.7", "glm-4.5-air"]
        case .kimi:
            // Kimi Code's OAuth-managed CLI models are addressed by aliases from
            // its refreshed local catalog. `kimi-code/k3` is the Kimi K3 alias;
            // the two K2.7 entries remain available for compatibility and speed.
            return ["Default", "kimi-code/k3", "kimi-code/k3-256k", "kimi-code/kimi-for-coding", "kimi-code/kimi-for-coding-highspeed"]
        case .qwen:
            // Qwen Code's ModelStudio catalog. `qwen3.8-max-preview` is a
            // Token Plan preview: the raw model ID is sent, while the user's
            // Qwen `/auth` configuration supplies the correct plan endpoint.
            return ["Default", "qwen3.8-max-preview", "qwen3-max", "qwen3-max-preview", "qwen3-max-2026-01-23", "qwen3.7-plus", "qwen3.6-plus", "qwen3.5-plus", "qwen3-coder-plus", "qwen3-coder-next"]
        case .google:
            // Antigravity exposes the models available to the signed-in Google
            // account through `agy models`. The field remains editable for
            // account-specific additions and future releases.
            return [
                "Default",
                "gemini-3.6-flash-high", "gemini-3.6-flash-medium", "gemini-3.6-flash-low",
                "gemini-3.5-flash-high", "gemini-3.5-flash-medium", "gemini-3.5-flash-low",
                "gemini-3.1-pro-high", "gemini-3.1-pro-low",
                "claude-sonnet-4-6", "claude-opus-4-6-thinking", "gpt-oss-120b-medium",
            ]
        case .meta:
            // Meta Model API uses a direct API key rather than a consumer Meta AI
            // subscription or a local CLI. Contributor is deliberately opt-in:
            // it carries different data-use terms from the standard model.
            return ["Default", "muse-spark-1.2-contributor", "muse-spark-1.2", "muse-spark-1.1"]
        case .deepseek:
            return ["Default", "deepseek-v4-pro", "deepseek-v4-flash"]
        }
    }

    var effortOptions: [String] {
        switch self {
        case .codex: return ["Default", "low", "medium", "high", "xhigh"]
        case .claude: return ["Default", "low", "medium", "high", "xhigh", "max"]
        case .grok: return ["Default", "low", "medium", "high"]
        case .glm: return ["Default", "low", "medium", "high", "xhigh", "max"]
        case .kimi: return ["Default"]
        case .qwen: return ["Default"]
        case .google: return ["Default", "low", "medium", "high"]
        case .meta: return ["Default", "low", "medium", "high", "xhigh"]
        case .deepseek: return ["Default", "high", "max"]
        }
    }

    /// Kimi and Qwen do not accept a per-request effort flag.
    var supportsPerRequestEffort: Bool { self != .kimi && self != .qwen }

    var effortDisabledNote: String? {
        switch self {
        case .kimi: return "Kimi Code does not expose a per-request effort setting."
        case .qwen: return "Qwen Code stores reasoning effort in its own CLI settings. Use its interactive /effort command."
        default: return nil
        }
    }

    /// The CLI command looked up on PATH and in well-known install locations.
    var cliCommand: String? {
        switch self {
        case .codex: return "codex"
        case .claude, .glm: return "claude"
        case .grok: return "grok"
        case .kimi: return "kimi"
        case .qwen: return "qwen"
        case .google: return "agy"
        case .meta, .deepseek: return nil
        }
    }

    /// Provider-specific install locations checked before PATH fallbacks.
    var cliCandidatePaths: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .codex: return ["/Applications/ChatGPT.app/Contents/Resources/codex"]
        case .grok: return ["\(home)/.grok/bin/grok"]
        case .kimi: return ["\(home)/.kimi-code/bin/kimi"]
        case .qwen: return ["\(home)/.qwen/bin/qwen"]
        case .google: return ["\(home)/.local/bin/agy"]
        default: return []
        }
    }

    var installerCommand: String? {
        switch self {
        case .codex: return "curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh"
        case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
        case .grok: return "curl -fsSL https://x.ai/cli/install.sh | bash"
        case .kimi: return "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash"
        case .qwen: return "curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen-standalone.sh | bash"
        case .google: return "curl -fsSL https://antigravity.google/cli/install.sh | bash"
        default: return nil
        }
    }

    /// Terminal arguments used for the interactive sign-in flow.
    var signInArguments: String? {
        switch self {
        case .claude: return "auth login"
        case .codex, .grok, .kimi: return "login"
        case .google: return ""
        default: return nil
        }
    }

    var modelFieldNote: String {
        self == .meta
            ? "Choose a listed model or type an account-specific model ID. Contributor pricing requires muse-spark-1.2-contributor and allows Meta to use prompts and outputs to improve its models."
            : "Choose a listed model or type an account-specific model ID."
    }
}

/// Per-provider editable preferences, persisted between launches.
struct ProviderSettings: Equatable {
    var included: Bool
    var model: String = "Default"
    var effort: String = "Default"
}

/// What the UI shows for one provider's response area.
struct ResponseState: Equatable {
    enum Status: Equatable {
        case idle
        case waiting
        case ready
        case stopRequested
    }

    var status: Status = .idle
    var text: String = ""
    var elapsedSeconds: TimeInterval?

    var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

/// Connection/CLI readiness shown beside each provider.
enum CLIStatus: Equatable {
    case checking
    case installed
    case notInstalled
    case needsClaudeCode
    case needsZAIKey
    case readyViaClaude
    case apiKeySaved
    case needsAPIKey

    var label: String {
        switch self {
        case .checking: return "Checking…"
        case .installed: return "Installed"
        case .notInstalled: return "Not installed"
        case .needsClaudeCode: return "Needs Claude Code"
        case .needsZAIKey: return "Needs Z.AI key"
        case .readyViaClaude: return "Ready via Claude"
        case .apiKeySaved: return "API key saved"
        case .needsAPIKey: return "Needs API key"
        }
    }

    var isReady: Bool {
        switch self {
        case .installed, .readyViaClaude, .apiKeySaved: return true
        default: return false
        }
    }
}

/// A resumable saved conversation folder.
struct SavedChat: Identifiable, Equatable {
    let folder: URL
    let title: String

    var id: String { folder.path }
}

/// Content presented in the full-window reader overlay.
struct ReaderContent: Identifiable, Equatable {
    let title: String
    let body: String

    var id: String { title }
}

/// State for the PDF export sheet: which sections of the latest comparison
/// should be written into the report.
struct PDFExportState: Identifiable {
    let folder: URL
    let hasSynthesis: Bool
    var includeSynthesis: Bool
    let availableProviders: [ProviderID]
    var includedProviders: Set<ProviderID>

    var id: String { folder.path }

    var canExport: Bool { includeSynthesis || !includedProviders.isEmpty }
}

/// One provider's contribution to a saved quick-select preset.
struct ProviderSettingSnapshot: Codable, Equatable {
    var included: Bool
    var model: String
    var effort: String
}

/// A named, user-saved grouping of provider and synthesis settings.
struct ProviderPreset: Codable, Equatable {
    var name: String
    /// Keyed by ProviderID raw value.
    var providers: [String: ProviderSettingSnapshot]
    /// Summary provider raw value, or "none".
    var summaryProvider: String
    var summaryModel: String
    var summaryEffort: String
}
