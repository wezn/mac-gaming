// Renders assets/icon.svg into an .iconset folder for iconutil. macOS only:
//   swift Scripts/render_icon.swift ../assets/icon.svg build/AppIcon.iconset
// NSImage reads SVG on macOS 14+; on older systems (or if it fails) the same design is drawn
// directly: a rounded magenta square with "MG".
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: render_icon.swift <icon.svg> <out.iconset>\n".utf8))
    exit(2)
}
let svg = NSImage(contentsOf: URL(fileURLWithPath: args[1]))
let out = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func drawFallback(in rect: NSRect) {
    // Mirrors icon.svg: 64×64 viewBox, rx 14, #c026d3, white semibold "MG" at 26.
    let s = rect.width / 64
    NSColor(srgbRed: 0xc0 / 255, green: 0x26 / 255, blue: 0xd3 / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 14 * s, yRadius: 14 * s).fill()
    let font = NSFont.systemFont(ofSize: 26 * s, weight: .semibold)
    let text = NSAttributedString(string: "MG", attributes: [.font: font, .foregroundColor: NSColor.white])
    let size = text.size()
    text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Apple's grid: the artwork fills ~80% of the canvas, centred.
    let inset = CGFloat(px) * 0.1
    let rect = NSRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
    if let svg, svg.isValid, svg.size.width > 0 {
        svg.draw(in: rect)
    } else {
        drawFallback(in: rect)
    }
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: out.appendingPathComponent(name))
}
print(svg?.isValid == true ? "rendered \(args[1])" : "drew the fallback icon (NSImage could not read \(args[1]))")
