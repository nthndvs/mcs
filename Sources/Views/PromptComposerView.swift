import SwiftUI

/// The question area: prompt editor, attachments, and the primary run action.
struct PromptComposerView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var promptFocused: Bool
    @Binding var editorHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Ask the room", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                if !state.attachments.isEmpty {
                    Button("Clear attachments") { state.clearAttachments() }
                        .controlSize(.small)
                }
                Button { state.chooseAttachments() } label: {
                    Label("Add images or files…", systemImage: "paperclip")
                }
                .controlSize(.small)
                .help("Add text files, common office documents, or images to this prompt. Selected files are shared with every provider.")
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $state.prompt)
                    .font(.system(size: 14))
                    .focused($promptFocused)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if state.prompt.isEmpty {
                    Text("Ask every selected model the same question…")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 11)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: editorHeight)

            if !state.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.attachments, id: \.path) { url in
                            AttachmentChip(url: url) { state.removeAttachment(url) }
                        }
                    }
                }
                .help(state.attachments.map(\.path).joined(separator: "\n"))
            }

            HStack {
                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if state.isRunning {
                    RunElapsedView(since: state.runStartedAt)
                    Button(role: .destructive) { state.stopComparison() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.large)
                } else {
                    Button { state.runComparison() } label: {
                        Label("Run Comparison", systemImage: "play.fill")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .card()
    }
}

struct AttachmentChip: View {
    let url: URL
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc")
                .font(.caption2)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
        .help(url.path)
    }
}

/// Live elapsed-time readout while a comparison is running.
struct RunElapsedView: View {
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let since {
                let seconds = Int(Date().timeIntervalSince(since))
                Text("Running · \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
