import AppKit

/// A small, dependency-free Markdown renderer for the read-only model panes.
/// It handles the formatting model answers most commonly contain: headings,
/// bulleted/numbered lists (including nesting and task boxes), emphasis,
/// inline and fenced code, tables, links, blockquotes, strikethrough, and
/// horizontal rules.
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
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        func baseParagraph() -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = 7
            return style
        }

        var inCodeBlock = false
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                if !inCodeBlock { output.append(NSAttributedString(string: "\n")) }
                index += 1
                continue
            }

            if inCodeBlock {
                let codeParagraph = baseParagraph()
                codeParagraph.paragraphSpacing = 2
                output.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular),
                    .foregroundColor: bodyColor,
                    .backgroundColor: codeBackground,
                    .paragraphStyle: codeParagraph,
                ]))
                index += 1
                continue
            }

            // Pipe table: a header row, a --- separator row, then body rows.
            if isTableRow(trimmed), index + 1 < lines.count,
               isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                var rowLines = [trimmed]
                index += 2
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isTableRow(candidate) else { break }
                    rowLines.append(candidate)
                    index += 1
                }
                appendTable(rowLines, to: output, baseSize: baseSize, bodyColor: bodyColor, codeBackground: codeBackground)
                continue
            }

            // Horizontal rule: three or more -, _, or * and nothing else.
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == "_" || $0 == "*" }) {
                let ruleParagraph = baseParagraph()
                ruleParagraph.paragraphSpacing = 4
                output.append(NSAttributedString(string: String(repeating: "─", count: 28) + "\n", attributes: [
                    .font: bodyFont,
                    .foregroundColor: bodyColor.withAlphaComponent(0.35),
                    .paragraphStyle: ruleParagraph,
                ]))
                index += 1
                continue
            }

            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let indentLevel = leadingSpaces / 2

            var font = bodyFont
            var color = bodyColor
            var prefix = ""
            let paragraphStyle = baseParagraph()
            var content = trimmed

            if trimmed.hasPrefix("### ") {
                font = NSFont.systemFont(ofSize: baseSize + 1, weight: .semibold)
                paragraphStyle.paragraphSpacing = 5
                content = String(trimmed.dropFirst(4))
            } else if trimmed.hasPrefix("## ") {
                font = NSFont.systemFont(ofSize: baseSize + 3, weight: .semibold)
                paragraphStyle.paragraphSpacing = 7
                content = String(trimmed.dropFirst(3))
            } else if trimmed.hasPrefix("# ") {
                font = NSFont.systemFont(ofSize: baseSize + 5, weight: .bold)
                paragraphStyle.paragraphSpacing = 10
                content = String(trimmed.dropFirst(2))
            } else if trimmed.hasPrefix(">") {
                // Blockquote: indented and muted, with a leading bar glyph.
                color = bodyColor.withAlphaComponent(0.75)
                content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                paragraphStyle.firstLineHeadIndent = 14
                paragraphStyle.headIndent = 14
                paragraphStyle.paragraphSpacing = 5
                prefix = "▍ "
            } else if let checkbox = checkboxPrefix(trimmed) {
                prefix = checkbox.symbol
                content = checkbox.rest
                paragraphStyle.firstLineHeadIndent = CGFloat(indentLevel) * 16
                paragraphStyle.headIndent = CGFloat(indentLevel) * 16 + 18
                paragraphStyle.paragraphSpacing = 3
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                prefix = indentLevel == 0 ? "•  " : (indentLevel == 1 ? "◦  " : "▪  ")
                content = String(trimmed.dropFirst(2))
                paragraphStyle.firstLineHeadIndent = CGFloat(indentLevel) * 16
                paragraphStyle.headIndent = CGFloat(indentLevel) * 16 + 16
                paragraphStyle.paragraphSpacing = 3
            } else if let dot = trimmed.firstIndex(of: "."),
                      trimmed[..<dot].allSatisfy({ $0.isNumber }), !trimmed[..<dot].isEmpty,
                      trimmed.index(after: dot) < trimmed.endIndex, trimmed[trimmed.index(after: dot)] == " " {
                // Numbered list: keep the original number.
                prefix = String(trimmed[..<dot]) + ".  "
                content = String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
                paragraphStyle.firstLineHeadIndent = CGFloat(indentLevel) * 16
                paragraphStyle.headIndent = CGFloat(indentLevel) * 16 + 22
                paragraphStyle.paragraphSpacing = 3
            }

            if !prefix.isEmpty {
                output.append(NSAttributedString(string: prefix, attributes: [
                    .font: font,
                    .foregroundColor: color.withAlphaComponent(0.8),
                ]))
            }
            let inline = renderInline(content, font: font, color: color, codeBackground: codeBackground)
            let lineWithAttributes = NSMutableAttributedString(attributedString: inline)
            lineWithAttributes.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: lineWithAttributes.length))
            output.append(lineWithAttributes)
            output.append(NSAttributedString(string: "\n"))
            index += 1
        }
        if output.length == 0 { output.append(NSAttributedString(string: "")) }
        return output
    }

    // MARK: - Tables

    private static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.hasSuffix("|") && line.count > 1
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard isTableRow(line) else { return false }
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let dashes = cell.filter { $0 == "-" }.count
            let other = cell.filter { $0 != "-" && $0 != ":" }.count
            return dashes >= 2 && other == 0
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var row = line
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Renders a pipe table as a real NSTextTable, so it stays selectable,
    /// wraps with the pane, and prints as genuine table text in PDFs.
    private static func appendTable(
        _ rowLines: [String],
        to output: NSMutableAttributedString,
        baseSize: CGFloat,
        bodyColor: NSColor,
        codeBackground: NSColor
    ) {
        let rows = rowLines.map(splitTableRow)
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return }

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.collapsesBorders = false
        table.hidesEmptyCells = false

        let headerFont = NSFont.systemFont(ofSize: baseSize - 0.5, weight: .semibold)
        let cellFont = NSFont.systemFont(ofSize: baseSize - 0.5)

        for (rowIndex, row) in rows.enumerated() {
            for columnIndex in 0..<columnCount {
                let cellText = columnIndex < row.count ? row[columnIndex] : ""
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex, rowSpan: 1,
                    startingColumn: columnIndex, columnSpan: 1
                )
                block.setContentWidth(100.0 / CGFloat(columnCount), type: .percentageValueType)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(.separatorColor)
                block.setWidth(5, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(5, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(3, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(3, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.verticalAlignment = .middleAlignment
                if rowIndex == 0 { block.backgroundColor = codeBackground }

                let cellParagraph = NSMutableParagraphStyle()
                cellParagraph.textBlocks = [block]
                cellParagraph.lineSpacing = 2

                let cell = NSMutableAttributedString(attributedString: renderInline(
                    cellText,
                    font: rowIndex == 0 ? headerFont : cellFont,
                    color: bodyColor,
                    codeBackground: codeBackground
                ))
                cell.addAttribute(.paragraphStyle, value: cellParagraph, range: NSRange(location: 0, length: cell.length))
                output.append(cell)
                output.append(NSAttributedString(string: "\n"))
            }
        }
        output.append(NSAttributedString(string: "\n"))
    }

    // MARK: - Lists

    private static func checkboxPrefix(_ trimmed: String) -> (symbol: String, rest: String)? {
        for (marker, symbol) in [("- [x]", "☑ "), ("- [X]", "☑ "), ("- [ ]", "☐ ")] {
            if trimmed.hasPrefix(marker) {
                return (symbol, String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    // MARK: - Inline spans

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

        scan: while index < chars.count {
            // Bold-italic ***text***
            if index + 2 < chars.count, chars[index] == "*", chars[index + 1] == "*", chars[index + 2] == "*",
               let end = find(chars, marker: "***", from: index + 3) {
                flushPlain()
                let inner = String(chars[(index + 3)..<end])
                let boldItalic = NSFontManager.shared.convert(NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), toHaveTrait: .italicFontMask)
                result.append(NSAttributedString(string: inner, attributes: [.font: boldItalic, .foregroundColor: color]))
                index = end + 3
                continue
            }
            // Bold **text**
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
            // Strikethrough ~~text~~
            if index + 1 < chars.count, chars[index] == "~", chars[index + 1] == "~",
               let end = find(chars, marker: "~~", from: index + 2) {
                flushPlain()
                let inner = String(chars[(index + 2)..<end])
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: font,
                    .foregroundColor: color.withAlphaComponent(0.7),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ]))
                index = end + 2
                continue
            }
            // Inline code `text`
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
            // Markdown link [text](url)
            if chars[index] == "[",
               let closeBracket = find(chars, marker: "](", from: index + 1),
               let closeParen = find(chars, marker: ")", from: closeBracket + 2) {
                flushPlain()
                let label = String(chars[(index + 1)..<closeBracket])
                let urlString = String(chars[(closeBracket + 2)..<closeParen])
                result.append(NSAttributedString(string: label, attributes: linkAttributes(urlString, font: font)))
                index = closeParen + 1
                continue
            }
            // Bare URL
            if chars[index] == "h" {
                let rest = String(chars[index...])
                if rest.hasPrefix("https://") || rest.hasPrefix("http://") {
                    var end = index
                    while end < chars.count, !chars[end].isWhitespace { end += 1 }
                    var urlEnd = end
                    while urlEnd > index, ".,;:!?)]}\"'".contains(chars[urlEnd - 1]) { urlEnd -= 1 }
                    if urlEnd > index + 8 {
                        flushPlain()
                        let urlString = String(chars[index..<urlEnd])
                        result.append(NSAttributedString(string: urlString, attributes: linkAttributes(urlString, font: font)))
                        index = urlEnd
                        continue
                    }
                }
            }
            // Italic *text*
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

    private static func linkAttributes(_ urlString: String, font: NSFont) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let url = URL(string: urlString), url.scheme != nil {
            attributes[.link] = url
        } else {
            attributes[.link] = urlString
        }
        return attributes
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
