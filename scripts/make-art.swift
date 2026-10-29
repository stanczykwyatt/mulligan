// Draws the icon (docs/icon.png), the README demo (docs/demo.gif) and the link preview image
// (docs/social.png). Everything is drawn here rather than recorded, so the art never shows
// anyone's real terminal or code. The project, files and session are all made up.
//
//   swift scripts/make-art.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let slate = NSColor(srgbRed: 0.13, green: 0.17, blue: 0.27, alpha: 1)
let ice = NSColor(srgbRed: 0.62, green: 0.82, blue: 1.0, alpha: 1)
let ink = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.07, alpha: 1)

func bitmap(_ width: Int, _ height: Int, draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Cool silver light on a dark wallpaper, like the other apps' art.
func wallpaper(_ rect: NSRect) {
    NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.09, blue: 0.13, alpha: 1), ending: ink)!.draw(in: rect, angle: -90)
    let glows: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
        (0.16, 0.78, 0.42, NSColor(srgbRed: 0.84, green: 0.89, blue: 0.95, alpha: 0.42)),
        (0.86, 0.74, 0.38, NSColor(srgbRed: 0.59, green: 0.68, blue: 0.81, alpha: 0.38)),
        (0.72, 0.10, 0.46, NSColor(srgbRed: 0.75, green: 0.81, blue: 0.89, alpha: 0.30)),
        (0.20, 0.14, 0.30, NSColor(srgbRed: 0.44, green: 0.53, blue: 0.65, alpha: 0.30)),
    ]
    for (x, y, r, color) in glows {
        let center = NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        NSGradient(starting: color, ending: color.withAlphaComponent(0))!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: rect.width * r, options: [])
    }
}

// MARK: - Icon

/// The icon on a 1024-point canvas: the slate tile, a terminal window, and an ice-blue arrow
/// curling back over it.
func drawIcon(in rect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: rect.minX, yBy: rect.minY)
    transform.scale(by: rect.width / 1024)
    transform.concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = .black.withAlphaComponent(0.3)
    tileShadow.shadowBlurRadius = 24
    tileShadow.shadowOffset = NSSize(width: 0, height: -12)
    tileShadow.set()
    slate.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(srgbRed: 0.80, green: 0.87, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.57, blue: 0.75, alpha: 1),
        slate,
    ])!.draw(in: tile, angle: -90)

    // The terminal: a white sheet with a slate prompt.
    let window = NSBezierPath(roundedRect: NSRect(x: 212, y: 206, width: 600, height: 430), xRadius: 54, yRadius: 54)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.withAlphaComponent(0.96).setFill()
    window.fill()
    NSGraphicsContext.restoreGraphicsState()

    slate.setStroke()
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 300, y: 512))
    chevron.line(to: NSPoint(x: 384, y: 440))
    chevron.line(to: NSPoint(x: 300, y: 368))
    chevron.lineWidth = 44
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.stroke()
    slate.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: 436, y: 346, width: 170, height: 44), xRadius: 22, yRadius: 22).fill()

    // The undo arrow: comes from the right, curls over the top and points back left.
    let arc = NSBezierPath()
    arc.move(to: NSPoint(x: 760, y: 560))
    arc.curve(to: NSPoint(x: 560, y: 790), controlPoint1: NSPoint(x: 780, y: 700), controlPoint2: NSPoint(x: 690, y: 790))
    arc.line(to: NSPoint(x: 400, y: 790))
    arc.lineWidth = 58
    arc.lineCapStyle = .round
    arc.lineJoinStyle = .round
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 400, y: 900))
    head.line(to: NSPoint(x: 400, y: 680))
    head.line(to: NSPoint(x: 262, y: 790))
    head.close()
    head.lineWidth = 30
    head.lineJoinStyle = .round
    // A slate shadow first, so the arrow stands out against the pale top of the tile.
    NSGraphicsContext.saveGraphicsState()
    let depth = NSShadow()
    depth.shadowColor = slate.withAlphaComponent(0.55)
    depth.shadowBlurRadius = 18
    depth.shadowOffset = NSSize(width: 0, height: -10)
    depth.set()
    ice.setStroke()
    ice.setFill()
    arc.stroke()
    head.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = ice.withAlphaComponent(0.8)
    glow.shadowBlurRadius = 36
    glow.set()
    NSColor(srgbRed: 0.42, green: 0.66, blue: 0.95, alpha: 1).setStroke()
    NSColor(srgbRed: 0.42, green: 0.66, blue: 0.95, alpha: 1).setFill()
    arc.stroke()
    head.fill()
    head.stroke()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
}

