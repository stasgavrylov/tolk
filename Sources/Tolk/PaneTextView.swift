import AppKit
import SwiftUI
import TolkCore

/// Text view for a pane. Selecting a word or phrase with the mouse in the translation pane asks for alternatives.
final class PaneTextView: NSTextView {
    var pane: Pane = .source
    weak var sharedUndoManager: UndoManager?
    var interactionEnabled = true
    override var undoManager: UndoManager? { sharedUndoManager ?? super.undoManager }
    override var acceptsFirstResponder: Bool { interactionEnabled && super.acceptsFirstResponder }
    /// Called after a mouse gesture (drag, double/triple click, shift-click) leaves a selection.
    var onMouseSelection: ((PaneTextView) -> Void)?
    var placeholder: String = "" { didSet { needsDisplay = true } }

    override func mouseDown(with event: NSEvent) {
        let before = selectedRange()
        super.mouseDown(with: event)
        // super runs the tracking loop until mouse-up, so this is the final selection. A plain click
        // inside an existing selection (e.g. starting a text drag) leaves it unchanged and is ignored;
        // a triple click re-fires with the wider selection.
        let after = selectedRange()
        if after.length > 0, after != before || event.clickCount > 1 { onMouseSelection?(self) }
    }

    var selectedText: String {
        let r = selectedRange()
        guard r.length > 0, NSMaxRange(r) <= (string as NSString).length else { return "" }
        return (string as NSString).substring(with: r)
    }

    /// Screen-independent rect of the selection in this view's coordinates.
    func selectionRect() -> NSRect {
        guard let layoutManager, let textContainer else { return bounds }
        let glyphs = layoutManager.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect.isEmpty ? NSRect(x: rect.minX, y: rect.minY, width: 1, height: max(rect.height, 16)) : rect
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 20), .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: attrs)
    }
}

/// Tracks both pane text views so menu commands (⌘E) can find the selection.
@MainActor
final class PaneRegistry {
    weak var source: PaneTextView?
    weak var translation: PaneTextView?

    /// The pane the user is working in: the focused one, else the one with a selection.
    func activePaneWithSelection() -> PaneTextView? {
        if let focused = NSApp.keyWindow?.firstResponder as? PaneTextView, focused.selectedRange().length > 0 { return focused }
        return [translation, source].compactMap { $0 }.first { $0.interactionEnabled && $0.selectedRange().length > 0 }
    }

    func focusEditor() {
        guard let source, source.interactionEnabled else { return }
        source.window?.makeFirstResponder(source)
    }

    func restoreEditorFocus() {
        guard let source, source.interactionEnabled, let window = source.window,
              !(window.firstResponder is PaneTextView) else { return }
        let previous = window.firstResponder
        // Wait for the disappearing control to leave the tree; do not steal focus if it has moved elsewhere.
        Task { @MainActor [weak window, weak source] in
            await Task.yield()
            guard let window, let source, source.interactionEnabled,
                  window.firstResponder === previous || window.firstResponder === window else { return }
            window.makeFirstResponder(source)
        }
    }
}

struct PaneEditor: NSViewRepresentable {
    let pane: Pane
    let text: String
    var editable = true
    var interactionEnabled = true
    let undoManager: UndoManager
    var placeholder = ""
    var fontSize: CGFloat = 20
    var textInset = NSSize(width: 14, height: 16)
    var accessibilityLabel: String?
    var accessibilityIdentifier: String?
    let registry: PaneRegistry
    var onChange: (String) -> Void
    var onMouseSelection: ((PaneTextView) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PaneTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // Replace the default text view with our subclass, keeping its configuration.
        let original = scroll.documentView as! NSTextView
        let tv = PaneTextView(frame: original.frame, textContainer: original.textContainer)
        tv.autoresizingMask = original.autoresizingMask
        tv.isVerticallyResizable = true
        tv.minSize = original.minSize
        tv.maxSize = original.maxSize
        scroll.documentView = tv
        tv.pane = pane
        tv.sharedUndoManager = undoManager
        tv.interactionEnabled = interactionEnabled
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: fontSize)
        tv.textContainerInset = textInset
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.setAccessibilityIdentifier(accessibilityIdentifier ?? (pane == .source ? "sourcePane" : "translationPane"))
        tv.setAccessibilityLabel(accessibilityLabel ?? (pane == .source ? "Source text" : "Translation"))
        tv.string = text
        tv.placeholder = placeholder
        tv.isEditable = editable && interactionEnabled
        tv.isSelectable = interactionEnabled
        tv.setAccessibilityHelp(placeholder)
        tv.onMouseSelection = onMouseSelection
        switch pane {
        case .source: registry.source = tv
        case .translation: registry.translation = tv
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? PaneTextView else { return }
        tv.onMouseSelection = onMouseSelection
        tv.sharedUndoManager = undoManager
        tv.interactionEnabled = interactionEnabled
        tv.isEditable = editable && interactionEnabled
        tv.isSelectable = interactionEnabled
        tv.placeholder = placeholder
        tv.setAccessibilityHelp(placeholder)
        if tv.string != text {
            let selection = tv.selectedRange()
            tv.string = text
            let length = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            tv.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PaneEditor
        init(_ parent: PaneEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.onChange(tv.string)
        }
    }
}

/// Shows the alternatives popover anchored at the selection.
@MainActor
final class SuggestionPresenter: NSObject, NSPopoverDelegate {
    private let translator: TranslatorModel
    private let popover = NSPopover()
    private var range = NSRange(location: NSNotFound, length: 0)
    private var pane: Pane = .translation
    private var revisionAtOpen = 0

    init(translator: TranslatorModel) {
        self.translator = translator
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    /// Mouse selection in the translation pane: open quietly for a word or phrase, ignore anything else.
    func presentForMouseSelection(from textView: PaneTextView) {
        guard PhraseSuggestion.opensOnSelection(textView.selectedText),
              !translator.isTranslating, !translator.isSmoothing, translator.effectiveSource != nil else { return }
        present(from: textView)
    }

    func present(from textView: PaneTextView) {
        let selection = textView.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { NSSound.beep(); return }
        if textView.pane == .translation, translator.isTranslating || translator.isSmoothing { NSSound.beep(); return }
        guard translator.effectiveSource != nil else { NSSound.beep(); return }
        pane = textView.pane
        range = textView.selectedRange()
        revisionAtOpen = translator.translationRevision
        translator.requestSuggestions(pane: pane, selection: selection)
        popover.contentViewController = NSHostingController(rootView: SuggestionsView(
            translator: translator, onPick: { [weak self] in self?.pick($0) }, onClose: { [weak self] in self?.close() }))
        popover.show(relativeTo: textView.selectionRect(), of: textView, preferredEdge: .maxY)
    }

    func pickForDev(_ suggestion: PhraseSuggestion) { pick(suggestion) }

    private func pick(_ suggestion: PhraseSuggestion) {
        switch pane {
        case .translation:
            guard translator.translationRevision == revisionAtOpen else { NSSound.beep(); close(); return }
            translator.applySuggestion(suggestion, range: range)
        case .source:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(suggestion.text, forType: .string)
        }
        close()
    }

    func close() {
        popover.performClose(nil)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            translator.dismissSuggestions()
        }
    }
}
