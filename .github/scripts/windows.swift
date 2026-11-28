// Lists the windows of Wine programs (owner name ends in .exe, or wine*) with their position, size,
// layer, alpha and whether they are on screen. Used by the Steam probe next to its screenshots:
// a window that exists but is off screen, or fully transparent, does not show up in a screenshot.
// Window titles need the screen-recording permission, so they may be empty.
import CoreGraphics
import Foundation

let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in all {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let o = owner.lowercased()
    guard o.hasSuffix(".exe") || o.hasPrefix("wine") else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let n = { (k: String) in (b[k] as? NSNumber)?.intValue ?? 0 }
    let name = w[kCGWindowName as String] as? String ?? ""
    let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    let onscreen = (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    print("\(owner)\t\"\(name)\"\tx=\(n("X")) y=\(n("Y")) \(n("Width"))x\(n("Height"))\tlayer=\(layer) alpha=\(alpha)\(onscreen ? " onscreen" : "")")
}