func png(_ rep: NSBitmapImageRep, _ path: String) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}

// MARK: - Terminal

struct Run {
    var text: String
    var color: NSColor = NSColor(white: 0.86, alpha: 1)
    var bold = false
}

let plain = NSColor(white: 0.86, alpha: 1)
let dim = NSColor(white: 0.52, alpha: 1)
let green = NSColor(srgbRed: 0.45, green: 0.84, blue: 0.55, alpha: 1)
let yellow = NSColor(srgbRed: 0.94, green: 0.80, blue: 0.42, alpha: 1)
let red = NSColor(srgbRed: 0.96, green: 0.48, blue: 0.48, alpha: 1)
let prompt = Run(text: "~/code/weather-app ", color: ice)

func r(_ text: String, _ color: NSColor = plain, bold: Bool = false) -> Run { Run(text: text, color: color, bold: bold) }

/// One line of the session: either typed (shown a few characters at a time) or printed.
enum Step {
    case type([Run], String, hold: Double)
    case print([[Run]], hold: Double)
}

let session: [Step] = [
    .type([prompt, r("$ ", dim)], "codex \"add a 7-day forecast, and tidy up\"", hold: 0.4),
    .print([
        [r("  edited  ", dim), r("src/forecast.ts")],
        [r("  ran     ", dim), r("npm run format")],
        [r("  ran     ", dim), r("rm -rf src/legacy")],
        [r("  done. ", dim), r("(…and the formatter rewrote 23 files you didn't ask about)", dim)],
    ], hold: 1.6),
    .type([prompt, r("$ ", dim)], "mulligan list", hold: 0.3),
    .print([
        [r("weather-app", bold: true), r(" · 4 snapshots · ~/code/weather-app", dim)],
        [],
        [r("  #1", bold: true), r("  6 min ago  ", dim), r("codex  ", ice), r("prompt: “add a 7-day forecast, and tidy up”  "), r("+1 ~1", yellow)],
        [r("  #2", bold: true), r("  5 min ago  ", dim), r("codex  ", ice), r("before Bash: npm run format                  "), r("~23", yellow)],
        [r("  #3", bold: true), r("  4 min ago  ", dim), r("codex  ", ice), r("before Bash: rm -rf src/legacy               "), r("-6", red)],
        [r("  #4", bold: true), r("  3 min ago  ", dim), r("codex  ", ice), r("end of turn")],
        [],
        [r("  Your files match #4.", dim)],
    ], hold: 2.4),
    .type([prompt, r("$ ", dim)], "mulligan undo 2", hold: 0.3),
    .print([
        [r("Back to "), r("#2", bold: true), r(" (before Bash: npm run format, 5 min ago).", dim)],
        [r("29 files changed:")],
        [r("  ~ src/app.ts", yellow)],
        [r("  ~ src/api/client.ts", yellow)],
        [r("  + src/legacy/units.ts", green)],
        [r("  …and 26 more", dim)],
        [r("Your files from just before are in #4. `mulligan undo 4` goes back to them.", dim)],
    ], hold: 3.2),
]

let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
let lineHeight: CGFloat = 19

func draw(_ runs: [Run], at point: NSPoint) {
    var x = point.x
    for run in runs {
        let attributes: [NSAttributedString.Key: Any] = [.font: run.bold ? boldFont : font, .foregroundColor: run.color]
        (run.text as NSString).draw(at: NSPoint(x: x, y: point.y), withAttributes: attributes)
        x += (run.text as NSString).size(withAttributes: attributes).width
    }
}

