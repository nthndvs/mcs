import SwiftUI

/// Main window: settings sidebar + the comparison workspace, with the focused
/// reader as an overlay on the detail area.
struct ContentView: View {
    @EnvironmentObject var state: AppState

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
        VStack(spacing: 12) {
            PromptComposerView()
            ResponseGridView()
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            SynthesisView()
            ActivityLogView()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $state.pdfExport) { _ in
            PDFExportSheet()
        }
    }
}
