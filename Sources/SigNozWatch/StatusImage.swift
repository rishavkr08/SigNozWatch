import AppKit

/// The whole menu bar label as one image: a coloured dot plus "count of unhealthy servers".
/// MenuBarExtra shows either an image or text for a custom (non-template) icon, never both,
/// so the text is drawn into the image. The drawing block runs at draw time, so `labelColor`
/// resolves against the menu bar's own light or dark appearance.
func statusImage(dot: NSColor, text: String) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    let textSize = str.size()
    let dotSize: CGFloat = 9, gap: CGFloat = 5, height: CGFloat = 18
    let size = NSSize(width: dotSize + gap + ceil(textSize.width), height: height)
    let img = NSImage(size: size, flipped: false) { _ in
        dot.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: (height - dotSize) / 2, width: dotSize, height: dotSize)).fill()
        str.draw(at: NSPoint(x: dotSize + gap, y: (height - textSize.height) / 2))
        return true
    }
    img.isTemplate = false
    return img
}
