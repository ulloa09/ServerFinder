// Draws the ServerFinder app icon: a stack of server drives with a magnifying glass.
// Usage: swiftc -O scripts/make-icon.swift -o build/make-icon && build/make-icon <variant> <output.png> [size]
import AppKit

let arguments = CommandLine.arguments
let variant = arguments.count > 1 ? arguments[1] : "blue"
let output = arguments.count > 2 ? arguments[2] : "icon.png"
let pixels = arguments.count > 3 ? Int(arguments[3])! : 1024

struct Palette {
    var backgroundTop: NSColor
    var backgroundBottom: NSColor
    var drive: NSColor
    var driveDetail: NSColor
    var light: NSColor
    var lens: NSColor
    var glass: NSColor
    var outlinedDrives = false
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let palettes: [String: Palette] = [
    "blue": Palette(backgroundTop: rgb(0x3B8BFF), backgroundBottom: rgb(0x1645B8),
                    drive: rgb(0xFFFFFF), driveDetail: rgb(0x9DB6DE), light: rgb(0x34D399),
                    lens: rgb(0x1E5BD6, 0.55), glass: rgb(0xFFFFFF)),
    "light": Palette(backgroundTop: rgb(0xFFFFFF), backgroundBottom: rgb(0xDCE3EE),
                     drive: rgb(0x2F6FEB), driveDetail: rgb(0x9EC1FF), light: rgb(0x34D399),
                     lens: rgb(0xFFFFFF, 0.6), glass: rgb(0x1B2A4A)),
    "dark": Palette(backgroundTop: rgb(0x26324A), backgroundBottom: rgb(0x0B1220),
                    drive: rgb(0x38BDF8), driveDetail: rgb(0x38BDF8, 0.55), light: rgb(0x4ADE80),
                    lens: rgb(0x0B1220, 0.55), glass: rgb(0xFB923C), outlinedDrives: true),
]
guard let palette = palettes[variant] else { fatalError("variant must be one of \(palettes.keys.sorted())") }

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
// Draw on Apple's 1024-point macOS icon grid, whatever the output size.
context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

// Rounded-square body (824 pt with the standard margin), with a soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
palette.backgroundBottom.setFill()
bodyPath.fill()
context.restoreGState()
context.saveGState()
bodyPath.addClip()
NSGradient(starting: palette.backgroundTop, ending: palette.backgroundBottom)!.draw(in: body, angle: -90)
context.restoreGState()

// Three server drives, stacked.
for (index, y) in [610.0, 470.0, 330.0].enumerated() {
    let drive = NSRect(x: 222, y: y, width: 470, height: 112)
    let path = NSBezierPath(roundedRect: drive, xRadius: 30, yRadius: 30)
    if palette.outlinedDrives {
        palette.drive.setStroke()
        path.lineWidth = 16
        path.stroke()
    } else {
        palette.drive.setFill()
        path.fill()
    }
    // Activity light: the top drive's is lit.
    (index == 0 ? palette.light : palette.driveDetail).setFill()
    NSBezierPath(ovalIn: NSRect(x: drive.minX + 46, y: drive.midY - 17, width: 34, height: 34)).fill()
    // Vent slots.
    palette.driveDetail.setFill()
    for slot in 0..<4 {
        let x = drive.maxX - 64 - CGFloat(slot) * 44
        NSBezierPath(roundedRect: NSRect(x: x, y: drive.midY - 26, width: 18, height: 52), xRadius: 9, yRadius: 9).fill()
    }
}

// Magnifying glass over the lower right.
let center = CGPoint(x: 660, y: 370)
let radius: CGFloat = 148
let angle = -CGFloat.pi / 4
let handleStart = CGPoint(x: center.x + (radius + 10) * cos(angle), y: center.y + (radius + 10) * sin(angle))
let handleEnd = CGPoint(x: center.x + (radius + 140) * cos(angle), y: center.y + (radius + 140) * sin(angle))
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: NSColor.black.withAlphaComponent(0.35).cgColor)
let handle = NSBezierPath()
handle.move(to: handleStart)
handle.line(to: handleEnd)
handle.lineWidth = 78
handle.lineCapStyle = .round
palette.glass.setStroke()
handle.stroke()
let lens = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
palette.lens.setFill()
lens.fill()
lens.lineWidth = 50
lens.stroke()
context.restoreGState()
// A glint on the lens.
let glint = NSBezierPath()
glint.appendArc(withCenter: center, radius: radius - 62, startAngle: 105, endAngle: 165)
glint.lineWidth = 22
glint.lineCapStyle = .round
palette.glass.withAlphaComponent(0.8).setStroke()
glint.stroke()

NSGraphicsContext.restoreGraphicsState()
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
