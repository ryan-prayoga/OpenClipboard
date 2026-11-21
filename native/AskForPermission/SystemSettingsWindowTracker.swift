// Adapted from AskForPermission's SystemSettings/SystemSettingsWindowTracker.swift (MIT).
// Upstream: https://github.com/riko2chen/AskForPermission/tree/91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e
import AppKit
import CoreGraphics

@MainActor
@objc(OCSystemSettingsWindowTracker)
public final class SystemSettingsWindowTracker: NSObject {
    private static var settingsPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .first?.processIdentifier
    }

    @objc public static func windowFrame() -> NSRect {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let pid = settingsPID, let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]]
        else { return .zero }

        // Pick the largest settings window so popovers don't win over the permission list.
        var largest = CGRect.zero
        for info in windows {
            guard info[kCGWindowOwnerPID] as? pid_t == pid,
                  info[kCGWindowLayer] as? Int == 0,
                  let bounds = info[kCGWindowBounds] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 300, frame.height >= 250
            else { continue }

            if frame.width * frame.height > largest.width * largest.height { largest = frame }
        }
        guard !largest.isEmpty else { return .zero }

        // The Window Server reports Y down from the main display; AppKit measures Y up.
        return NSRect(x: largest.minX, y: primary.frame.maxY - largest.maxY,
                      width: largest.width, height: largest.height)
    }

    @objc(isSettingsWindowAtPoint:)
    public static func isSettingsWindow(at point: NSPoint) -> Bool {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0, let id = CGWindowID(exactly: number), let pid = settingsPID,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[CFString: Any]]
        else { return false }
        return windows.first?[kCGWindowOwnerPID] as? pid_t == pid
    }
}
