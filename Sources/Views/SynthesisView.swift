import AppKit
import SwiftUI

/// Synthesis pane plus the follow-up-to-all-models composer.
struct SynthesisView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var followUpFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Synthesis", systemImage: "sparkles")
                    .font(.headline)
                Text("agreement · disagreement · overall answer")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.synthesisText, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy synthesis")
                Button { state.openSummaryReader() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open in focused reader")
            }

            MarkdownTextView(text: state.synthesisText, baseSize: 13.5)
                .frame(minHeight: 80, maxHeight: 150)

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $state.followUp)
                        .font(.system(size: 13))
                        .focused($followUpFocused)
                        .scrollContentBackground(.hidden)
                        .padding(5)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .disabled(!state.canFollowUp || state.isRunning)
                    if state.followUp.isEmpty {
                        Text(state.canFollowUp ? "Follow-up to all models…" : "Run a comparison to enable follow-ups")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 10)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 52)

                VStack(spacing: 6) {
                    Button { state.sendFollowUp(); state.followUp = "" } label: {
                        Label("Send to all", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canFollowUp || state.isRunning || state.followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Include all previous prompts, responses, and the synthesis in the next request. ⌘Return")
                    Button("New conversation") { state.newConversation() }
                        .controlSize(.small)
                        .disabled(state.isRunning)
                }
            }
        }
        .card()
    }
}

/// Collapsible launcher/installer output.
struct ActivityLogView: View {
    @EnvironmentObject var state: AppState
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Activity Log")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    if !state.activityLog.isEmpty {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(state.activityLog, forType: .string)
                        }
                        .controlSize(.mini)
                        .onTapGesture {} // keep the disclosure from toggling
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                LogTextView(text: state.activityLog)
                    .frame(minHeight: 90, maxHeight: 160)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .card()
    }
}
