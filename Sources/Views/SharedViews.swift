import AppKit
import SwiftUI

/// Read-only, selectable, scrolling Markdown view backed by NSTextView so the
/// ported MarkdownRenderer drives the presentation.
struct MarkdownTextView: NSViewRepresentable {
    let text: String
    var baseSize: CGFloat = 13
    var inset: CGFloat = 10

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: inset, height: inset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        guard textView.string != text else { return }
        let rendered = MarkdownRenderer.render(text, baseSize: baseSize)
        textView.textStorage?.setAttributedString(rendered)
        textView.scrollToBeginningOfDocument(nil)
    }
}

/// Monospaced, auto-scrolling log view for launcher and installer output.
struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .secondaryLabelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        guard textView.string != text else { return }
        textView.string = text
        textView.scrollToEndOfDocument(nil)
    }
}

/// An editable combo box (presets plus free-form model IDs), matching the
/// previous app's NSComboBox behavior including typed-but-uncommitted text.
struct EditableComboBox: NSViewRepresentable {
    let items: [String]
    @Binding var text: String
    var placeholder: String = ""
    var onChange: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.isEditable = true
        combo.completes = true
        combo.addItems(withObjectValues: items)
        combo.stringValue = text
        combo.placeholderString = placeholder
        combo.font = .systemFont(ofSize: 12)
        combo.target = context.coordinator
        combo.action = #selector(Coordinator.selectionChanged(_:))
        combo.delegate = context.coordinator
        return combo
    }

    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.parent = self
        // Never write state back into the combo while the user is editing it:
        // a re-render triggered by an unrelated control (status text, a key
        // field's CLI-status refresh) would otherwise stomp the in-progress
        // edit with the last committed value — the "selection reset" bug.
        let isEditing = combo.currentEditor() != nil
        if !isEditing, combo.stringValue != text {
            combo.stringValue = text
        }
        if !isEditing, (combo.objectValues as? [String]) != items {
            combo.removeAllItems()
            combo.addItems(withObjectValues: items)
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: EditableComboBox

        init(_ parent: EditableComboBox) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSComboBox) {
            parent.text = sender.stringValue
            parent.onChange(sender.stringValue)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            parent.text = combo.stringValue
            parent.onChange(combo.stringValue)
        }

        /// Commit the final text when focus leaves, so a typed value is never
        /// lost even if an earlier re-render skipped the state update.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            if parent.text != combo.stringValue {
                parent.text = combo.stringValue
                parent.onChange(combo.stringValue)
            }
        }
    }
}

/// Shared card container styling.
struct CardStyle: ViewModifier {
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
    }
}

/// A horizontal grabber the user drags to resize the panel above or below it.
/// `invert` flips the drag direction for dividers that sit *above* the panel
/// they resize (dragging up grows that panel).
struct VerticalDragDivider: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var invert: Bool = false
    var help: String = "Drag to resize"

    @State private var dragStart: CGFloat?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(nsColor: .separatorColor).opacity((hovering || dragStart != nil) ? 0.95 : 0.45))
                .frame(width: 64, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 14)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if dragStart == nil { dragStart = value }
                    guard let start = dragStart else { return }
                    let delta = gesture.translation.height * (invert ? -1 : 1)
                    value = min(range.upperBound, max(range.lowerBound, start + delta))
                }
                .onEnded { _ in dragStart = nil }
        )
        .help(help)
    }
}

extension View {
    func card(padding: CGFloat = 12) -> some View { modifier(CardStyle(padding: padding)) }
}

/// Small colored status dot with a label.
struct StatusBadge: View {
    let status: CLIStatus

    private var color: Color {
        if status.isReady { return .green }
        switch status {
        case .notInstalled: return .red
        case .checking: return .secondary
        default: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(status.label)
    }
}
