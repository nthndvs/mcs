import AppKit
import SwiftUI

/// Side-by-side response cards in an adaptive grid; each card scrolls
/// internally so a long answer never distorts the layout. Only providers
/// selected for the comparison appear here.
struct ResponseGridView: View {
    @EnvironmentObject var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 330), spacing: 12)]

    private var visibleProviders: [ProviderID] {
        ProviderID.allCases.filter { state.providerSettings[$0]?.included ?? false }
    }

    var body: some View {
        Group {
            if visibleProviders.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No providers selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Tick providers in the sidebar, or use Quick select.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(visibleProviders) { provider in
                            ResponseCardView(provider: provider)
                                .frame(height: 250)
                        }
                    }
                    .padding(1) // room for focus rings/shadows
                }
            }
        }
    }
}

struct ResponseCardView: View {
    let provider: ProviderID
    @EnvironmentObject var state: AppState

    private var response: ResponseState {
        state.responses[provider] ?? ResponseState()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(provider.displayName)
                    .font(.callout.weight(.semibold))
                statusView
                Spacer()
                if response.status == .ready {
                    Text("\(response.wordCount) words")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    iconButton("doc.on.doc", help: "Copy response") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(response.text, forType: .string)
                    }
                }
                if state.canStopWaiting(for: provider), provider != .google {
                    // Google's Antigravity CLI has no cooperative per-provider
                    // cancel path, matching the previous app.
                    Button("Stop") { state.stopWaiting(for: provider) }
                        .controlSize(.mini)
                        .help("Stop waiting for this model and continue to synthesis with the completed responses.")
                }
                iconButton("arrow.up.left.and.arrow.down.right", help: "Open in focused reader") {
                    state.openReader(for: provider)
                }
            }

            MarkdownTextView(text: response.text, baseSize: 13)
        }
        .card(padding: 10)
    }

    @ViewBuilder
    private var statusView: some View {
        switch response.status {
        case .idle:
            EmptyView()
        case .waiting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Waiting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            if let elapsed = response.elapsedSeconds {
                Text("· \(Int(elapsed))s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        case .stopRequested:
            Text("Stopping…")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
