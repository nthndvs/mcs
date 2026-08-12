import AppKit
import UniformTypeIdentifiers

/// Builds and writes the shareable PDF report for a saved comparison folder.
///
/// Rendering goes through NSPrintOperation with an NSTextView, so the PDF
/// contains real, selectable, searchable text (the previous rasterized-image
/// approach produced pages that were pictures of text).
enum PDFReportService {

    /// Which content blocks a folder can offer for export.
    static func availableProviders(in folder: URL) -> [ProviderID] {
        ProviderID.allCases.filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.resultFileName).path)
        }
    }

    static func hasSynthesis(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("summary.txt").path)
    }

    /// Exports the comparison in `folder`. The synthesis is always placed
    /// first (when included), followed by the prompt, then the selected
    /// provider responses in roster order. `activePrompt` is used when the
    /// export targets the folder from the run currently shown in the app.
    /// Returns a user-facing status message.
    @discardableResult
    static func export(
        folder: URL,
        includeSynthesis: Bool,
        providers: [ProviderID],
        activePrompt: String?,
        isActiveFolder: Bool
    ) -> String {
        guard includeSynthesis || !providers.isEmpty else {
            return "Select at least one section to include in the PDF."
        }

        let panel = NSSavePanel()
        panel.title = "Export Model Compare PDF"
        panel.message = "Choose where to save a shareable copy of this comparison."
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = folder
        panel.nameFieldStringValue = "Model Compare - \(pdfFilenameDate()).pdf"
        guard panel.runModal() == .OK, let destination = panel.url else {
            return "PDF export cancelled."
        }

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.paperSize = NSSize(width: 612, height: 792) // US Letter
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54
        printInfo.topMargin = 54
        printInfo.bottomMargin = 54
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey(rawValue: "NSPrintJobSavingURL")] = destination

        let content = buildReport(
            from: folder,
            includeSynthesis: includeSynthesis,
            providers: providers,
            activePrompt: activePrompt,
            isActiveFolder: isActiveFolder
        )

        let printableWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: printableWidth, height: 100))
        textView.textContainerInset = .zero
        textView.isEditable = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: printableWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(content)
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            textView.frame = NSRect(x: 0, y: 0, width: printableWidth, height: ceil(used.height))
        }

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: destination.path) else {
            return "PDF export did not complete. Try another save location."
        }
        return "PDF exported: \(destination.lastPathComponent)"
    }

    private static func buildReport(
        from folder: URL,
        includeSynthesis: Bool,
        providers: [ProviderID],
        activePrompt: String?,
        isActiveFolder: Bool
    ) -> NSAttributedString {
        let report = NSMutableAttributedString()
        let bodyColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
        let mutedColor = NSColor(calibratedRed: 0.36, green: 0.38, blue: 0.42, alpha: 1)
        let accentColor = NSColor(calibratedRed: 0.62, green: 0.24, blue: 0.13, alpha: 1)
        let codeBackground = NSColor(calibratedWhite: 0.93, alpha: 1)

        func append(_ text: String, font: NSFont, color: NSColor, spacing: CGFloat) {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.paragraphSpacing = spacing
            report.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style,
            ]))
        }

        func appendSection(_ title: String) {
            append(title.uppercased() + "\n", font: .systemFont(ofSize: 10, weight: .semibold), color: accentColor, spacing: 4)
        }

        append("Model Compare\n", font: .systemFont(ofSize: 24, weight: .bold), color: bodyColor, spacing: 2)
        append("Shareable comparison report - \(pdfDisplayDate(for: folder))\n\n", font: .systemFont(ofSize: 11), color: mutedColor, spacing: 14)

        // Synthesis always leads the report when it is part of the export.
        if includeSynthesis {
            appendSection("Synthesis")
            let summaryFile = folder.appendingPathComponent("summary.txt")
            let summary = (try? String(contentsOf: summaryFile, encoding: .utf8)) ?? "No synthesis was produced."
            report.append(MarkdownRenderer.render(summary, baseSize: 12, bodyColor: bodyColor, codeBackground: codeBackground))
            report.append(NSAttributedString(string: "\n"))
        }

        appendSection("Prompt")
        report.append(MarkdownRenderer.render(
            reportPrompt(for: folder, activePrompt: activePrompt, isActiveFolder: isActiveFolder),
            baseSize: 12, bodyColor: bodyColor, codeBackground: codeBackground
        ))
        report.append(NSAttributedString(string: "\n"))

        for provider in providers {
            let file = folder.appendingPathComponent(provider.resultFileName)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let response = (try? String(contentsOf: file, encoding: .utf8)) ?? "Response could not be read."
            appendSection("\(provider.displayName) response")
            report.append(MarkdownRenderer.render(response, baseSize: 11.5, bodyColor: bodyColor, codeBackground: codeBackground))
            report.append(NSAttributedString(string: "\n"))
        }

        return report
    }

    private static func reportPrompt(for folder: URL, activePrompt: String?, isActiveFolder: Bool) -> String {
        if isActiveFolder,
           let activePrompt,
           !activePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return activePrompt
        }
        let contextFile = folder.appendingPathComponent("conversation-context.txt")
        if let context = try? String(contentsOf: contextFile, encoding: .utf8),
           let range = context.range(of: "USER REQUEST:\n", options: .backwards) {
            let afterRequest = String(context[range.upperBound...])
            let request = afterRequest.components(separatedBy: "\n\nMODEL RESPONSES:").first ?? afterRequest
            if !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return request }
        }
        let readme = folder.appendingPathComponent("README.md")
        if let text = try? String(contentsOf: readme, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("Prompt: ") }) {
            return String(line.dropFirst("Prompt: ".count))
        }
        return "Prompt was not available in this saved result."
    }

    private static func pdfFilenameDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: Date())
    }

    private static func pdfDisplayDate(for folder: URL) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyyMMdd-HHmmss"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if let date = parser.date(from: folder.lastPathComponent) { return formatter.string(from: date) }
        return folder.lastPathComponent
    }
}
