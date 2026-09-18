// macspanso/Views/MatchManagerWindow.swift
import AppKit
import SwiftUI

final class MatchManagerWindowController: NSWindowController, NSWindowDelegate {
    private let store: EspansoConfigStore
    private let processManager: EspansoProcessManager

    /// Frames persist under "NSWindow Frame MatchManagerWindow_v2".
    /// Bumped from "MatchManagerWindow" because that key contained a stale
    /// minimum-size frame (640×520) that had never been updated after the
    /// panel's implicit autosave stopped writing — see the delegate-based
    /// saving below. Once users open the v2 window this key is discarded.
    static let autosaveName: NSWindow.FrameAutosaveName = "MatchManagerWindow_v2"
    static let legacyAutosaveName: NSWindow.FrameAutosaveName = "MatchManagerWindow"

    init(store: EspansoConfigStore, processManager: EspansoProcessManager) {
        self.store = store
        self.processManager = processManager

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 850),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "macspanso"
        panel.minSize = NSSize(width: 640, height: 520)
        if !panel.setFrameUsingName(Self.autosaveName) {
            panel.center()
        }
        let registered = panel.setFrameAutosaveName(Self.autosaveName)
        if !registered {
            NSLog("macspanso: setFrameAutosaveName(\(Self.autosaveName)) failed")
        }
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior.insert(.moveToActiveSpace)
        // NSPanel defaults to hiding when the app deactivates — wrong for a
        // main editing window; users expect it to stay put when they switch apps.
        panel.hidesOnDeactivate = false

        // Use NSHostingController (not NSHostingView) so SwiftUI gets full responder-chain
        // integration, keyboard focus cycles, and scene-environment setup.
        let rootView = MatchManagerView(store: store, processManager: processManager)
        let hc = NSHostingController(rootView: rootView)
        hc.sizingOptions = []
        // sizingOptions is the empty set on purpose: any option that reports the
        // content's size lets the hosting controller resize the window down to
        // the SwiftUI content's fitting size (the HSplitView minimums sum to
        // ~681×562, clamped to minSize 640×520 shortly after). Observed live:
        // the window ended at exactly that fitting size and that state was
        // persisted — the "window never remembers" bug.
        let intendedFrame = panel.frame
        panel.contentViewController = hc
        // Attaching the content view can trigger a hosting-layout pass that
        // resizes the window to the content's fitting size. Re-assert the frame
        // we meant to have — the autosaved frame, or the 1300×850 default.
        if panel.frame != intendedFrame {
            panel.setFrame(intendedFrame, display: false)
        }

        super.init(window: panel)

        // The panel's implicit autosave historically stopped writing frame
        // updates (the stored frame froze at one old value). Save explicitly on
        // move, resize end, and close so persistence does not depend on AppKit's
        // close-time flush — which MenuBarController's willClose handler can
        // race by tearing the window controller down first.
        panel.delegate = self

        // Purge the stale pre-v2 frame (a frozen minimum-size rectangle) if a
        // long-time user has it; a no-op when the key doesn't exist.
        NSWindow.removeFrame(usingName: Self.legacyAutosaveName)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: NSWindowDelegate — explicit frame persistence

    private func saveCurrentFrame() {
        guard let window,
              !window.styleMask.contains(.fullScreen),
              !window.isMiniaturized,
              window.frame.width > 0,
              window.frame.height > 0 else { return }
        window.saveFrame(usingName: Self.autosaveName)
    }

    func windowDidMove(_ notification: Notification) {
        saveCurrentFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveCurrentFrame()
    }

    func windowWillClose(_ notification: Notification) {
        saveCurrentFrame()
    }

    enum WindowPlacement: Equatable { case keep, recenter }

    /// Decide whether a window at `frame` is reachable on the current displays,
    /// or should be recentered. Pure so it can be unit-tested without real
    /// screens.
    ///
    /// `frame.intersects(screen)` is too weak: it's true for even a 1px overlap,
    /// so a window left straddling a screen edge after undocking passes it and
    /// gets ordered front effectively off-screen. Instead we require at least
    /// `minVisibleFraction` of the window's area to fall within a single screen's
    /// visible frame; otherwise the user can't reach it and we recenter.
    static func placement(forFrame frame: CGRect,
                          visibleFrames: [CGRect],
                          minVisibleFraction: CGFloat = 0.5) -> WindowPlacement {
        let windowArea = frame.width * frame.height
        guard windowArea > 0 else { return .recenter }
        let bestOverlapArea = visibleFrames.reduce(CGFloat(0)) { best, screen in
            let overlap = screen.intersection(frame)
            guard !overlap.isNull else { return best }
            return max(best, overlap.width * overlap.height)
        }
        return bestOverlapArea >= windowArea * minVisibleFraction ? .keep : .recenter
    }

    func focusNewMatch() {
        postDelayed(.focusNewMatch)
    }

    func focusAbout() {
        postDelayed(.focusAbout)
    }

    /// Delays one run-loop cycle so SwiftUI has rendered MatchManagerView
    /// and wired up its .onReceive subscribers before the notification fires.
    private func postDelayed(_ name: Notification.Name) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }
}

extension Notification.Name {
    static let focusNewMatch = Notification.Name("com.macspanso.focusNewMatch")
    static let focusAbout    = Notification.Name("com.macspanso.focusAbout")
}
