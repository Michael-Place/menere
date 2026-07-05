import SwiftUI

// MARK: - Markdown ↔ AttributedString bridge
//
// Rich-Text C1. iOS 26 lets `TextEditor` bind to an `AttributedString` for native rich text
// (bold/italic/underline + Writing Tools + Genmoji, all for free). For persistence we deliberately
// store a **portable Markdown `String`** (Firestore-friendly, future web-client-friendly) rather
// than an archived `AttributedString` — see the "Native rich text" backlog in ROADMAP-family.md.
//
// Round-trip contract: **bold** and *italic* survive the Markdown round-trip (they map to
// `inlinePresentationIntent` on parse and to SwiftUI `Font` weight/slant on render). **Underline**
// is a live editing affordance but has no Markdown representation, so it is intentionally NOT
// persisted (it renders while you edit, then drops on save — documented, minor). Plain/empty
// strings decode as unformatted text, so existing plain-`String` fields migrate for free.

public enum RichNoteMarkdown {
    /// Parse a stored Markdown string into a rendered `AttributedString`. Empty / plain input
    /// yields unformatted text (decode-safe migration). Inline-only parsing preserves the user's
    /// line breaks and whitespace (notes aren't documents — no headers/lists collapsing).
    public static func attributed(from markdown: String) -> AttributedString {
        guard !markdown.isEmpty else { return AttributedString() }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard var string = try? AttributedString(markdown: markdown, options: options) else {
            // Malformed markup: fall back to the raw text rather than losing the note.
            return AttributedString(markdown)
        }
        // The parser tags emphasis with Foundation's `inlinePresentationIntent`; mirror that onto a
        // SwiftUI `Font` so the editable/rendered text actually shows bold/italic.
        for run in string.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            var font = Font.system(.body, design: .rounded)
            var formatted = false
            if intent.contains(.stronglyEmphasized) { font = font.bold(); formatted = true }
            if intent.contains(.emphasized) { font = font.italic(); formatted = true }
            if formatted { string[run.range].font = font }
        }
        return string
    }

    /// Serialize the editor's `AttributedString` back to a Markdown string for persistence. Reads
    /// each run's SwiftUI `Font` (resolved against the view's context) for bold/italic and wraps the
    /// text in the matching markers. Whitespace-only runs are never wrapped (avoids invalid `** **`).
    public static func markdown(from attributed: AttributedString, context: Font.Context) -> String {
        var result = ""
        for run in attributed.runs {
            let text = String(attributed.characters[run.range])
            guard !text.isEmpty else { continue }
            var bold = false
            var italic = false
            if let font = run.font {
                let resolved = font.resolve(in: context)
                bold = resolved.isBold
                italic = resolved.isItalic
            }
            result += wrap(text, bold: bold, italic: italic)
        }
        return result
    }

    private static func wrap(_ text: String, bold: Bool, italic: Bool) -> String {
        guard bold || italic,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        var marker = ""
        if bold { marker += "**" }
        if italic { marker += "*" }
        return marker + text + String(marker.reversed())
    }
}

// MARK: - RichNoteEditor

/// A reusable, family-styled rich-text note editor (Rich-Text C1). Wraps the iOS 26 rich
/// `TextEditor(text: $attributedString, selection:)` with a small Bold/Italic/Underline format bar,
/// Apple-Intelligence **Writing Tools** (`.writingToolsBehavior(.complete)`), and Genmoji (both come
/// free on the standard control). Callers bind a **Markdown `String`** for persistence; the view
/// converts to/from `AttributedString` internally.
///
/// Graceful degradation: rich editing is the iOS 26 baseline (always works). Writing Tools / Genmoji
/// need an Apple-Intelligence-capable device — where unavailable the button simply doesn't appear and
/// plain rich editing keeps working. (Simulators generally lack Apple Intelligence.)
public struct RichNoteEditor: View {
    @Binding private var markdown: String
    private let placeholder: String
    private let minHeight: CGFloat

    @State private var text: AttributedString
    @State private var selection = AttributedTextSelection()
    @Environment(\.fontResolutionContext) private var fontContext

    public init(markdown: Binding<String>, placeholder: String = "Add a note…", minHeight: CGFloat = 120) {
        self._markdown = markdown
        self.placeholder = placeholder
        self.minHeight = minHeight
        self._text = State(initialValue: RichNoteMarkdown.attributed(from: markdown.wrappedValue))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            formatBar
            editor
        }
        // Editor edits → serialize to the persisted Markdown binding.
        .onChange(of: text) { _, newValue in
            markdown = RichNoteMarkdown.markdown(from: newValue, context: fontContext)
        }
        // External binding change (e.g. a fresh model load) that diverges from our text → re-parse.
        // Guarded so our own writes above don't cause a re-parse loop.
        .onChange(of: markdown) { _, newValue in
            if RichNoteMarkdown.markdown(from: text, context: fontContext) != newValue {
                text = RichNoteMarkdown.attributed(from: newValue)
            }
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.characters.isEmpty {
                Text(placeholder)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(Color.inkSoft)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text, selection: $selection)
                .writingToolsBehavior(.complete)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(Color.ink)
                .tint(Color.bacanGreen)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .accessibilityIdentifier("rich-note-editor")
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.familySurface))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.inkSoft.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: Format bar

    private var formatBar: some View {
        HStack(spacing: 6) {
            formatButton("bold", label: "Bold", id: "rich-note-bold", action: toggleBold)
            formatButton("italic", label: "Italic", id: "rich-note-italic", action: toggleItalic)
            formatButton("underline", label: "Underline", id: "rich-note-underline", action: toggleUnderline)
            Spacer(minLength: 0)
        }
    }

    private func formatButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.bacanGreen.opacity(0.12)))
                .foregroundStyle(Color.bacanGreen)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: Toggles (WWDC25 pattern — transformAttributes over the live selection)

    private func toggleBold() {
        text.transformAttributes(in: &selection) { container in
            let current = container.font ?? .system(.body, design: .rounded)
            let resolved = current.resolve(in: fontContext)
            container.font = current.bold(!resolved.isBold)
        }
    }

    private func toggleItalic() {
        text.transformAttributes(in: &selection) { container in
            let current = container.font ?? .system(.body, design: .rounded)
            let resolved = current.resolve(in: fontContext)
            container.font = current.italic(!resolved.isItalic)
        }
    }

    private func toggleUnderline() {
        text.transformAttributes(in: &selection) { container in
            container.underlineStyle = (container.underlineStyle == nil) ? .single : nil
        }
    }
}

// MARK: - RichNoteText (read-only renderer)

/// The read-only companion to ``RichNoteEditor`` — renders a stored Markdown note as formatted,
/// selectable text (selection enables Writing Tools on the rendered text too). Use anywhere a saved
/// note is displayed rather than edited.
public struct RichNoteText: View {
    private let attributed: AttributedString

    public init(markdown: String) {
        self.attributed = RichNoteMarkdown.attributed(from: markdown)
    }

    public var body: some View {
        Text(attributed)
            .font(.system(.body, design: .rounded))
            .foregroundStyle(Color.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
