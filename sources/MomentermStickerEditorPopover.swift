//
//  MomentermStickerEditorPopover.swift
//  iTerm2
//
//  Lightweight NSPopover used by PTYSession when the user picks
//  "스티커 붙이기…" / "스티커 편집…" from the right-click context menu on
//  a split pane. Single NSTextField; ⏎ saves, ⎋ or outside-click
//  dismisses. The save callback receives the trimmed text, or nil when
//  the field is empty (treated as "remove").
//
//  Anchored to the parent SessionView rather than the exact click point —
//  the menu has already closed by the time the action method runs, so the
//  original mouse coordinate is gone; anchoring to the view's top edge
//  gives a stable, predictable location regardless of where the user
//  right-clicked inside the pane.
//

import AppKit

@objc(MomentermStickerEditorPopover)
final class MomentermStickerEditorPopover: NSObject, NSPopoverDelegate, NSTextFieldDelegate {

    /// Cap input length so the persisted arrangement payload stays bounded
    /// and the on-pane pill remains readable. The hard cap mirrors the
    /// label's truncation behavior (single line, short identifier).
    private static let maxLength = 100

    private let popover = NSPopover()
    private let textField = NSTextField(string: "")
    private let onSave: (String?) -> Void
    private var didCommit = false
    /// Strong self-reference held during presentation so the popover stays
    /// alive even though the caller doesn't retain us. Released in
    /// `popoverDidClose:`.
    private var keepAlive: MomentermStickerEditorPopover?

    private init(initialText: String?, onSave: @escaping (String?) -> Void) {
        self.onSave = onSave
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        textField.stringValue = initialText ?? ""
        textField.placeholderString = "예: backend logs"
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.isEditable = true
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        container.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            textField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let vc = NSViewController()
        vc.view = container
        popover.contentViewController = vc
        popover.contentSize = container.bounds.size
    }

    /// Present an editor popover anchored to the top edge of `parentView`.
    /// `onSave` is invoked with the trimmed text on ⏎ (nil if empty),
    /// and is NOT invoked when the user cancels via ⎋ / outside-click.
    @objc(presentOverView:initialText:onSave:)
    static func present(over parentView: NSView,
                        initialText: String?,
                        onSave: @escaping (String?) -> Void) {
        let editor = MomentermStickerEditorPopover(initialText: initialText, onSave: onSave)
        editor.keepAlive = editor

        let bounds = parentView.bounds
        let anchor = NSRect(x: bounds.midX - 1, y: bounds.minY, width: 2, height: 2)
        editor.popover.show(relativeTo: anchor,
                            of: parentView,
                            preferredEdge: .minY)

        DispatchQueue.main.async { [weak editor] in
            guard let editor else { return }
            editor.popover.contentViewController?.view.window?.makeFirstResponder(editor.textField)
        }
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            didCommit = false
            popover.performClose(nil)
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        // Hard-cap length without disrupting the cursor by trimming only
        // when the field exceeds the cap.
        if textField.stringValue.count > Self.maxLength {
            textField.stringValue = String(textField.stringValue.prefix(Self.maxLength))
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        if !didCommit {
            // ⎋ / outside-click path — caller wants no-op, NOT a clear.
            // Releasing the keep-alive ref is enough; sticker stays as-is.
        }
        keepAlive = nil
    }

    // MARK: - Private

    private func commit() {
        didCommit = true
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmed.isEmpty ? nil : trimmed)
        popover.performClose(nil)
    }
}
