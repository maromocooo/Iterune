import SwiftUI
import AppKit
import SkillStudioCore

/// Native selectable text with a selection-anchored comment popover; no web content or scripts.
struct AnnotatableDocumentView: NSViewRepresentable {
    let content: String
    let raw: Bool
    let isTranslation: Bool
    let onComment: (SelectionComment, String) -> Void
    private static let sourceRangeKey = NSAttributedString.Key("studio.sourceRange")

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let text = SelectionTextView()
        text.isEditable = false; text.isSelectable = true; text.isRichText = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 24, height: 24)
        text.backgroundColor = .white
        text.setAccessibilityLabel(L("Skill document"))
        scroll.documentView = text
        let coordinator = context.coordinator
        text.onSelection = { [weak text, weak coordinator] in
            if let text { coordinator?.showComment(in: text) }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? SelectionTextView else { return }
        let coordinator = context.coordinator
        coordinator.onComment = onComment
        if coordinator.content != content || coordinator.raw != raw || coordinator.isTranslation != isTranslation {
            coordinator.popover?.close()
            coordinator.content = content; coordinator.raw = raw; coordinator.isTranslation = isTranslation
            text.textStorage?.setAttributedString(Self.render(content, raw: raw))
            text.setSelectedRange(NSRange(location: 0, length: 0))
            text.scrollToBeginningOfDocument(nil)
        }
    }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.popover?.close() }

    private static func render(_ source: String, raw: Bool) -> NSAttributedString {
        if raw { return NSAttributedString(string: source, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor]) }
        let result = NSMutableAttributedString(string: "")
        var offset = 0
        var fence: Character?
        for line in source.components(separatedBy: "\n") {
            let sourceRange = NSRange(location: offset, length: (line as NSString).length)
            offset += sourceRange.length + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if fence == nil { fence = trimmed.first } else if fence == trimmed.first { fence = nil }
                continue
            }
            let level = line.prefix(while: { $0 == "#" }).count
            let heading = fence == nil && (1...6).contains(level) && line.dropFirst(level).first == " "
            let visible = heading ? String(line.dropFirst(level + 1)) : line
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5; paragraph.paragraphSpacing = heading ? 10 : 3
            let part: NSMutableAttributedString
            if fence == nil, !heading, let styled = try? AttributedString(markdown: visible, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                part = NSMutableAttributedString(attributedString: NSAttributedString(styled))
            } else { part = NSMutableAttributedString(string: visible) }
            let font: NSFont = fence != nil ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: heading ? (level == 1 ? 22 : 16) : 13, weight: heading ? .semibold : .regular)
            part.addAttributes([.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
                                sourceRangeKey: NSValue(range: sourceRange)], range: NSRange(location: 0, length: part.length))
            result.append(part)
            result.append(NSAttributedString(string: "\n", attributes: [.font: font, sourceRangeKey: NSValue(range: sourceRange)]))
        }
        return result
    }

    final class Coordinator {
        var content: String?
        var raw = false
        var isTranslation = false
        var onComment: ((SelectionComment, String) -> Void)?
        var popover: NSPopover?
        func showComment(in text: NSTextView) {
            let range = text.selectedRange(), displayed = text.string as NSString
            guard range.length > 0, NSMaxRange(range) <= displayed.length else { return }
            let quote = displayed.substring(with: range)
            guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            var sourceRange: NSRange?
            if !isTranslation {
                if raw { sourceRange = range }
                else {
                    text.textStorage?.enumerateAttribute(sourceRangeKey, in: range) { value, _, _ in
                        if let value = value as? NSValue { sourceRange = sourceRange.map { NSUnionRange($0, value.rangeValue) } ?? value.rangeValue }
                    }
                }
            }
            let context = displayed.substring(with: displayed.paragraphRange(for: range))
            let selection = SelectionComment(quote: quote, context: String(context.prefix(5_000)), isTranslation: isTranslation, sourceRange: sourceRange)
            popover?.close()
            let popup = NSPopover(); popup.behavior = .semitransient
            popup.contentViewController = NSHostingController(rootView: SelectionCommentPopover(selection: selection) { [weak self, weak popup] feedback in
                popup?.close(); self?.onComment?(selection, feedback)
            })
            popover = popup
            var actual = NSRange()
            let screenRect = text.firstRect(forCharacterRange: NSRange(location: range.location, length: min(range.length, 1)), actualRange: &actual)
            guard let window = text.window else { return }
            let rect = text.convert(window.convertFromScreen(screenRect), from: nil)
            popup.show(relativeTo: rect, of: text, preferredEdge: .maxY)
        }
    }
}

final class SelectionTextView: NSTextView {
    var onSelection: (() -> Void)?
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event); onSelection?() }
    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        if event.modifierFlags.contains(.shift) { onSelection?() }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if selectedRange().length > 0 {
            let item = NSMenuItem(title: L("Comment on selection"), action: #selector(commentSelection), keyEquivalent: "")
            item.target = self; menu.insertItem(item, at: 0)
        }
        return menu
    }
    @objc private func commentSelection() { onSelection?() }
}

private struct SelectionCommentPopover: View {
    let selection: SelectionComment
    let submit: (String) -> Void
    @State private var feedback = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("Comment on selection"), systemImage: "text.bubble").font(.headline)
            Text(selection.quote).font(.callout).lineLimit(4).foregroundStyle(.secondary)
            if selection.isTranslation {
                Text(L("This quote is translated. Your instruction will revise the original language.")).font(.caption).foregroundStyle(.secondary)
            }
            Text(L("What should be better?")).font(.callout)
            TextEditor(text: $feedback).font(.body).frame(height: 90).focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.3)))
            Button(L("Continue to improvement")) { submit(feedback) }.buttonStyle(.borderedProminent)
                .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(18).frame(width: 350).onAppear { focused = true }
    }
}
