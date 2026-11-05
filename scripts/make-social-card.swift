// Draws the link preview image for the website (1200×630, as LinkedIn and others show it),
// in the site's look. The fonts are Martian Mono instances from Google Fonts (OFL): bold at
// 112.5% width for the headline, medium at 87.5% for the small print. Without them it falls
// back to the system monospaced font.
// Usage: swiftc -O scripts/make-social-card.swift -o build/make-social-card &&
//        build/make-social-card docs/logo.png site/social-card.png [headline.ttf small.ttf]
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 3, let logo = NSImage(contentsOfFile: arguments[1]) else {
    print("Usage: make-social-card <logo.png> <output.png> [headline.ttf small.ttf]")
    exit(1)
}
let width = 1_200, height = 630

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let ink = rgb(0x0A1322), rule = rgb(0x22344F), text = rgb(0xDDE7F6), dim = rgb(0x8C9DBA)
let lens = rgb(0xFF9F45), led = rgb(0x3DDC97)

func font(_ index: Int, size: CGFloat, fallback weight: NSFont.Weight) -> NSFont {
    if arguments.count > index,
       let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: arguments[index]) as CFURL) as? [CTFontDescriptor],
       let descriptor = descriptors.first {
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

ink.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
// The site's 32px grid, fading out toward the bottom.
for x in stride(from: 0, through: width, by: 32) {
    NSGradient(starting: rule.withAlphaComponent(0.5), ending: rule.withAlphaComponent(0))!
        .draw(in: NSRect(x: x, y: 0, width: 1, height: height), angle: -90)
}
for y in stride(from: 0, through: height, by: 32) {
    rule.withAlphaComponent(0.5 * CGFloat(y) / CGFloat(height)).setFill()
    NSRect(x: 0, y: y, width: width, height: 1).fill()
}

func draw(_ string: String, _ font: NSFont, _ color: NSColor, at point: NSPoint, kern: CGFloat = 0) {
    NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: kern]).draw(at: point)
}
let small = font(4, size: 22, fallback: .medium)
let headline = font(3, size: 64, fallback: .bold)

// Status line with the drive LED.
led.setFill()
NSBezierPath(ovalIn: NSRect(x: 80, y: 522, width: 12, height: 12)).fill()
draw("smb://fileserver/Projects · indexed · searchable offline", small, dim, at: NSPoint(x: 106, y: 515))

draw("Find any file", headline, text, at: NSPoint(x: 76, y: 400), kern: -3)
draw("on the server", headline, text, at: NSPoint(x: 76, y: 322), kern: -3)
draw("before Finder", headline, lens, at: NSPoint(x: 76, y: 244), kern: -3)
draw("stops spinning.", headline, lens, at: NSPoint(x: 76, y: 166), kern: -3)

logo.draw(in: NSRect(x: 900, y: 290, width: 220, height: 220))

rule.setFill()
NSRect(x: 80, y: 112, width: width - 160, height: 1).fill()
draw("ServerFinder · free, open source", small, text, at: NSPoint(x: 80, y: 62))
let address = "ulloa09.github.io/ServerFinder"
let addressWidth = NSAttributedString(string: address, attributes: [.font: small]).size().width
draw(address, small, dim, at: NSPoint(x: CGFloat(width) - 80 - addressWidth, y: 62))

NSGraphicsContext.current = nil
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
