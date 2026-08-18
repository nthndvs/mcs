import SwiftUI

/// Left column: provider roster, synthesis settings, keys/options, saved chats.
struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                providersSection
                synthesisSection
                keysSection
                artifactsSection
                savedChatsSection
            }
            .padding(14)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Providers

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SidebarHeader("Providers", systemImage: "square.grid.2x2")
            HStack(spacing: 6) {
                Text("Quick select")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("All") { state.setAllProvidersIncluded(true) }
                Button("None") { state.setAllProvidersIncluded(false) }
                Button { state.applyFastMode() } label: {
                    Label("Fast Mode", systemImage: "bolt.fill")
                }
                .help("Meta 1.2 Contributor, Gemini 3.7 Flash, DeepSeek V4 Flash, and Grok 4.6 — all at High effort — with GPT-5.6 Luna High synthesizing.")
                Spacer()
            }
            .controlSize(.small)
            HStack(spacing: 6) {
                Text("Custom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach([1, 2], id: \.self) { slot in
                    CustomPresetButton(slot: slot)
                }
                Spacer()
            }
            .controlSize(.small)
            Text("Include · Model · Effort · Connection. Model names stay editable for account-specific releases.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            VStack(spacing: 8) {
                ForEach(ProviderID.allCases) { provider in
                    ProviderRowView(provider: provider)
                }
            }
        }
    }

    // MARK: - Synthesis

    private var synthesisSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SidebarHeader("Synthesis", systemImage: "sparkles.rectangle.stack")
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Summary by") {
                    Picker("Summary by", selection: Binding(
                        get: { state.summaryProviderRaw },
                        set: { state.summaryProviderChanged(to: $0) }
                    )) {
                        Text("No summary").tag("none")
                        ForEach(ProviderID.allCases) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                    .labelsHidden()
                    .help("Choose which model synthesizes agreement, disagreement, and an overall answer after the comparison.")
                }
                if state.summaryProvider != nil {
                    LabeledContent("Model") {
                        EditableComboBox(
                            items: state.summaryProvider?.modelOptions ?? ["Default"],
                            text: $state.summaryModel,
                            placeholder: "Model",
                            onChange: { _ in state.summarySettingChanged() }
                        )
                        .frame(width: 170)
                    }
                    LabeledContent("Effort") {
                        EditableComboBox(
                            items: state.summaryProvider?.effortOptions ?? ["Default"],
                            text: $state.summaryEffort,
                            placeholder: "Effort",
                            onChange: { _ in state.summarySettingChanged() }
                        )
                        .frame(width: 100)
                        .disabled(!(state.summaryProvider?.supportsPerRequestEffort ?? false))
                        .help(state.summaryProvider?.effortDisabledNote ?? "Per-request reasoning effort for the synthesis.")
                    }
                }
            }
            .card()
        }
    }

    // MARK: - Keys & options

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SidebarHeader("Keys & Options", systemImage: "key")
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Z.AI key").font(.caption).foregroundStyle(.secondary)
                    SecureField("Optional Z.AI key", text: $state.zaiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: state.zaiKey) { _, _ in state.refreshCLIStatus() }
                    Toggle("Remember in macOS Keychain", isOn: $state.rememberZaiKey)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .onChange(of: state.rememberZaiKey) { _, _ in state.zaiRememberChanged() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tavily search key").font(.caption).foregroundStyle(.secondary)
                    SecureField("Optional Tavily key", text: $state.tavilyKey)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Remember in macOS Keychain", isOn: $state.rememberTavilyKey)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .onChange(of: state.rememberTavilyKey) { _, _ in state.tavilyRememberChanged() }
                }
                Divider()
                Toggle("Safe mode: no file changes or commands", isOn: $state.safeMode)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Toggle("Use online research when supported", isOn: $state.onlineResearch)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .help("Each provider researches with its own tools: CLI providers use their built-in search, and Meta and DeepSeek use their APIs' server-side web search (Meta bills search grounding per query, about $2.50 per 1,000). A Tavily key gives Qwen and GLM an independent research source and backs the fallback brief if a native search endpoint is unavailable. Safe mode still prevents local file and command tools.")
            }
            .card()
        }
    }

    // MARK: - Saved chats

    private var artifactsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SidebarHeader("Artifacts", systemImage: "shippingbox")
                Spacer()
                Button { state.refreshArtifacts() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh the artifact list.")
            }
            if state.artifacts.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No artifacts yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Turn Safe mode off, then ask the models to create something — for example “save your analysis as report.pdf”. Files the CLIs write appear here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .card()
            } else {
                VStack(spacing: 6) {
                    ForEach(state.artifacts.prefix(12)) { item in
                        ArtifactRowView(item: item)
                            .onTapGesture { state.openArtifact(item.url) }
                            .contextMenu {
                                Button("Open") { state.openArtifact(item.url) }
                                Button("Reveal in Finder") { state.revealArtifact(item.url) }
                            }
                    }
                }
            }
        }
    }

    // MARK: - Saved chats

    private var savedChatsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SidebarHeader("Saved Chats", systemImage: "clock.arrow.circlepath")
                Spacer()
                Button("New") { state.newConversation() }
                    .controlSize(.small)
                    .disabled(state.isRunning)
                    .help("Start a clean conversation context.")
            }
            if state.savedChats.isEmpty {
                Text("No saved chats yet. Completed comparisons appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .card()
            } else {
                VStack(spacing: 6) {
                    ForEach(state.savedChats) { chat in
                        SavedChatRowView(chat: chat, isActive: state.activeChatFolder == chat.folder)
                            .onTapGesture { state.resumeSavedChat(chat) }
                            .contextMenu {
                                Button("Resume") { state.resumeSavedChat(chat) }
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([chat.folder])
                                }
                                Divider()
                                Button("Move to Trash", role: .destructive) { state.deleteSavedChat(chat) }
                            }
                    }
                }
            }
        }
    }
}