/// A terminal window holding `lines`, the newest at the bottom when they don't all fit.
func terminal(_ frame: NSRect, lines: [[Run]], cursor: Bool) {
    let body = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 0.97).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.13).setStroke()
    body.lineWidth = 1
    body.stroke()
    for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: frame.minX + 16 + CGFloat(index) * 20, y: frame.maxY - 24, width: 12, height: 12)).fill()
    }
    let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: dim]
    let name = "weather-app — zsh" as NSString
    name.draw(at: NSPoint(x: frame.midX - name.size(withAttributes: title).width / 2, y: frame.maxY - 25), withAttributes: title)

    let fits = Int((frame.height - 56) / lineHeight)
    let shown = lines.suffix(fits)
    var y = frame.maxY - 56
    for (index, line) in shown.enumerated() {
        draw(line, at: NSPoint(x: frame.minX + 20, y: y))
        if cursor, index == shown.count - 1 {
            let width = line.reduce(CGFloat(0)) { $0 + ($1.text as NSString).size(withAttributes: [.font: $1.bold ? boldFont : font]).width }
            ice.withAlphaComponent(0.85).setFill()
            NSRect(x: frame.minX + 20 + width + 1, y: y - 2, width: 8, height: 16).fill()
        }
        y -= lineHeight
    }
}

// MARK: - Demo GIF

let size = NSSize(width: 880, height: 520)
var frames: [(NSBitmapImageRep, Double)] = []
var lines: [[Run]] = []

func frame(_ hold: Double, cursor: Bool) {
    let rep = bitmap(Int(size.width), Int(size.height)) {
        wallpaper(NSRect(origin: .zero, size: size))
        terminal(NSRect(x: 30, y: 28, width: size.width - 60, height: size.height - 56), lines: lines, cursor: cursor)
    }
    frames.append((rep, hold))
}

lines = [[prompt, r("$ ", dim)]]
frame(1.0, cursor: true)
for step in session {
    switch step {
    case .type(let head, let text, let hold):
        lines.removeLast()
        var typed = ""
        for character in text {
            typed.append(character)
            if typed.count % 3 == 0 || typed.count == text.count {
                lines.append(head + [r(typed)])
                frame(0.05, cursor: true)
                lines.removeLast()
            }
        }
        lines.append(head + [r(text)])
        frame(hold, cursor: false)
    case .print(let output, let hold):
        for line in output {
            lines.append(line)
            frame(0.08, cursor: false)
        }
        lines.append([prompt, r("$ ", dim)])
        frame(hold, cursor: true)
    }
}

let gifURL = URL(fileURLWithPath: "docs/demo.gif") as CFURL
let destination = CGImageDestinationCreateWithURL(gifURL, UTType.gif.identifier as CFString, frames.count, nil)!
CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (rep, delay) in frames {
    let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]]
    CGImageDestinationAddImage(destination, rep.cgImage!, properties as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write the GIF") }
print("Wrote docs/demo.gif (\(frames.count) frames)")

// MARK: - Icon and social image

try png(bitmap(256, 256) { drawIcon(in: NSRect(x: 0, y: 0, width: 256, height: 256)) }, "docs/icon.png")

let social = bitmap(1280, 640) {
    let rect = NSRect(x: 0, y: 0, width: 1280, height: 640)
    wallpaper(rect)
    drawIcon(in: NSRect(x: 70, y: 330, width: 200, height: 200))
    let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 74, weight: .semibold), .foregroundColor: NSColor.white]
    ("mulligan" as NSString).draw(at: NSPoint(x: 86, y: 220), withAttributes: title)
    let tagline: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.78)]
    ("Undo for coding agents." as NSString).draw(at: NSPoint(x: 90, y: 168), withAttributes: tagline)
    let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 17, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.5)]
    ("codex · claude code · gemini cli · opencode · aider · any agent" as NSString).draw(at: NSPoint(x: 92, y: 110), withAttributes: small)
    lines = [
        [prompt, r("$ ", dim), r("mulligan list")],
        [r("  #2", bold: true), r("  5 min ago  ", dim), r("before Bash: npm run format  "), r("~23", yellow)],
        [r("  #3", bold: true), r("  4 min ago  ", dim), r("before Bash: rm -rf src/legacy  "), r("-6", red)],
        [r("  #4", bold: true), r("  3 min ago  ", dim), r("end of turn")],
        [prompt, r("$ ", dim), r("mulligan undo 2")],
        [r("Back to "), r("#2", bold: true), r(". 29 files changed.", dim)],
        [prompt, r("$ ", dim)],
    ]
    terminal(NSRect(x: 640, y: 215, width: 580, height: 210), lines: lines, cursor: true)
}
try png(social, "docs/social.png")
