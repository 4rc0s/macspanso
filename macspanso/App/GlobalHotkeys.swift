// macspanso/App/GlobalHotkeys.swift
import AppKit
import Carbon.HIToolbox

/// Registers the app's system-wide hotkeys via the Carbon `RegisterEventHotKey`
/// API, which needs no Accessibility or Input Monitoring permission:
///
///   ⌃⇧M — open the Match Manager
///   ⌃⇧N — open the Match Manager on a new-match draft
///
/// The combos sit beside espanso's own ⌃⇧Space without colliding with system
/// or common app shortcuts. A registration consumes the combo system-wide for
/// as long as macspanso runs; if another app claims the same combo, whichever
/// registered last wins.
///
/// The controller lives as long as the menu bar controller, so no uninstall
/// path is needed.
@MainActor
final class GlobalHotkeyController {
    enum Action: UInt32 {
        case openManager = 1
        case newMatch = 2
    }

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actions: [Action: () -> Void] = [:]

    func install(onOpenManager: @escaping () -> Void,
                 onNewMatch: @escaping () -> Void) {
        actions = [.openManager: onOpenManager, .newMatch: onNewMatch]

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventCallback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef)
        guard status == noErr else {
            NSLog("GlobalHotkeys: InstallEventHandler failed (%d)", status)
            return
        }

        let modifiers = UInt32(controlKey | shiftKey)
        for (action, keyCode) in [(Action.openManager, UInt32(kVK_ANSI_M)),
                                  (Action.newMatch,  UInt32(kVK_ANSI_N))] {
            if let ref = register(action: action, keyCode: keyCode, modifiers: modifiers) {
                hotKeyRefs.append(ref)
            }
        }
    }

    private func register(action: Action, keyCode: UInt32,
                          modifiers: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        var hotKeyID = EventHotKeyID(signature: 0x4D53_5053 /* 'MSPS' */, id: action.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("GlobalHotkeys: RegisterEventHotKey failed for \(action) (%d)", status)
        }
        return status == noErr ? ref : nil
    }

    /// C callback — no captures allowed. Carbon delivers hotkey presses on the
    /// main thread; hop into the MainActor before touching controller state.
    private static let eventCallback: EventHandlerUPP = { _, event, userData in
        guard let userData else { return noErr }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID)
        guard status == noErr else { return noErr }

        let controller = Unmanaged<GlobalHotkeyController>
            .fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
            controller.dispatch(hotKeyID.id)
        }
        return noErr
    }

    private func dispatch(_ id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        actions[action]?()
    }
}
