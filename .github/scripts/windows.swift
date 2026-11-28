// Steam probe helper (macOS).
//   windows                    Lists the windows of Wine programs (owner name ends in .exe, or wine*) with
//                              their position, size, alpha and whether they are on screen. An off-screen or
//                              transparent window does not show up in a screenshot.
//   windows --lit PNG TITLE    Prints how much of the newest on-screen window called TITLE is not black in
//                              the screenshot PNG ("lit 37.2% of 700x440 at 162,147"), or "no window".
// Window titles need the screen-recording permission, so they may be empty.
import CoreGraphics
import Foundation
import ImageIO

struct Win { var owner: String, name: String, rect: CGRect, layer: Int, alpha: Double, onscreen: Bool }

func wineWindows() -> [Win] {
    let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return all.compactMap { w in
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let o = owner.lowercased()
        guard o.hasSuffix(".exe") || o.hasPrefix("wine") else { return nil }
        var rect = CGRect.zero
        if let b = w[kCGWindowBounds as String] as? NSDictionary { rect = CGRect(dictionaryRepresentation: b as CFDictionary) ?? .zero }
        return Win(owner: owner, name: w[kCGWindowName as String] as? String ?? "", rect: rect,
                   layer: (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                   alpha: (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                   onscreen: (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
    }
}

let args = CommandLine.arguments
if args.count == 4, args[1] == "--lit" {
    guard let win = wineWindows().first(where: { $0.onscreen && $0.name == args[3] && $0.rect.width > 0 }) else {
        print("no window"); exit(0)
    }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("no screenshot"); exit(0) }
    // Screenshot pixels per point (Retina screens capture at 2x).
    let scale = CGFloat(img.width) / CGDisplayBounds(CGMainDisplayID()).width
    let r = CGRect(x: win.rect.minX * scale, y: win.rect.minY * scale, width: win.rect.width * scale, height: win.rect.height * scale).integral
    guard let crop = img.cropping(to: r) else { print("no pixels"); exit(0) }
    let w = crop.width, h = crop.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        ctx?.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var lit = 0
    for i in stride(from: 0, to: px.count, by: 4) {
        let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
        if r + g + b > 24 { lit += 1 }
    }
    let percent: Double = 100 * Double(lit) / Double(max(1, w * h))
    let size = "\(Int(win.rect.width))x\(Int(win.rect.height)) at \(Int(win.rect.minX)),\(Int(win.rect.minY))"
    print(String(format: "lit %.1f%% of ", percent) + size)
    exit(0)
}
for w in wineWindows() {
    print("\(w.owner)\t\"\(w.name)\"\tx=\(Int(w.rect.minX)) y=\(Int(w.rect.minY)) \(Int(w.rect.width))x\(Int(w.rect.height))\tlayer=\(w.layer) alpha=\(w.alpha)\(w.onscreen ? " onscreen" : "")")
}
