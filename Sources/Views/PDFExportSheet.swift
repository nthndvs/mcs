import SwiftUI

/// Section picker shown before exporting a comparison as PDF. The synthesis
/// is always placed first in the report when included.
struct PDFExportSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export comparison as PDF")
                .font(.title3.weight(.semibold))
            Text("Choose which responses to include. The PDF contains real, selectable text, and the synthesis always appears first when selected.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                if state.pdfExport?.hasSynthesis == true {
                    Toggle("Synthesis (always first)", isOn: synthesisBinding)
                        .toggleStyle(.checkbox)
                    Divider()
                }
                ForEach(state.pdfExport?.availableProviders ?? []) { provider in
                    Toggle(provider.displayName, isOn: providerBinding(provider))
                        .toggleStyle(.checkbox)
                }
            }

            HStack {
                Button("Select all") { setAll(true) }
                    .controlSize(.small)
                Button("Select none") { setAll(false) }
                    .controlSize(.small)
                Spacer()
                Button("Cancel", role: .cancel) { state.pdfExport = nil; dismiss() }
                Button("Export…") { state.confirmPDFExport(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.pdfExport?.canExport == false)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var synthesisBinding: Binding<Bool> {
        Binding(
            get: { state.pdfExport?.includeSynthesis ?? false },
            set: { state.pdfExport?.includeSynthesis = $0 }
        )
    }

    private func providerBinding(_ provider: ProviderID) -> Binding<Bool> {
        Binding(
            get: { state.pdfExport?.includedProviders.contains(provider) ?? false },
            set: { included in
                if included {
                    state.pdfExport?.includedProviders.insert(provider)
                } else {
                    state.pdfExport?.includedProviders.remove(provider)
                }
            }
        )
    }

    private func setAll(_ included: Bool) {
        guard let export = state.pdfExport else { return }
        state.pdfExport?.includeSynthesis = included && export.hasSynthesis
        state.pdfExport?.includedProviders = included ? Set(export.availableProviders) : []
    }
}
