// draws App/Assets.xcassets/AppIcon.appiconset/icon.png: a phone outline with a tap ripple
import AppKit

let s: CGFloat = 1024
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// warm black, not blue-black
ctx.setFillColor(NSColor(srgbRed: 0.07, green: 0.07, blue: 0.065, alpha: 1).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

// phone body
let phone = CGRect(x: 337, y: 182, width: 350, height: 660)
ctx.setStrokeColor(NSColor(white: 0.93, alpha: 1).cgColor)
ctx.setLineWidth(30)
ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 78, cornerHeight: 78, transform: nil))
ctx.strokePath()

// island
ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
ctx.addPath(CGPath(roundedRect: CGRect(x: 462, y: 770, width: 100, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
ctx.fillPath()

// tap: dot + two rings, a bit below center
let c = CGPoint(x: 512, y: 430)
let blue = NSColor(srgbRed: 0.2, green: 0.52, blue: 1, alpha: 1)
ctx.setFillColor(blue.cgColor)
ctx.fillEllipse(in: CGRect(x: c.x - 44, y: c.y - 44, width: 88, height: 88))
for (r, a) in [(86.0, 0.55), (126.0, 0.25)] {
    ctx.setStrokeColor(blue.withAlphaComponent(a).cgColor)
    ctx.setLineWidth(14)
    ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}
img.unlockFocus()

let rep = NSBitmapImageRep(cgImage: img.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
