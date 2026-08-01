import CoreGraphics
import Foundation

/// Which side of the Mac’s main display to park the virtual screen on
/// when a session starts (or restarts). Users can still fine-tune in
/// System Settings → Displays; the next connect re-applies this preference.
enum DisplaySide: String, CaseIterable {
    case left
    case right

    var label: String {
        switch self {
        case .left: return "Left of Mac"
        case .right: return "Right of Mac"
        }
    }

    var shortLabel: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// Places each device's virtual display relative to the main Mac screen.
///
/// macOS does persist display arrangement, but keys it on the monitor
/// identity (vendor/product/serial) — and ours legitimately changes: each
/// orientation uses a distinct serial (saved-mode separation, see
/// setupExtend), and the serial also derives from the session id, so USB
/// and WiFi produce different identities for the same device. Every such
/// change makes macOS treat the display as a brand-new monitor and park it
/// at a default position. We therefore force placement from the user’s
/// Left/Right preference (and still remember drag adjustments for the
/// short restore window while the display settles).
enum DisplayArrangement {

    private static let sideKey = "displaySide"

    /// Global preference: place extended screens left or right of the Mac.
    static var preferredSide: DisplaySide {
        get {
            DisplaySide(rawValue: UserDefaults.standard.string(forKey: sideKey) ?? "") ?? .left
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: sideKey)
        }
    }

    /// Origin for a new virtual display of `size` points, on the preferred
    /// side of the main display (vertically centered). WindowServer may snap
    /// the final position to a valid adjacent arrangement.
    static func origin(for size: CGSize, device: String) -> CGPoint? {
        // Prefer the explicit Left/Right setting so orientation / transport
        // identity churn doesn’t shuffle the phone to a random corner.
        // Per-device drag memory still records via `save` for diagnostics
        // and a future “remember last” mode, but does not override the setting.
        _ = device
        return sideOrigin(preferredSide, size: size)
    }

    /// Point-origin so the virtual display sits flush against the main
    /// screen on `side`. Vertically center against the main display so the
    /// shared edge is as long as possible — tops-only alignment leaves a
    /// dead zone at the bottom of a tall Mac where drag-to-edge fails.
    static func sideOrigin(_ side: DisplaySide, size: CGSize) -> CGPoint {
        let main = CGDisplayBounds(CGMainDisplayID())
        let y = main.minY + max(0, (main.height - size.height) / 2)
        switch side {
        case .right:
            return CGPoint(x: main.maxX, y: y)
        case .left:
            return CGPoint(x: main.minX - size.width, y: y)
        }
    }

    /// Record the origin (global desktop points) the display settled at.
    /// Kept so a future “remember last drag” option can restore it; the
    /// active Left/Right setting wins on the next connect today.
    static func save(origin: CGPoint, size: CGSize, device: String) {
        UserDefaults.standard.set([Int(origin.x), Int(origin.y), Int(size.width), Int(size.height)],
                                  forKey: key(device))
    }

    private static func key(_ device: String) -> String { "displayOrigin.\(device)" }
}
