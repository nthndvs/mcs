import AppKit
import SwiftUI

/// Central observable state and behavior for Model Compare Studio.
///
/// The run/stop/conversation logic is a faithful port of the previous app's
/// AppDelegate: the launcher contract (`RESULTS_DIR:`, `RESPONSE_READY:`,
/// `.stop-waiting-<key>` markers, `conversation-context.txt`) is unchanged.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Prompt & attachments

    @Published var prompt = ""
    @Published var attachments: [URL] = []

    // MARK: - Provider & summary preferences

    @Published var providerSettings: [ProviderID: ProviderSettings]
    /// Raw value of the summary provider, or "none".
    @Published var summaryProviderRaw: String
    @Published var summaryModel = "Default"
    @Published var summaryEffort = "Default"

    // MARK: - Keys & options

    @Published var zaiKey = ""
    @Published var rememberZaiKey = false
    @Published var tavilyKey = ""
    @Published var rememberTavilyKey = false
    @Published var safeMode = true
    @Published var onlineResearch = true

    // MARK: - Run state

    @Published private(set) var isRunning = false
    @Published private(set) var installerRunningProvider: ProviderID?
    @Published var statusText = "Ready. Sign in to each provider once before running."
    @Published var responses: [ProviderID: ResponseState]
    @Published var synthesisText = "No conversation selected. Run a comparison to begin."
    @Published var activityLog = ""
    @Published var cliStatus: [ProviderID: CLIStatus]
    @Published var runStartedAt: Date?

    // MARK: - Conversation

    @Published var followUp = ""
    @Published var canFollowUp = false
    @Published private(set) var conversationContext = ""
    @Published var savedChats: [SavedChat] = []
    @Published var activeChatFolder: URL?
    @Published var reader: ReaderContent?
    @Published var pdfExport: PDFExportState?
    @Published var artifacts: [ArtifactItem] = []
    /// User-saved quick-select groupings, keyed by slot (1 and 2).
    @Published private(set) var customPresets: [Int: ProviderPreset] = [:]

    // MARK: - Updates

    /// A newer GitHub release, when a check found one. Drives the banner.
    @Published var availableUpdate: UpdateInfo?
    /// One-off alert text for manual "Check for Updates…" results.
    @Published var updateAlert: UpdateAlert?

    // MARK: - Private run bookkeeping

    private var process: Process?
    private var outputPipe: Pipe?
    private var launcherOutputBuffer = ""
    private var lastResult: URL?
    private var activeResultsFolder: URL?
    private var pendingProviderKeys = Set<String>()
    private var stopRequestedProviderKeys = Set<String>()
    private var activePrompt = ""
    private var activeContextFile: URL?
    private var recordedFolders = Set<String>()
    private var installerProcess: Process?
    private var installerOutputPipe: Pipe?
    /// In-memory copy of the Keychain vault; loaded once at launch.
    private var apiKeys: [String: String] = [:]

    private let settings = SettingsStore.shared

    var includedProviders: [ProviderID] {
        ProviderID.allCases.filter { providerSettings[$0]?.included ?? false }
    }

    var summaryProvider: ProviderID? {
        ProviderID(rawValue: summaryProviderRaw)
    }

    init() {
        var settings: [ProviderID: ProviderSettings] = [:]
        var statuses: [ProviderID: CLIStatus] = [:]
        var responseStates: [ProviderID: ResponseState] = [:]
        for provider in ProviderID.allCases {
            settings[provider] = SettingsStore.shared.loadSettings(for: provider)
            statuses[provider] = .checking
            responseStates[provider] = ResponseState()
        }
        providerSettings = settings
        cliStatus = statuses
        responses = responseStates

        let storedSummary = SettingsStore.shared.loadSummaryProvider()
        // Migrate the previous app's display-name values ("Codex", "No summary").
        let normalized = storedSummary.lowercased().replacingOccurrences(of: " ", with: "")
        if normalized == "nosummary" || normalized == "none" || ProviderID(rawValue: normalized) == nil {
            summaryProviderRaw = "none"
        } else {
            summaryProviderRaw = normalized
        }
        if let provider = summaryProvider {
            summaryModel = SettingsStore.shared.loadSummaryModel(for: provider)
            summaryEffort = SettingsStore.shared.loadSummaryEffort(for: provider)
        }

        // One Keychain access loads every saved key (migrating the previous
        // app's separate items on first launch).
        apiKeys = KeychainService.loadAllMigratingLegacy()
        for slot in [1, 2] {
            if let preset = SettingsStore.shared.loadPreset(slot: slot) {
                customPresets[slot] = preset
            }
        }
        if let saved = apiKeys["zai"], !saved.isEmpty {
            zaiKey = saved
            rememberZaiKey = true
        }
        if let saved = apiKeys["tavily"], !saved.isEmpty {
            tavilyKey = saved
            rememberTavilyKey = true
        }

        reloadSavedChats()
        refreshArtifacts()
        refreshCLIStatus()
    }

    // MARK: - Preferences

    func providerSettingChanged(_ provider: ProviderID) {
        if let current = providerSettings[provider] {
            settings.save(current, for: provider)
        }
    }

    /// Switches the summary provider, preserving the previous provider's
    /// model/effort choices exactly like the old app.
    func summaryProviderChanged(to rawValue: String) {
        if let previous = summaryProvider {
            settings.saveSummary(model: summaryModel, effort: summaryEffort, for: previous)
        }
        summaryProviderRaw = rawValue
        settings.saveSummaryProvider(rawValue == "none" ? "No summary" : rawValue)
        if let provider = summaryProvider {
            summaryModel = settings.loadSummaryModel(for: provider)
            summaryEffort = settings.loadSummaryEffort(for: provider)
        } else {
            summaryModel = "Default"
            summaryEffort = "Default"
        }
    }

    func summarySettingChanged() {
        if let provider = summaryProvider {
            settings.saveSummary(model: summaryModel, effort: summaryEffort, for: provider)
        }
    }

    func persistAllPreferences() {
        for provider in ProviderID.allCases {
            if let current = providerSettings[provider] {
                settings.save(current, for: provider)
            }
        }
        if let provider = summaryProvider {
            settings.saveSummary(model: summaryModel, effort: summaryEffort, for: provider)
        }
        settings.saveSummaryProvider(summaryProviderRaw == "none" ? "No summary" : summaryProviderRaw)
    }

    // MARK: - Keys

    func zaiRememberChanged() {
        if !rememberZaiKey {
            KeychainService.setKey("zai", value: "", in: &apiKeys)
        } else if !zaiKey.isEmpty {
            KeychainService.setKey("zai", value: zaiKey, in: &apiKeys)
        }
        refreshCLIStatus()
    }

    func tavilyRememberChanged() {
        if !rememberTavilyKey {
            KeychainService.setKey("tavily", value: "", in: &apiKeys)
        } else if !tavilyKey.isEmpty {
            KeychainService.setKey("tavily", value: tavilyKey, in: &apiKeys)
        }
    }

    // MARK: - Direct API keys (Meta / DeepSeek)

    func apiKeyName(for provider: ProviderID) -> String {
        provider == .meta ? "meta" : "deepseek"
    }

    func apiKey(for provider: ProviderID) -> String {
        apiKeys[apiKeyName(for: provider)] ?? ""
    }

    /// Saves or removes a direct API key. Returns an error description or nil.
    func updateAPIKey(_ key: String, for provider: ProviderID) -> String? {
        let status = KeychainService.setKey(apiKeyName(for: provider), value: key, in: &apiKeys)
        refreshCLIStatus()
        guard status == errSecSuccess else {
            return KeychainService.errorDescription(status)
        }
        return nil
    }

    // MARK: - Quick provider presets

    func setAllProvidersIncluded(_ included: Bool) {
        for provider in ProviderID.allCases {
            providerSettings[provider]?.included = included
        }
        persistAllPreferences()
        statusText = included ? "All providers included." : "All providers excluded."
    }

    /// Fast Mode: four quick models at high effort, with GPT-5.6 Luna
    /// synthesizing. Everything else is excluded.
    func applyFastMode() {
        for provider in ProviderID.allCases {
            providerSettings[provider]?.included = false
        }
        let preset: [(ProviderID, String, String)] = [
            (.meta, "muse-spark-1.2-contributor", "high"),
            (.google, "gemini-3.7-flash-high", "high"),
            (.deepseek, "deepseek-v4-flash", "high"),
            (.grok, "grok-4.6", "high"),
        ]
        for (provider, model, effort) in preset {
            providerSettings[provider] = ProviderSettings(included: true, model: model, effort: effort)
        }
        summaryProviderChanged(to: ProviderID.codex.rawValue)
        summaryModel = "gpt-5.6-luna"
        summaryEffort = "high"
        persistAllPreferences()
        statusText = "Fast Mode: Meta 1.2 Contributor, Gemini 3.7 Flash, DeepSeek V4 Flash, Grok 4.6 (all High) — GPT-5.6 Luna High synthesizes."
    }

    /// Saves the current provider and synthesis settings as a named preset.
    func saveCustomPreset(slot: Int, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var providers: [String: ProviderSettingSnapshot] = [:]
        for provider in ProviderID.allCases {
            let current = providerSettings[provider] ?? ProviderSettings(included: false)
            providers[provider.rawValue] = ProviderSettingSnapshot(
                included: current.included,
                model: current.model,
                effort: current.effort
            )
        }
        let preset = ProviderPreset(
            name: trimmed.isEmpty ? "Custom \(slot)" : trimmed,
            providers: providers,
            summaryProvider: summaryProviderRaw,
            summaryModel: summaryModel,
            summaryEffort: summaryEffort
        )
        customPresets[slot] = preset
        settings.savePreset(preset, slot: slot)
        statusText = "Saved preset “\(preset.name)”."
    }

    func applyCustomPreset(slot: Int) {
        guard let preset = customPresets[slot] else { return }
        for provider in ProviderID.allCases {
            if let snapshot = preset.providers[provider.rawValue] {
                providerSettings[provider] = ProviderSettings(
                    included: snapshot.included,
                    model: snapshot.model,
                    effort: snapshot.effort
                )
            }
        }
        let summaryTarget = preset.summaryProvider == "none" || ProviderID(rawValue: preset.summaryProvider) != nil
            ? preset.summaryProvider
            : "none"
        summaryProviderChanged(to: summaryTarget)
        summaryModel = preset.summaryModel
        summaryEffort = preset.summaryEffort
        persistAllPreferences()
        statusText = "Applied preset “\(preset.name)”."
    }

    func clearCustomPreset(slot: Int) {
        customPresets.removeValue(forKey: slot)
        settings.clearPreset(slot: slot)
    }

    // MARK: - Attachments

    func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.title = "Add prompt attachments"
        panel.message = "Selected files are shared with every provider in the next comparison."
        panel.prompt = "Add attachments"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.item]
        guard panel.runModal() == .OK else { return }

        let existing = Set(attachments.map(\.path))
        let additions = panel.urls
            .map(\.standardizedFileURL)
            .filter { !existing.contains($0.path) }
        guard !additions.isEmpty else {
            statusText = "Those attachments are already selected."
            return
        }
        attachments.append(contentsOf: additions)
        statusText = "\(additions.count) attachment\(additions.count == 1 ? "" : "s") added."
    }

    func removeAttachment(_ url: URL) {
        attachments.removeAll { $0.path == url.path }
    }

    func clearAttachments() {
        attachments.removeAll()
        statusText = "Attachments cleared."
    }

    // MARK: - Running a comparison

    func runComparison() {
        guard !isRunning else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusText = "Enter a prompt first."
            return
        }
        guard !includedProviders.isEmpty else {
            statusText = "Select at least one model to compare."
            return
        }
        conversationContext = ""
        followUp = ""
        canFollowUp = false
        startComparison(text, usingConversation: false)
    }

    func sendFollowUp() {
        guard !isRunning else { return }
        guard !conversationContext.isEmpty else {
            statusText = "Run an initial comparison before sending a follow-up."
            return
        }
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusText = "Enter a follow-up question first."
            return
        }
        startComparison(text, usingConversation: true)
    }

    func newConversation() {
        guard !isRunning else { return }
        conversationContext = ""
        activePrompt = ""
        attachments.removeAll()
        followUp = ""
        canFollowUp = false
        activeChatFolder = nil
        synthesisText = "No conversation selected. Run a comparison to begin."
        statusText = "Ready for a new comparison."
    }

    func resumeSavedChat(_ chat: SavedChat) {
        guard !isRunning else {
            statusText = "Finish or stop the current comparison before switching chats."
            return
        }
        let contextFile = chat.folder.appendingPathComponent("conversation-context.txt")
        guard let savedContext = try? String(contentsOf: contextFile, encoding: .utf8), !savedContext.isEmpty else {
            statusText = "That saved chat could not be read."
            return
        }
        conversationContext = savedContext
        activePrompt = ""
        attachments.removeAll()
        followUp = ""
        lastResult = chat.folder
        activeChatFolder = chat.folder
        loadLatestResponses()
        canFollowUp = true
        statusText = "Saved chat resumed. Enter a follow-up question below."
    }

    private func startComparison(_ text: String, usingConversation: Bool) {
        guard process == nil else { return }
        // Commit any in-progress combo-box edit (e.g. a custom model ID whose
        // field editor is still active) before the settings are read.
        NSApp.keyWindow?.makeFirstResponder(nil)
        activePrompt = text
        activeResultsFolder = nil
        pendingProviderKeys = Set(includedProviders.map(\.rawValue))
        stopRequestedProviderKeys.removeAll()
        // Persist editable field contents before this run. This also captures
        // a custom model ID typed without choosing a menu item.
        persistAllPreferences()

        var arguments = [LauncherService.runner.path]
        if !safeMode { arguments.append("--allow-tools") }
        if !onlineResearch { arguments.append("--no-web-search") }
        if usingConversation && !conversationContext.isEmpty {
            let contextURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("model-compare-context-\(UUID().uuidString).txt")
            do {
                try conversationContext.write(to: contextURL, atomically: true, encoding: .utf8)
                activeContextFile = contextURL
                arguments.append(contentsOf: ["--context-file", contextURL.path])
            } catch {
                statusText = "Could not prepare conversation context: \(error.localizedDescription)"
                return
            }
        }

        for provider in ProviderID.allCases {
            guard let providerSetting = providerSettings[provider] else { continue }
            let model = normalizedChoice(providerSetting.model)
            let effort = normalizedChoice(providerSetting.effort)
            if model != "default" { arguments.append(contentsOf: ["--\(provider.rawValue)-model", model]) }
            if provider.supportsPerRequestEffort, effort != "default" {
                arguments.append(contentsOf: ["--\(provider.rawValue)-effort", effort])
            }
        }
        for provider in includedProviders {
            arguments.append(contentsOf: ["--provider", provider.rawValue])
        }
        let selectedSummary = summaryProvider?.rawValue ?? "none"
        arguments.append(contentsOf: ["--summary-model", selectedSummary])
        if let summaryProvider {
            let model = summaryModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let effort = summaryEffort.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty, model.lowercased() != "default" { arguments.append(contentsOf: ["--summary-model-id", model.lowercased()]) }
            if !effort.isEmpty, effort.lowercased() != "default", summaryProvider.supportsPerRequestEffort {
                arguments.append(contentsOf: ["--summary-effort", effort.lowercased()])
            }
        }
        for attachment in attachments {
            arguments.append(contentsOf: ["--attachment", attachment.path])
        }
        arguments.append(text)

        var environment = ProcessInfo.processInfo.environment
        let key = zaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if rememberZaiKey && !key.isEmpty { KeychainService.setKey("zai", value: key, in: &apiKeys) }
        if !key.isEmpty {
            // The normal GLM route consumes ZAI_API_KEY. Qwen's optional
            // Z.AI Web Search MCP follows Z.AI's documented spelling. Both
            // values exist only in this child process; neither is written to
            // Qwen settings or result files.
            environment["ZAI_API_KEY"] = key
            environment["Z_AI_API_KEY"] = key
        }
        let searchKey = tavilyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if rememberTavilyKey && !searchKey.isEmpty { KeychainService.setKey("tavily", value: searchKey, in: &apiKeys) }
        if !searchKey.isEmpty {
            // Tavily's key is passed only to this launcher process. The runner
            // injects it into Qwen's configured MCP at execution time and uses
            // a short-lived, owner-only config when invoking GLM via Claude.
            environment["TAVILY_API_KEY"] = searchKey
        }
        let metaKey = apiKeys["meta"] ?? ""
        if !metaKey.isEmpty {
            // Direct API keys remain in Keychain until this point and are
            // passed only to the short-lived comparison launcher.
            environment["META_API_KEY"] = metaKey
        }
        let deepSeekKey = apiKeys["deepseek"] ?? ""
        if !deepSeekKey.isEmpty {
            environment["DEEPSEEK_API_KEY"] = deepSeekKey
        }
        environment["MODEL_COMPARE_RESULTS_DIR"] = LauncherService.results.path
        // Each provider CLI runs inside its own subfolder of this root, so
        // files the models create stay separated by model (see ask-all.zsh).
        environment["MODEL_COMPARE_WORKSPACE_ROOT"] = LauncherService.workDirectory.path

        let child = Process()
        let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/zsh")
        child.arguments = arguments
        child.currentDirectoryURL = LauncherService.workDirectory
        child.environment = environment
        child.standardOutput = pipe
        child.standardError = pipe
        outputPipe = pipe
        launcherOutputBuffer = ""
        process = child
        isRunning = true
        runStartedAt = Date()

        for provider in ProviderID.allCases {
            responses[provider] = ResponseState(status: .waiting, text: "Waiting…")
        }
        synthesisText = selectedSummary == "none"
            ? "No summary model selected."
            : "Waiting for the individual responses…"
        statusText = usingConversation
            ? "Sending follow-up to all models…"
            : (selectedSummary == "none"
                ? "Running available models in parallel…"
                : "Running models, then synthesizing with \(summaryProvider?.displayName ?? "the selected model")…")
        appendLog("\nStarting comparison…\n")

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.received(text) }
        }
        child.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.flushPendingLauncherOutput()
                self.process = nil
                self.outputPipe = nil
                self.pendingProviderKeys.removeAll()
                self.stopRequestedProviderKeys.removeAll()
                self.isRunning = false
                self.statusText = finished.terminationStatus == 0
                    ? "Finished. Responses are shown above."
                    : "Launcher exited with status \(finished.terminationStatus)."
                self.loadLatestResponses(recordConversation: true)
                self.refreshArtifacts()
                if let activeContextFile = self.activeContextFile {
                    try? FileManager.default.removeItem(at: activeContextFile)
                    self.activeContextFile = nil
                }
            }
        }
        do {
            try child.run()
        } catch {
            process = nil
            pendingProviderKeys.removeAll()
            stopRequestedProviderKeys.removeAll()
            isRunning = false
            statusText = "Could not start launcher: \(error.localizedDescription)"
            if let activeContextFile { try? FileManager.default.removeItem(at: activeContextFile) }
            activeContextFile = nil
        }
    }

    func stopComparison() {
        process?.terminate()
        statusText = "Stopping…"
    }

    func canStopWaiting(for provider: ProviderID) -> Bool {
        isRunning
            && activeResultsFolder != nil
            && pendingProviderKeys.contains(provider.rawValue)
            && !stopRequestedProviderKeys.contains(provider.rawValue)
    }

    func stopWaiting(for provider: ProviderID) {
        let key = provider.rawValue
        guard process != nil, pendingProviderKeys.contains(key), !stopRequestedProviderKeys.contains(key) else { return }
        guard let activeResultsFolder else {
            statusText = "Preparing the comparison; try stopping \(provider.displayName) again in a moment."
            return
        }

        let marker = activeResultsFolder.appendingPathComponent(".stop-waiting-\(key)")
        do {
            try Data("Stopped manually by the user.\n".utf8).write(to: marker, options: .atomic)
            stopRequestedProviderKeys.insert(key)
            responses[provider] = ResponseState(
                status: .stopRequested,
                text: "Stopping \(provider.displayName)… its response will be excluded so synthesis can continue with the completed models."
            )
            statusText = "Stop requested for \(provider.displayName). Synthesis will continue without its response."
            appendLog("Stop waiting requested for \(provider.displayName).\n")
        } catch {
            statusText = "Could not stop \(provider.displayName): \(error.localizedDescription)"
        }
    }

    // MARK: - Launcher output parsing

    private func received(_ text: String) {
        launcherOutputBuffer += text
        let parts = launcherOutputBuffer.components(separatedBy: "\n")
        guard parts.count > 1 else { return }
        launcherOutputBuffer = parts.last ?? ""
        var visibleLines: [String] = []
        for line in parts.dropLast() {
            handleLauncherLine(line, visibleLines: &visibleLines)
        }
        if !visibleLines.isEmpty {
            appendLog(visibleLines.joined(separator: "\n") + "\n")
        }
    }

    private func flushPendingLauncherOutput() {
        guard !launcherOutputBuffer.isEmpty else { return }
        var visibleLines: [String] = []
        handleLauncherLine(launcherOutputBuffer, visibleLines: &visibleLines)
        launcherOutputBuffer = ""
        if !visibleLines.isEmpty {
            appendLog(visibleLines.joined(separator: "\n") + "\n")
        }
    }

    private func handleLauncherLine(_ line: String, visibleLines: inout [String]) {
        guard !line.isEmpty else { return }
        if line.hasPrefix("RESULTS_DIR:") {
            let path = line.dropFirst("RESULTS_DIR:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                activeResultsFolder = URL(fileURLWithPath: String(path))
                lastResult = activeResultsFolder
            }
            return
        }
        if line.hasPrefix("RESPONSE_READY:") {
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 {
                let key = String(parts[1]).lowercased()
                let file = URL(fileURLWithPath: String(parts[2]))
                showCompletedResponse(key: key, from: file)
                return
            }
        }
        if line.hasPrefix("Done. Open:") {
            let path = line.dropFirst("Done. Open:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { lastResult = URL(fileURLWithPath: String(path)) }
        }
        visibleLines.append(line)
    }

    private func showCompletedResponse(key: String, from file: URL) {
        lastResult = file.deletingLastPathComponent()
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? "No response saved."
        let elapsed = runStartedAt.map { Date().timeIntervalSince($0) }
        if key == "summary" {
            synthesisText = text
        } else if let provider = ProviderID(rawValue: key) {
            responses[provider] = ResponseState(status: .ready, text: text, elapsedSeconds: elapsed)
            pendingProviderKeys.remove(key)
            stopRequestedProviderKeys.remove(key)
        } else {
            return
        }
        let label = key == "summary" ? "Synthesis" : (ProviderID(rawValue: key)?.displayName ?? key.capitalized)
        statusText = "\(label) response ready."
        appendLog("\(label) response ready and shown above.\n")
    }

    // MARK: - CLI status, installers, sign-in

    func refreshCLIStatus() {
        for provider in ProviderID.allCases {
            if provider.isDirectAPI {
                let hasKey = !apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                cliStatus[provider] = hasKey ? .apiKeySaved : .needsAPIKey
                continue
            }
            let cli = LauncherService.executableURL(for: provider)
            if provider == .glm {
                if cli == nil {
                    cliStatus[provider] = .needsClaudeCode
                } else if zaiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cliStatus[provider] = .needsZAIKey
                } else {
                    cliStatus[provider] = .readyViaClaude
                }
                continue
            }
            cliStatus[provider] = cli != nil ? .installed : .notInstalled
        }
    }

    /// Runs the provider's official installer, streaming output to the log.
    func installCLI(_ provider: ProviderID) {
        guard installerProcess == nil else {
            statusText = "An installer is already running."
            return
        }
        guard let command = provider.installerCommand else { return }

        let child = Process()
        let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/zsh")
        child.arguments = ["-o", "pipefail", "-lc", command]
        child.currentDirectoryURL = LauncherService.workDirectory
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe
        child.standardError = pipe
        installerProcess = child
        installerOutputPipe = pipe
        installerRunningProvider = provider
        appendLog("\nStarting \(provider.displayName) CLI installer…\n")
        statusText = "Installing \(provider.displayName) CLI…"

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.appendLog(text) }
        }
        child.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.installerProcess = nil
                self.installerOutputPipe = nil
                self.installerRunningProvider = nil
                self.statusText = finished.terminationStatus == 0
                    ? "\(provider.displayName) CLI installed. Click Sign in to connect your account."
                    : "\(provider.displayName) installer exited with status \(finished.terminationStatus). See the activity log."
                self.appendLog("\(provider.displayName) installer finished (status \(finished.terminationStatus)).\n")
                self.refreshCLIStatus()
            }
        }
        do {
            try child.run()
        } catch {
            installerProcess = nil
            installerOutputPipe = nil
            installerRunningProvider = nil
            statusText = "Could not start the \(provider.displayName) installer: \(error.localizedDescription)"
        }
    }

    /// Opens Terminal for the provider's interactive sign-in flow.
    func signInCLI(_ provider: ProviderID) {
        guard let arguments = provider.signInArguments else { return }
        guard let executable = LauncherService.executableURL(for: provider) else {
            statusText = "Install that CLI before signing in."
            return
        }
        let command = "exec \(LauncherService.shellQuoted(executable.path)) \(arguments)"
        if let error = LauncherService.openTerminalSignIn(command: command) {
            statusText = "Could not open Terminal for \(provider.displayName) sign-in: \(error)"
        } else {
            statusText = "A Terminal window opened for \(provider.displayName) sign-in. Complete its browser flow, then refresh status."
        }
    }

    /// Opens Terminal for Qwen Code's interactive ModelStudio setup.
    func openQwenSetup() {
        guard let executable = LauncherService.executableURL(for: .qwen) else {
            statusText = "Install Qwen Code before signing in."
            return
        }
        let command = "exec \(LauncherService.shellQuoted(executable.path)) --auth-type openai"
        if let error = LauncherService.openTerminalSignIn(command: command) {
            statusText = "Could not open Terminal for Qwen setup: \(error)"
        } else {
            statusText = "A Terminal window opened for Qwen Code’s ModelStudio setup. Choose Token Plan or Coding Plan in /auth, then return here."
        }
    }

    // MARK: - Results, saved chats, conversation recording

    func latestResultsFolder() -> URL? {
        if let lastResult {
            return lastResult.lastPathComponent == "README.md"
                ? lastResult.deletingLastPathComponent()
                : lastResult
        }
        return try? FileManager.default.contentsOfDirectory(at: LauncherService.results, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    private func loadLatestResponses(recordConversation: Bool = false) {
        guard let folder = latestResultsFolder() else { return }
        for provider in ProviderID.allCases {
            let file = folder.appendingPathComponent(provider.resultFileName)
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? "No response saved."
            let elapsed = responses[provider]?.elapsedSeconds
            responses[provider] = ResponseState(status: .ready, text: text, elapsedSeconds: elapsed)
        }
        let summaryFile = folder.appendingPathComponent("summary.txt")
        let summary = (try? String(contentsOf: summaryFile, encoding: .utf8)) ?? "No synthesis was selected or produced for this run."
        synthesisText = summary
        if recordConversation { recordConversationTurn(in: folder) }
    }

    private func recordConversationTurn(in folder: URL) {
        guard !activePrompt.isEmpty, !recordedFolders.contains(folder.path) else { return }
        recordedFolders.insert(folder.path)
        var turn = "USER REQUEST:\n\(activePrompt)\n\nMODEL RESPONSES:\n"
        for provider in ProviderID.allCases {
            let file = folder.appendingPathComponent(provider.resultFileName)
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? "No response was produced."
            turn += "\n===== \(provider.displayName.uppercased()) =====\n\(text)\n"
        }
        let summaryFile = folder.appendingPathComponent("summary.txt")
        let summary = (try? String(contentsOf: summaryFile, encoding: .utf8)) ?? "No synthesis was produced."
        turn += "\n===== SYNTHESIS =====\n\(summary)\n"
        if !conversationContext.isEmpty { conversationContext += "\n\n" }
        conversationContext += turn
        let contextFile = folder.appendingPathComponent("conversation-context.txt")
        try? conversationContext.write(to: contextFile, atomically: true, encoding: .utf8)
        activeChatFolder = folder
        reloadSavedChats()
        canFollowUp = true
    }

    func reloadSavedChats() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: LauncherService.results, includingPropertiesForKeys: nil))?
            .filter { $0.hasDirectoryPath && FileManager.default.fileExists(atPath: $0.appendingPathComponent("conversation-context.txt").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        savedChats = folders.prefix(30).map { folder in
            SavedChat(folder: folder, title: savedChatTitle(for: folder))
        }
    }

    private func savedChatTitle(for folder: URL) -> String {
        let file = folder.appendingPathComponent("conversation-context.txt")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return folder.lastPathComponent }
        let data = handle.readData(ofLength: 500)
        handle.closeFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let request = text.components(separatedBy: "\n")
            .drop { $0 != "USER REQUEST:" }
            .dropFirst()
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Saved comparison"
        let preview = String(request.prefix(62))
        return "\(folder.lastPathComponent) — \(preview)"
    }

    func deleteSavedChat(_ chat: SavedChat) {
        try? FileManager.default.trashItem(at: chat.folder, resultingItemURL: nil)
        if activeChatFolder == chat.folder { activeChatFolder = nil }
        reloadSavedChats()
        statusText = "Saved chat moved to Trash."
    }

    func openLatest() {
        guard let folder = latestResultsFolder() else {
            statusText = "No results yet. Run a comparison first."
            return
        }
        NSWorkspace.shared.open(folder.appendingPathComponent("README.md"))
    }

    /// Opens the export sheet with the sections available in the latest folder.
    func beginPDFExport() {
        guard let folder = latestResultsFolder() else {
            statusText = "No results yet. Run a comparison before exporting a PDF."
            return
        }
        let available = PDFReportService.availableProviders(in: folder)
        pdfExport = PDFExportState(
            folder: folder,
            hasSynthesis: PDFReportService.hasSynthesis(in: folder),
            includeSynthesis: true,
            availableProviders: available,
            includedProviders: Set(available)
        )
    }

    func confirmPDFExport() {
        guard let export = pdfExport else { return }
        let isActive = export.folder.standardizedFileURL == lastResult?.standardizedFileURL
        let providers = ProviderID.allCases.filter { export.includedProviders.contains($0) }
        statusText = PDFReportService.export(
            folder: export.folder,
            includeSynthesis: export.includeSynthesis,
            providers: providers,
            activePrompt: activePrompt,
            isActiveFolder: isActive
        )
        pdfExport = nil
    }

    // MARK: - Artifacts

    /// Files created in the shared workspace folder. With Safe mode off, the
    /// coding CLIs can write reports, PDFs, and other files here during a run.
    /// Each provider works inside its own subfolder; files at the workspace
    /// root (including artifacts from earlier versions) are shown without a
    /// provider label.
    func refreshArtifacts() {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        let root = LauncherService.workDirectory

        func isRegularFile(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        func modificationDate(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        func providerName(for folder: URL) -> String {
            let key = folder.lastPathComponent.lowercased()
            if key == "summary" { return "Synthesis" }
            return ProviderID(rawValue: key)?.displayName ?? folder.lastPathComponent
        }

        var items: [ArtifactItem] = []
        let topLevel = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in topLevel {
            if isRegularFile(url) {
                items.append(ArtifactItem(url: url, provider: nil))
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let contents = (try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for file in contents where isRegularFile(file) {
                    items.append(ArtifactItem(url: file, provider: providerName(for: url)))
                }
            }
        }
        artifacts = items.sorted { modificationDate($0.url) > modificationDate($1.url) }
    }

    func openArtifact(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func revealArtifact(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Reader

    func openReader(for provider: ProviderID) {
        let body = responses[provider]?.text ?? ""
        reader = ReaderContent(title: "\(provider.displayName) · Model Compare", body: body)
    }

    func openSummaryReader() {
        reader = ReaderContent(title: "Synthesis · Model Compare", body: synthesisText)
    }

    // MARK: - Updates

    /// Silent launch-time check: only surfaces the banner when a newer
    /// release exists; failures are ignored so startup is never noisy.
    func checkForUpdatesOnLaunch() {
        Task {
            if case .success(.some(let info)) = await UpdateService.checkForUpdate() {
                availableUpdate = info
            }
        }
    }

    /// Menu-driven check: always reports the outcome, including up-to-date
    /// and the reasons a check might not be possible.
    func checkForUpdatesManually() {
        Task {
            switch await UpdateService.checkForUpdate() {
            case .success(.some(let info)):
                availableUpdate = info
            case .success(.none):
                updateAlert = UpdateAlert(
                    title: "You're up to date",
                    message: "Model Compare Studio \(UpdateService.currentVersion) is the latest release."
                )
            case .failure(.unreachable):
                updateAlert = UpdateAlert(
                    title: "Update check failed",
                    message: "Couldn't reach GitHub. Check your internet connection and try again."
                )
            case .failure(.noReleaseFound):
                updateAlert = UpdateAlert(
                    title: "Update check unavailable",
                    message: "GitHub does not serve release information for private repositories. Make the repository public to enable update checks."
                )
            }
        }
    }

    func openUpdateRelease() {
        if let url = availableUpdate?.releaseURL { NSWorkspace.shared.open(url) }
    }

    func dismissUpdateBanner() {
        availableUpdate = nil
    }

    // MARK: - Helpers

    private func appendLog(_ text: String) {
        activityLog += text
    }

    private func normalizedChoice(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed.lowercased()
    }
}
