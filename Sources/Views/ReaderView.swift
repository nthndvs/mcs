import SwiftUI

/// Full-detail-area reading view, presented as an overlay so a response can be
/// read without the workspace around it. Escape or Back returns to the
/// comparison.
struct ReaderView: View {
    let content: ReaderContent
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Focused Reader", systemImage: "book")
                    .font(.headline)
                Spacer()
                Button("Back to comparison", action: onClose)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            Text(content.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            MarkdownTextView(text: content.body, baseSize: 15, inset: 16)
                .card(padding: 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
