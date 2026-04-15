import Foundation
import AppKit
import CoreGraphics

/// Inserts text into the currently focused text field by simulating Cmd+V paste.
/// Saves and restores the original clipboard contents.
enum TextInserter {

    /// Insert text into the active app's focused text field.
    /// Uses clipboard + Cmd+V simulation (same approach as Raycast, Alfred, TextExpander).
    static func insert(_ text: String) async {
        let pasteboard = NSPasteboard.general

        // 1. Save current clipboard contents
        let savedContents = savePasteboard(pasteboard)

        // Guarantee restoration even if anything below throws or is cancelled.
        defer {
            restorePasteboard(pasteboard, from: savedContents)
        }

        // 2. Set our text on the clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Small delay to ensure pasteboard is ready
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // 4. Simulate Cmd+V keystroke
        simulatePaste()

        // 5. Wait for target app to process the paste
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
    }

    // MARK: - Private

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code 9 = 'V' on US keyboard layout
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Save all pasteboard items for later restoration.
    private static func savePasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        var saved: [[NSPasteboard.PasteboardType: Data]] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var itemData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemData[type] = data
                }
            }
            saved.append(itemData)
        }

        return saved
    }

    /// Restore previously saved pasteboard contents.
    private static func restorePasteboard(
        _ pasteboard: NSPasteboard,
        from saved: [[NSPasteboard.PasteboardType: Data]]
    ) {
        pasteboard.clearContents()

        if saved.isEmpty { return }

        var items: [NSPasteboardItem] = []
        for itemData in saved {
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            items.append(item)
        }

        pasteboard.writeObjects(items)
    }
}
