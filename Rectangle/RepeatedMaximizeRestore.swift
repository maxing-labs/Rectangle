//
//  RepeatedMaximizeRestore.swift
//  Rectangle
//

import Foundation

/// Opt-in (`repeatedMaximizeRestoresPrevious`): executing Maximize or Almost Maximize on a window that
/// Rectangle has just put in that state restores the frame the window had right before, instead of
/// doing nothing.
enum RepeatedMaximizeRestore {
    
    static func applies(to action: WindowAction) -> Bool {
        action == .maximize || action == .almostMaximize
    }
    
    /// The frame to restore instead of executing `action`, or nil to execute it normally.
    ///
    /// Restores only when `action` is the action that last positioned the window, the window
    /// has not been moved since, and a pre-maximize frame was recorded for it.
    static func restoreRect(for action: WindowAction,
                            windowRect: CGRect,
                            lastAction: RectangleAction?,
                            preMaximizeRect: CGRect?) -> CGRect? {
        guard Defaults.repeatedMaximizeRestoresPrevious.enabled,
              applies(to: action),
              let lastAction,
              lastAction.action == action,
              lastAction.rect == windowRect,
              let preMaximizeRect
        else { return nil }
        return preMaximizeRect
    }
    
    static func restoreRect(for action: WindowAction, windowId: CGWindowID, windowRect: CGRect) -> CGRect? {
        restoreRect(for: action,
                    windowRect: windowRect,
                    lastAction: AppDelegate.windowHistory.lastRectangleActions[windowId],
                    preMaximizeRect: AppDelegate.windowHistory.preMaximizeRects[windowId])
    }
}
