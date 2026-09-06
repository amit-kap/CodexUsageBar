import AppKit

/// Builds the compact capacity meter shown beside the menu-bar percentage.
///
/// It is a template image, so AppKit supplies the appropriate menu-bar colour
/// in light and dark appearances. The vector drawing stays sharp at 1x and Retina
/// scales and does not depend on a bitmap asset.
@MainActor
func usageMeterIcon(
    usedPercent: Double?,
    showingRemaining: Bool,
    stale: Bool
) -> NSImage {
    let canvas = NSSize(width: 20, height: 18)
    let image = NSImage(size: canvas)
    image.lockFocus()
    defer { image.unlockFocus() }

    // Keep the indicator legible when the service reports a malformed value.
    let used = usedPercent.map { min(100, max(0, $0)) }
    let displayedPercent = used.map { showingRemaining ? 100 - $0 : $0 }

    // A thin, pure rounded rectangle keeps the meter visually quieter than an icon.
    // Half-point placement produces a clean one-point outline at 1x and 2x.
    let bodyRect = NSRect(x: 2, y: 6.5, width: 16, height: 5)
    let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 1, yRadius: 1)
    bodyPath.lineWidth = 1
    NSColor.white.setStroke() // Template pixels are recoloured by AppKit.
    bodyPath.stroke()

    let fillRect = bodyRect.insetBy(dx: 1, dy: 1)
    let clippedInterior = NSBezierPath(roundedRect: fillRect, xRadius: 0.5, yRadius: 0.5)

    if let displayedPercent {
        // A sliver at nonzero values prevents a live reading from looking blank.
        let fraction = CGFloat(displayedPercent / 100)
        let width = fraction > 0 ? max(1, fillRect.width * fraction) : 0
        NSGraphicsContext.saveGraphicsState()
        clippedInterior.addClip()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: fillRect.minX, y: fillRect.minY, width: width, height: fillRect.height)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    if stale {
        // A diagonal interruption signals old data without adding a warning colour.
        let staleMark = NSBezierPath()
        staleMark.move(to: NSPoint(x: 8.75, y: 6))
        staleMark.line(to: NSPoint(x: 11.25, y: 12))
        staleMark.lineWidth = 1
        NSColor.white.setStroke()
        staleMark.stroke()
    }

    image.isTemplate = true
    image.accessibilityDescription = stale ? "Codex usage meter, stale" : "Codex usage meter"
    return image
}

/// Temporary compatibility wrapper for callers that used the original name.
@MainActor
func usageGaugeIcon(
    usedPercent: Double?,
    showingRemaining: Bool,
    stale: Bool
) -> NSImage {
    usageMeterIcon(usedPercent: usedPercent, showingRemaining: showingRemaining, stale: stale)
}
