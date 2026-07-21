import AppKit

/// Resizer launches as an accessory (menu-bar-only) app, so it stays out of the
/// Dock. The tradeoff is that accessory apps' windows don't show in ⌘-Tab or
/// Mission Control. To fix that we switch to a regular activation policy while
/// any window is open — so the windows behave like a normal app's — and drop
/// back to accessory once they all close, keeping the menu-bar-only footprint
/// at rest.
///
/// Every window controller calls `windowOpened()` when it shows a window and
/// `windowClosed()` from `windowWillClose`.
enum AppActivation {
    private static var openWindows = 0

    static func windowOpened() {
        openWindows += 1
        if openWindows == 1 {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func windowClosed() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
