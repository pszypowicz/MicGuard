import AppKit
import SwiftUI

enum MenuBarIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let w = rect.width
            let h = rect.height

            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()

            // Shield outline
            let shield = NSBezierPath()
            shield.move(to: NSPoint(x: w * 0.5, y: h))
            shield.line(to: NSPoint(x: w * 0.95, y: h * 0.82))
            shield.line(to: NSPoint(x: w * 0.95, y: h * 0.48))
            shield.curve(
                to: NSPoint(x: w * 0.5, y: 0),
                controlPoint: NSPoint(x: w * 0.95, y: h * 0.18))
            shield.curve(
                to: NSPoint(x: w * 0.05, y: h * 0.48),
                controlPoint: NSPoint(x: w * 0.05, y: h * 0.18))
            shield.line(to: NSPoint(x: w * 0.05, y: h * 0.82))
            shield.close()
            shield.lineWidth = 1.2
            shield.stroke()

            // Mic head (capsule)
            let micW = w * 0.22
            let micH = h * 0.24
            let micRect = NSRect(
                x: w / 2 - micW / 2,
                y: h * 0.54,
                width: micW,
                height: micH)
            NSBezierPath(roundedRect: micRect, xRadius: micW / 2, yRadius: micW / 2).fill()

            // Mic arc (cradle)
            let arcCenterY = micRect.minY - h * 0.02
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: NSPoint(x: w / 2, y: arcCenterY),
                radius: w * 0.16,
                startAngle: 0,
                endAngle: -180,
                clockwise: true)
            arc.lineWidth = 1.1
            arc.stroke()

            // Stem
            let stemTop = arcCenterY - w * 0.16
            let stemBottom = stemTop - h * 0.08
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: w / 2, y: stemTop))
            stem.line(to: NSPoint(x: w / 2, y: stemBottom))
            stem.lineWidth = 1.1
            stem.stroke()

            // Base
            let base = NSBezierPath()
            base.move(to: NSPoint(x: w * 0.36, y: stemBottom))
            base.line(to: NSPoint(x: w * 0.64, y: stemBottom))
            base.lineWidth = 1.1
            base.stroke()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MicGuard"
        return image
    }
}
