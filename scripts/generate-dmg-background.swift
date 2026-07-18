#!/usr/bin/env swift
import AppKit

// Renders the DMG installer window background: a transparent canvas
// with an arrow from the app icon position to the Applications-folder
// position and a one-line drag hint, so Finder's own light or dark
// window shows through (Finder composites the picture over a white
// canvas regardless of appearance). The glyphs are mid-gray with a thin
// dark outline and a soft white halo, so they stay legible and survive
// any change to how Finder composites the picture. Emits a two-page
// HiDPI TIFF (1x + 2x via tiffutil) so Finder draws it crisply on
// Retina displays. Positions must match the --icon/--app-drop-link
// coordinates in package-dmg.sh.

func usage() {
    print("""
    Generate the DMG installer background (HiDPI TIFF).

    Usage: swift scripts/generate-dmg-background.swift [--output <path>]

    Flags:
      --output    Path of the .tiff to write (default: Resources/dmg-background.tiff)
      -h, --help  Show this help.
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var output = "Resources/dmg-background.tiff"

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--output":
        guard !args.isEmpty else { fail("Missing value for --output") }
        output = args.removeFirst()
    case "-h", "--help":
        usage()
        exit(0)
    default:
        fail("Unknown argument: \(arg)")
    }
}

// Window content size in points; the icon row and arrow sit on one line.
let size = NSSize(width: 660, height: 400)
let appIconCenter = NSPoint(x: 165, y: 215)    // bottom-left origin
let dropLinkCenter = NSPoint(x: 495, y: 215)
let iconHalf: CGFloat = 64

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let pixelsWide = Int(size.width * scale)
    let pixelsHigh = Int(size.height * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fail("Could not create bitmap at scale \(scale)") }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let fill = NSColor(white: 0.5, alpha: 1)
    let outline = NSColor(white: 0, alpha: 0.4)
    let halo = NSShadow()
    halo.shadowColor = NSColor(white: 1, alpha: 0.85)
    halo.shadowBlurRadius = 3
    halo.shadowOffset = .zero

    // One closed path for the whole arrow so outline and halo wrap it as
    // a single shape, clear of both 128pt icons.
    let start = NSPoint(x: appIconCenter.x + iconHalf + 24, y: appIconCenter.y)
    let end = NSPoint(x: dropLinkCenter.x - iconHalf - 24, y: dropLinkCenter.y)
    let half: CGFloat = 2.5
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: start.x, y: start.y + half))
    arrow.line(to: NSPoint(x: end.x - 22, y: end.y + half))
    arrow.line(to: NSPoint(x: end.x - 22, y: end.y + 13))
    arrow.line(to: end)
    arrow.line(to: NSPoint(x: end.x - 22, y: end.y - 13))
    arrow.line(to: NSPoint(x: end.x - 22, y: end.y - half))
    arrow.line(to: NSPoint(x: start.x, y: start.y - half))
    arrow.close()

    NSGraphicsContext.current?.saveGraphicsState()
    halo.set()
    fill.setFill()
    arrow.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    outline.setStroke()
    arrow.lineWidth = 1
    arrow.stroke()

    let hint = "Drag MicGuard into Applications"
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
        .foregroundColor: fill,
        // Negative width strokes AND fills; the outline is what keeps
        // the text readable over a light window.
        .strokeWidth: -1.5,
        .strokeColor: outline,
        .shadow: halo,
    ]
    let text = NSAttributedString(string: hint, attributes: attributes)
    let textSize = text.size()
    text.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: 92))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let temp = FileManager.default.temporaryDirectory
    .appendingPathComponent("micguard-dmg-bg-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }

var pngPaths: [String] = []
for scale: CGFloat in [1, 2] {
    let rep = draw(scale: scale)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fail("PNG encoding failed at scale \(scale)")
    }
    let path = temp.appendingPathComponent(scale == 1 ? "bg.png" : "bg@2x.png").path
    try! png.write(to: URL(fileURLWithPath: path))
    pngPaths.append(path)
}

// tiffutil pairs the two representations and marks them 1x/2x; Finder
// picks per display.
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck"] + pngPaths + ["-out", output]
try! tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else { fail("tiffutil failed") }
print("Wrote \(output)")