struct SidebarHeader: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

/// One provider's include toggle, model/effort selectors, status, and actions.
struct ProviderRowView: View {
    let provider: ProviderID
    @EnvironmentObject var state: AppState
    @State private var showingInstallConfirm = false
    @State private var showingZAISetup = false
    @State private var showingQwenSetup = false
    @State private var showingKeySetup = false

    private var settings: ProviderSettings {
        state.providerSettings[provider] ?? ProviderSettings(included: false)
    }

    private var status: CLIStatus {
        state.cliStatus[provider] ?? .checking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Toggle(isOn: Binding(
                    get: { settings.included },
                    set: { newValue in
                        state.providerSettings[provider]?.included = newValue
                        state.providerSettingChanged(provider)
                    }
                )) {
                    Text(provider.displayName).font(.callout.weight(.semibold))
                }
                .toggleStyle(.checkbox)
                .help("Include \(provider.displayName) in this comparison.")
                Spacer()
                StatusBadge(status: status)
            }

            HStack(spacing: 6) {
                EditableComboBox(
                    items: provider.modelOptions,
                    text: Binding(
                        get: { settings.model },
                        set: { newValue in
                            state.providerSettings[provider]?.model = newValue
                            state.providerSettingChanged(provider)
                        }
                    ),
                    placeholder: "Model",
                    onChange: { _ in state.providerSettingChanged(provider) }
                )
                .help(provider.modelFieldNote)
                EditableComboBox(
                    items: provider.effortOptions,
                    text: Binding(
                        get: { settings.effort },
                        set: { newValue in
                            state.providerSettings[provider]?.effort = newValue
                            state.providerSettingChanged(provider)
                        }
                    ),
                    placeholder: "Effort",
                    onChange: { _ in state.providerSettingChanged(provider) }
                )
                .frame(width: 84)
                .disabled(!provider.supportsPerRequestEffort)
                .help(provider.effortDisabledNote ?? "Per-request reasoning effort, when the provider supports it.")
            }

