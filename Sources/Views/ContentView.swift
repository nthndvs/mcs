import SwiftUI

/// Main window: settings sidebar + the comparison workspace, with the focused
/// reader as an overlay on the detail area.
struct ContentView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("composerEditorHeight") private var composerEditorHeight = 96.0
    @AppStorage("synthesisSectionHeight") private var synthesisSectionHeight = 300.0

    private var composerHeight: Binding<CGFloat> {
        Binding(get: { CGFloat(composerEditorHeight) }, set: { composerEditorHeight = $0 })
    }

    private var synthesisHeight: Binding<CGFloat> {
        Binding(get: { CGFloat(synthesisSectionHeight) }, set: { synthesisSectionHeight = $0 })
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            ZStack {
                workspace
                if let reader = state.reader {
                    ReaderView(content: reader) {
                        withAnimation(.easeInOut(duration: 0.15)) { state.reader = nil }
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { state.beginPDFExport() } label: {
                        Label("Export PDF", systemImage: "doc.richtext")
                    }
                    .help("Save the latest comparison, including responses and synthesis, as a shareable PDF.")
                    Button { state.openLatest() } label: {
                        Label("Open Results", systemImage: "folder")
                    }
                    .help("Open the latest results folder's README.")
                    Button { state.refreshCLIStatus() } label: {
                        Label("Refresh CLI Status", systemImage: "arrow.clockwise")
                    }
                    .help("Check whether each required command-line client is installed.")
                }
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            if let update = state.availableUpdate {
                updateBanner(update)
                    .padding(.bottom, 10)
            }
            PromptComposerView(editorHeight: composerHeight)
            VerticalDragDivider(
                value: composerHeight,
                range: 52...260,
                help: "Drag to resize the prompt area"
            )
            ResponseGridView()
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            VerticalDragDivider(
                value: synthesisHeight,
                range: 200...560,
                invert: true,
                help: "Drag to resize the synthesis and follow-up area"
            )
            SynthesisView(sectionHeight: synthesisHeight.wrappedValue)
            ActivityLogView()
                .padding(.top, 10)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $state.pdfExport) { _ in
            PDFExportSheet()
        }
        .alert(item: $state.updateAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    /// Slim banner shown when a GitHub release newer than the running build
    /// exists. Dismissal is session-only; the next launch re-checks.
    private func updateBanner(_ update: UpdateInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text("Version \(update.version) is available — you're running \(UpdateService.currentVersion).")
                .font(.callout)
            Spacer()
            Button("Download") { state.openUpdateRelease() }
                .controlSize(.small)
            Button {
                state.dismissUpdateBanner()
            } label: {
                Image(systemName: "xmark")
            }
            .controlSize(.small)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss until the next launch.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
        )
    }
}
