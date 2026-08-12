import AppKit

/// A small, dependency-free Markdown renderer for the read-only model panes.
/// It intentionally handles the formatting people most commonly get back from
/// the CLIs (headings, bullets, emphasis, inline code, and fenced code).
///
/// Colors default to dynamic system colors so the same renderer serves the
/// light/dark UI; the PDF report passes fixed print colors instead.
final class MarkdownRenderer {
    static func render(
        _ text: String,
        baseSize: CGFloat = 13,
        bodyColor: NSColor = .labelColor,
        codeBackground: NSColor = .unemphasizedSelectedContentBackgroundColor
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: baseSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 7

        var inCodeBlock = false
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeBlock.toggle()
                if !inCodeBlock { output.append(NSAttributedString(string: "\n")) }
                continue
            }

            if inCodeBlock {
                let codeParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
                codeParagraph.paragraphSpacing = 2
                output.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular),
                    .foregroundColor: bodyColor,
                    .backgroundColor: codeBackground,
                    .paragraphStyle: codeParagraph,
                ]))
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var font = bodyFont
            let color = bodyColor
            var prefix = ""
            var paragraphStyle = paragraph
            if trimmed.hasPrefix("### ") {
                font = NSFont.systemFont(ofSize: baseSize + 1, weight: .semibold)
                paragraphStyle = paragraph.mutableCopy() as! NSMutableParagraphStyle
                paragraphStyle.paragraphSpacing = 5
            } else if trimmed.hasPrefix("## ") {
                font = NSFont.systemFont(ofSize: baseSize + 3, weight: .semibold)
                paragraphStyle = paragraph.mutableCopy() as! NSMutableParagraphStyle
                paragraphStyle.paragraphSpacing = 7
            } else if trimmed.hasPrefix("# ") {
                font = NSFont.systemFont(ofSize: baseSize + 5, weight: .bold)
                paragraphStyle = paragraph.mutableCopy() as! NSMutableParagraphStyle
                paragraphStyle.paragraphSpacing = 10
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                prefix = "•  "
            } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy({ $0.isNumber }) {
                prefix = "•  "
            }

            var content = trimmed
            if trimmed.hasPrefix("### ") { content = String(trimmed.dropFirst(4)) }
            if trimmed.hasPrefix("## ") { content = String(trimmed.dropFirst(3)) }
            if trimmed.hasPrefix("# ") { content = String(trimmed.dropFirst(2)) }
            if !prefix.isEmpty {
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { content = String(trimmed.dropFirst(2)) }
                else if let dot = trimmed.firstIndex(of: ".") { content = String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces) }
            }

            let lineText = prefix + content
            let inline = renderInline(lineText, font: font, color: color, codeBackground: codeBackground)
            let lineWithAttributes = NSMutableAttributedString(attributedString: inline)
            lineWithAttributes.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: lineWithAttributes.length))
            output.append(lineWithAttributes)
            output.append(NSAttributedString(string: "\n"))
        }
        if output.length == 0 { output.append(NSAttributedString(string: "")) }
        return output
    }

    private static func renderInline(_ line: String, font: NSFont, color: NSColor, codeBackground: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let chars = Array(line)
        var index = 0
        var plain = ""

        func flushPlain() {
            guard !plain.isEmpty else { return }
            result.append(NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: color]))
            plain.removeAll(keepingCapacity: true)
        }

        while index < chars.count {
            if index + 1 < chars.count, chars[index] == "*", chars[index + 1] == "*" {
                if let end = find(chars, marker: "**", from: index + 2) {
                    flushPlain()
                    let inner = String(chars[(index + 2)..<end])
                    result.append(NSAttributedString(string: inner, attributes: [
                        .font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                        .foregroundColor: color,
                    ]))
                    index = end + 2
                    continue
                }
            }
            if chars[index] == "`", let end = find(chars, marker: "`", from: index + 1) {
                flushPlain()
                let inner = String(chars[(index + 1)..<end])
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: max(10, font.pointSize - 1), weight: .regular),
                    .foregroundColor: color,
                    .backgroundColor: codeBackground,
                ]))
                index = end + 1
                continue
            }
            if chars[index] == "*", let end = find(chars, marker: "*", from: index + 1) {
                flushPlain()
                let inner = String(chars[(index + 1)..<end])
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask),
                    .foregroundColor: color,
                ]))
                index = end + 1
                continue
            }
            plain.append(chars[index])
            index += 1
        }
        flushPlain()
        return result
    }

    private static func find(_ chars: [Character], marker: String, from start: Int) -> Int? {
        let markerChars = Array(marker)
        let lastStart = chars.count - markerChars.count
        guard !markerChars.isEmpty, start <= lastStart else { return nil }
        for index in start...lastStart {
            if Array(chars[index..<(index + markerChars.count)]) == markerChars { return index }
        }
        return nil
    }
}