            actionRow
        }
        .card(padding: 10)
        .alert("Install \(provider.displayName) CLI?", isPresented: $showingInstallConfirm) {
            Button("Install") { state.installCLI(provider) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This downloads and runs the provider's official installer. It installs into your user account, does not receive any API keys from Model Compare, and may require a separate browser sign-in afterward.\n\n\(provider.installerCommand ?? "")")
        }
        .alert("Set up GLM with Z.AI", isPresented: $showingZAISetup) {
            Button("Open Z.AI API Keys") {
                if let url = URL(string: "https://z.ai/manage-apikey") { NSWorkspace.shared.open(url) }
            }
            Button("Close", role: .cancel) {}
        } message: {
            Text("GLM uses the already-installed Claude Code CLI; it does not need a separate CLI.\n\n1. Sign in to Z.AI and subscribe to a GLM Coding Plan.\n2. In Z.AI's API Keys page, create a new key.\n3. Paste it into the Z.AI key field in Keys & Options.\n4. Tick ‘Remember in macOS Keychain’ if you want this Mac to retain it securely.\n\nThe app supplies the key only to its temporary GLM request; it does not write the key into a project file or shell profile.")
        }
        .alert("Set up Qwen Code", isPresented: $showingQwenSetup) {
            Button("Open Qwen setup") { state.openQwenSetup() }
            Button("View setup guide") {
                if let url = URL(string: "https://qwenlm.github.io/qwen-code-docs/en/users/configuration/auth/") { NSWorkspace.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Qwen Code stores its own authentication; Model Compare never receives or saves your ModelStudio key.\n\n1. Click ‘Open Qwen setup’. In the Terminal window, run /auth if it is not shown automatically.\n2. Choose Alibaba ModelStudio → Token Plan (or Coding Plan if that is your subscription).\n3. Select your region and enter the API key for that exact plan.\n4. Use /model to inspect your account's model choices and /effort to set Qwen's persisted reasoning level.\n\nOnline research: Tavily is configured as Qwen's independent web-search MCP. Keep its key in Model Compare's Keychain-backed Tavily field.")
        }
        .sheet(isPresented: $showingKeySetup) {
            APIKeySetupSheet(provider: provider)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if provider == .glm {
            HStack(spacing: 6) {
                Button("Z.AI setup…") { showingZAISetup = true }
                    .controlSize(.small)
                Spacer()
            }
        } else if provider.isDirectAPI {
            HStack(spacing: 6) {
                Button(status == .apiKeySaved ? "Key setup…" : "Set key…") { showingKeySetup = true }
                    .controlSize(.small)
                Spacer()
            }
        } else {
            HStack(spacing: 6) {
                if provider.installerCommand != nil {
                    Button(status == .installed ? "Update" : "Install") { showingInstallConfirm = true }
                        .controlSize(.small)
                        .disabled(state.installerRunningProvider != nil)
                }
                if provider == .qwen {
                    Button("Sign in") { showingQwenSetup = true }
                        .controlSize(.small)
                        .disabled(status != .installed || state.installerRunningProvider != nil)
                } else if provider.signInArguments != nil {
                    Button("Sign in") { state.signInCLI(provider) }
                        .controlSize(.small)
                        .disabled(status != .installed || state.installerRunningProvider != nil)
                }
                Spacer()
            }
        }
    }
}

/// A user-defined quick-select grouping. Click applies it; right-click saves
/// the current settings into the slot, renames, or deletes it.
struct CustomPresetButton: View {
    let slot: Int
    @EnvironmentObject var state: AppState
    @State private var showingNameSheet = false
    @State private var showingActions = false
    @State private var name = ""

    private var preset: ProviderPreset? { state.customPresets[slot] }

    var body: some View {
        Button {
            if preset != nil {
                // Never apply silently: a plain click offers explicit choices
                // so tweaking settings and then clicking a preset can't wipe
                // the current selections by surprise.
                showingActions = true
            } else {
                name = ""
                showingNameSheet = true
            }
        } label: {
            Text(preset?.name ?? "Custom \(slot)")
                .lineLimit(1)
        }
        .opacity(preset == nil ? 0.7 : 1)
        .help(preset == nil
              ? "No preset saved here yet. Click to save the current provider and synthesis settings."
              : "Apply, replace, or delete the “\(preset!.name)” preset.")
        .confirmationDialog(
            "Preset “\(preset?.name ?? "Custom \(slot)")”",
            isPresented: $showingActions,
            titleVisibility: .visible
        ) {
            Button("Apply") { state.applyCustomPreset(slot: slot) }
            Button("Replace with current settings…") {
                name = preset?.name ?? ""
                showingNameSheet = true
            }
            Button("Delete preset", role: .destructive) { state.clearCustomPreset(slot: slot) }
            Button("Cancel", role: .cancel) {}
        }
        .contextMenu {
            Button("Apply") { state.applyCustomPreset(slot: slot) }
            Button("Replace with current settings…") {
                name = preset?.name ?? ""
                showingNameSheet = true
            }
            if preset != nil {
                Divider()
                Button("Delete preset", role: .destructive) { state.clearCustomPreset(slot: slot) }
            }
        }
        .sheet(isPresented: $showingNameSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text(preset == nil ? "Save current settings as a preset" : "Name this preset")
                    .font(.headline)
                Text("Captures every provider's Include, model, and effort choices plus the synthesis settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Preset name", text: $name)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { showingNameSheet = false }
                    Button("Save") {
                        state.saveCustomPreset(slot: slot, name: name)
                        showingNameSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 320)
        }
    }
}

/// A file created by a model in the shared workspace.
struct ArtifactRowView: View {
    let item: ArtifactItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let provider = item.provider {
                    Text(provider)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "arrow.up.forward.square")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .help(item.url.path)
    }

    private var iconName: String {
        switch item.url.pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
        case "md", "txt": return "doc.text"
        case "csv", "tsv": return "tablecells"
        case "json": return "curlybraces"
        case "html": return "globe"
        case "py", "js", "ts", "swift", "zsh", "sh": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

/// A resumable saved conversation entry.
struct SavedChatRowView: View {
    let chat: SavedChat
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(chat.title)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? .primary : .secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}

/// Secure-key entry for the direct Meta and DeepSeek API providers.
struct APIKeySetupSheet: View {
    let provider: ProviderID
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var saveError: String?

    private var portal: URL? {
        URL(string: provider == .meta ? "https://dev.meta.ai/" : "https://platform.deepseek.com/api_keys")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(provider == .meta ? "Connect Meta Model API" : "Connect DeepSeek API")
                .font(.title3.weight(.semibold))
            Text(provider == .meta
                 ? "Create a Meta Model API key at dev.meta.ai, then paste it below. This enables direct, pay-as-you-go Muse Spark requests; it is separate from a Meta AI app subscription. The key is saved only in this Mac's Keychain and is passed only to a comparison run. Save with an empty field to remove an existing key."
                 : "Create a DeepSeek API key in the DeepSeek platform, then paste it below. This enables direct, pay-as-you-go DeepSeek V4 requests; it is separate from the DeepSeek chat site. The key is saved only in this Mac's Keychain and is passed only to a comparison run. Save with an empty field to remove an existing key.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(provider == .meta ? "Meta Model API key" : "DeepSeek API key", text: $key)
                .textFieldStyle(.roundedBorder)
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if let portal {
                    Button("Open provider portal") { NSWorkspace.shared.open(portal) }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save key") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { key = state.apiKey(for: provider) }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = state.updateAPIKey(trimmed, for: provider) {
            saveError = "Could not save the key: \(error)"
            return
        }
        state.statusText = trimmed.isEmpty
            ? "\(provider.displayName) API key removed from macOS Keychain."
            : "\(provider.displayName) API key saved in macOS Keychain."
        dismiss()
    }
}
