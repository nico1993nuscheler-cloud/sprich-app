import Foundation
import CoreGraphics
import AppKit

/// Manages global keyboard shortcuts using CGEvent tap.
/// Detects Fn+Shift (Literal), Fn+Control (Formal), Fn+Command (Custom).
class HotkeyManager {
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onActivate: (TranscriptionMode) -> Void
    private var onRelease: () -> Void

    // Optional gate — return false to disable the Custom combo when it's not configured.
    var isCustomModeAvailable: () -> Bool = { false }

    // Track current recording state to detect release
    private var isActive = false
    private var activeMode: TranscriptionMode?

    // Track modifier state to detect hold/release
    private var fnDown = false
    private var shiftDown = false
    private var controlDown = false
    private var commandDown = false

    init(onActivate: @escaping (TranscriptionMode) -> Void,
         onRelease: @escaping () -> Void) {
        self.onActivate = onActivate
        self.onRelease = onRelease
    }

    /// Start listening for global hotkeys. Requires Accessibility permission.
    func start() {
        guard Permissions.isAccessibilityGranted() else {
            #if DEBUG
            print("[Sprich] Accessibility permission not granted — hotkeys disabled")
            #endif
            return
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: userInfo
        ) else {
            #if DEBUG
            print("[Sprich] Failed to create event tap — check Accessibility permissions")
            #endif
            return
        }

        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        #if DEBUG
        print("[Sprich] Global hotkeys active: Fn+Shift (Literal), Fn+Control (Formal), Fn+Cmd (Custom)")
        #endif
    }

    /// Stop listening for global hotkeys.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Called from the CGEvent callback — must be fast.
    fileprivate func handleFlagsChanged(_ flags: CGEventFlags) {
        let newFn = flags.contains(.maskSecondaryFn)
        let newShift = flags.contains(.maskShift)
        let newControl = flags.contains(.maskControl)
        let newCommand = flags.contains(.maskCommand)

        let wasFnShift = fnDown && shiftDown && !controlDown && !commandDown
        let wasFnControl = fnDown && controlDown && !shiftDown && !commandDown
        let wasFnCommand = fnDown && commandDown && !shiftDown && !controlDown

        fnDown = newFn
        shiftDown = newShift
        controlDown = newControl
        commandDown = newCommand

        let isFnShift = fnDown && shiftDown && !controlDown && !commandDown
        let isFnControl = fnDown && controlDown && !shiftDown && !commandDown
        let isFnCommand = fnDown && commandDown && !shiftDown && !controlDown

        // Activation
        if !isActive {
            if isFnShift && !wasFnShift {
                isActive = true
                activeMode = .literal
                DispatchQueue.main.async { [weak self] in
                    self?.onActivate(.literal)
                }
            } else if isFnControl && !wasFnControl {
                isActive = true
                activeMode = .formal
                DispatchQueue.main.async { [weak self] in
                    self?.onActivate(.formal)
                }
            } else if isFnCommand && !wasFnCommand && isCustomModeAvailable() {
                isActive = true
                activeMode = .custom
                DispatchQueue.main.async { [weak self] in
                    self?.onActivate(.custom)
                }
            }
        }
        // Release (either key of the combo released)
        else {
            switch activeMode {
            case .literal:
                if !isFnShift {
                    fireRelease()
                }
            case .formal:
                if !isFnControl {
                    fireRelease()
                }
            case .custom:
                if !isFnCommand {
                    fireRelease()
                }
            case .none:
                break
            }
        }
    }

    private func fireRelease() {
        isActive = false
        activeMode = nil
        DispatchQueue.main.async { [weak self] in
            self?.onRelease()
        }
    }
}

/// C-compatible callback for CGEvent tap.
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .flagsChanged, let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    let flags = event.flags

    manager.handleFlagsChanged(flags)

    return Unmanaged.passRetained(event)
}
